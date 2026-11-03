# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'sequel/extensions/migration'
require 'legion/data/archival'
require 'legion/data/retention'
require 'legion/data/archiver'

RSpec.describe Legion::Data::Task::Execution do
  include Legion::Data::Task::Status::Helper
  include Legion::Data::Settings::Helper

  before(:context) do
    @directory = Dir.mktmpdir('legion-task-execution')
    if ENV['LEGION_DATA_ADAPTER'] == 'postgres'
      @database_options = {
        adapter: :postgres, host: ENV.fetch('LEGION_DATA_HOST'), port: Integer(ENV.fetch('LEGION_DATA_PORT')),
        user: ENV.fetch('LEGION_DATA_USER'), password: ENV.fetch('LEGION_DATA_PASSWORD'), database: ENV.fetch('LEGION_DATA_DATABASE'),
        max_connections: 8
      }
      @schema_admin = Sequel.connect(@database_options)
      @schema_name = :"task_execution_#{SecureRandom.hex(8)}"
      @schema_admin.create_schema(@schema_name)
      @schema_created = true
      @database_options[:search_path] = @schema_name.to_s
      @database = Sequel.connect(@database_options)
      task_migrate_postgres_fixture
    else
      @database_options = {
        adapter: :sqlite, database: File.join(@directory, 'tasks.db'), max_connections: 8,
        after_connect: proc { |connection| Legion::Data::Connection.configure_sqlite_busy_handler(connection: connection, timeout: 5000) }
      }
      @database = Sequel.connect(@database_options)
      Sequel::Migrator.run(@database, File.expand_path('../../../lib/legion/data/migrations', __dir__))
    end
  end

  after(:context) do
    @database&.disconnect
    @schema_admin.drop_schema(@schema_name, cascade: true) if @schema_created
    @schema_admin&.disconnect
    FileUtils.remove_entry(@directory) if @directory
  end

  around do |example|
    original = Legion::Data::Connection.instance_variable_get(:@sequel)
    original_adapter = Legion::Data::Connection.instance_variable_get(:@adapter)
    original_loader = Legion::Settings.loader
    original_settings = Legion::Settings[:data][:task_execution]
    begin
      Legion::Data::Connection.instance_variable_set(:@sequel, @database)
      Legion::Data::Connection.instance_variable_set(:@adapter, @database.database_type)
      Legion::Settings[:data][:task_execution] = Legion::Data::Settings.task_execution
      @database[:task_dispatches].delete
      @database[:task_attempts].delete
      @database[:tasks_archive].delete
      @database[:tasks].delete
      example.run
    ensure
      Legion::Data::Connection.instance_variable_set(:@sequel, original)
      Legion::Data::Connection.instance_variable_set(:@adapter, original_adapter)
      Legion::Settings.loader = original_loader
      Legion::Settings[:data][:task_execution] = original_settings
    end
  end

  def task_migrate_postgres_fixture
    # Exercise the actual task migrations without unrelated pgvector tables or public-schema writes.
    @database.create_table(:functions) { primary_key :id }
    @database.create_table(:nodes) { primary_key :id }
    @database.create_table(:identity_principals) { primary_key :id }
    @database.create_table(:identities) { primary_key :id }
    migrations = %w[
      008_add_tasks.rb 021_add_archive_tables.rb 031_add_task_depth.rb 032_add_task_cancelled_at.rb 033_add_task_delay.rb
      051_fix_tasks_created_at.rb
      075_add_task_idempotency.rb 137_preserve_task_archive_fields.rb 139_add_task_execution.rb
      140_create_task_attempts.rb 141_create_task_dispatches.rb 142_create_task_logs.rb 143_preserve_task_execution_archive_fields.rb
      144_add_task_execution_policy.rb
    ]
    fixture_path = File.join(@directory, 'task_migrations')
    FileUtils.mkdir_p(fixture_path)
    migrations.each_with_index do |name, index|
      source = File.expand_path("../../../lib/legion/data/migrations/#{name}", __dir__)
      FileUtils.cp(source, File.join(fixture_path, format('%<index>03d_%<name>s', index: index + 1, name: name)))
    end
    Sequel::Migrator.run(@database, fixture_path)
  end

  def task_create(key: SecureRandom.uuid, **values)
    described_class.create_task(values: { status: task_status(name: :queued) }.merge(values), idempotency_key: key).fetch(:task)
  end

  def dispatch_values(key: SecureRandom.uuid)
    { event_key: key, message_type: 'task', options: { args: { item: 'one' } } }
  end

  def concurrently(count:, &block)
    ready = Queue.new
    release = Queue.new
    threads = Array.new(count) do |index|
      Thread.new do
        ready << true
        release.pop
        yield index
      end
    end
    count.times { ready.pop }
    count.times { release << true }
    threads.map(&:value)
  ensure
    threads&.each(&:join)
  end

  it 'atomically deduplicates concurrent child creation and its dispatch intent' do
    calls = concurrently(count: 8) do
      described_class.create_task(values: { payload: { source: 'parent' } }, idempotency_key: 'parent:relationship:0',
                                  dispatch: dispatch_values(key: 'parent:relationship:0:dispatch'))
    end
    expect(calls.count { |call| call[:created] }).to eq(1)
    expect(calls.map { |call| call[:task][:id] }.uniq).to contain_exactly(@database[:tasks].get(:id))
    expect(@database[:task_dispatches].count).to eq(1)
    claimed = described_class.claim_dispatches(owner: 'relay').fetch(0)
    expect(claimed[:options]).to eq(args: { item: 'one' }, task_id: calls.first[:task][:id])
  end

  it 'rolls task creation back if its durable dispatch cannot be recorded' do
    expect do
      described_class.create_task(values: {}, idempotency_key: 'rollback', dispatch: dispatch_values.merge(options: 'invalid'))
    end.to raise_error(StandardError)
    expect(@database[:tasks].where(execution_key: 'rollback').count).to eq(0)
    expect(described_class.create_task(values: {}, idempotency_key: 'rollback')[:created]).to be(true)
  end

  it 'rolls back a failed creation even when its caller catches the error and commits unrelated work' do
    @database.transaction do
      task_create(key: 'unrelated')
      expect do
        described_class.create_task(values: {}, idempotency_key: 'rollback', dispatch: dispatch_values.merge(options: 'invalid'))
      end.to raise_error(StandardError)
    end

    expect(@database[:tasks].select_map(:execution_key)).to eq(['unrelated'])
    expect(@database[:task_dispatches].count).to eq(0)
    expect(described_class.create_task(values: {}, idempotency_key: 'rollback', dispatch: dispatch_values)[:created]).to be(true)
    expect(@database[:task_dispatches].count).to eq(1)
  end

  it 'preserves logical identity after completion and idempotency TTL expiry' do
    task = task_create(key: 'logical', idempotency_expires_at: Time.now - 60)
    described_class.complete_task(task_id: task[:id], status: task_status(name: :completed), result: { answer: 42 })
    duplicate = described_class.create_task(values: {}, idempotency_key: 'logical')
    expect(duplicate[:created]).to be(false)
    expect(duplicate[:task]).to include(id: task[:id], status: task_status(name: :completed))
  end

  it 'grants only one concurrent owner and one persisted attempt' do
    task = task_create
    claims = concurrently(count: 8) { described_class.claim_task(task_id: task[:id], owner: SecureRandom.uuid) }
    expect(claims.count { |claim| claim[:claimed] }).to eq(1)
    expect(@database[:task_attempts].where(task_id: task[:id]).count).to eq(1)
    winner = claims.find { |claim| claim[:claimed] }
    expect(@database[:task_attempts].where(id: winner[:attempt_id]).first).to include(token: winner[:token], task_id: task[:id])
  end

  it 'does not let missing or stale ownership complete a running task' do
    task = task_create
    owner = described_class.claim_task(task_id: task[:id], owner: 'worker')
    expect(described_class.complete_task(task_id: task[:id], status: task_status(name: :completed), result: {})[:changed]).to be(false)
    expect(described_class.complete_task(task_id: task[:id], status: task_status(name: :completed), result: {}, token: 'stale')[:changed]).to be(false)
    expect(described_class.complete_task(task_id: task[:id], status: task_status(name: :completed), result: {}, token: owner[:token])[:changed]).to be(true)
  end

  it 'commits one outcome and one continuation under competing duplicate completions' do
    task = task_create
    claim = described_class.claim_task(task_id: task[:id], owner: 'worker')
    completions = concurrently(count: 4) do
      described_class.complete_task(task_id: task[:id], status: task_status(name: :completed), result: { answer: 42 }, token: claim[:token],
                                    continuation: dispatch_values(key: "complete:#{task[:id]}"))
    end
    expect(completions.count { |completion| completion[:changed] }).to eq(1)
    expect(@database[:task_dispatches].count).to eq(1)
    expect(Legion::JSON.load(@database[:tasks].where(id: task[:id]).get(:results))).to eq(answer: 42)
    expect(described_class.transition_task(task_id: task[:id], status: task_status(name: :queued))[:reason]).to eq(:terminal)
    expect(described_class.claim_task(task_id: task[:id], owner: 'late')[:claimed]).to be(false)
  end

  it 'rolls completion and attempt outcome back if continuation persistence fails' do
    task = task_create
    claim = described_class.claim_task(task_id: task[:id], owner: 'worker')
    expect do
      described_class.complete_task(task_id: task[:id], status: task_status(name: :completed), result: {}, token: claim[:token],
                                    continuation: dispatch_values.merge(options: 'invalid'))
    end.to raise_error(StandardError)
    expect(@database[:tasks].where(id: task[:id]).get(:status)).to eq(task_status(name: :running))
    expect(@database[:task_attempts].where(id: claim[:attempt_id]).get(:finished_at)).to be_nil
    expect(@database[:task_dispatches].count).to eq(0)
  end

  it 'rolls back a failed completion inside a caller transaction that still commits' do
    task = task_create(key: 'completion')
    claim = described_class.claim_task(task_id: task[:id], owner: 'worker')
    @database.transaction do
      task_create(key: 'unrelated')
      expect do
        described_class.complete_task(task_id: task[:id], status: task_status(name: :completed), result: { answer: 42 }, token: claim[:token],
                                      continuation: dispatch_values.merge(options: 'invalid'))
      end.to raise_error(StandardError)
    end

    expect(@database[:tasks].order(:execution_key).select_map(:execution_key)).to eq(%w[completion unrelated])
    expect(@database[:tasks].where(id: task[:id]).first).to include(status: task_status(name: :running), completed_at: nil, results: nil)
    expect(@database[:task_attempts].where(id: claim[:attempt_id]).first).to include(finished_at: nil, status: task_status(name: :running))
    expect(@database[:task_dispatches].count).to eq(0)
    completed = described_class.complete_task(task_id: task[:id], status: task_status(name: :completed), result: { answer: 42 }, token: claim[:token],
                                              continuation: dispatch_values)
    expect(completed[:changed]).to be(true)
    expect(@database[:task_dispatches].count).to eq(1)
  end

  it 'joins an outer occurrence transaction instead of committing partial task or dispatch state' do
    @database.transaction do
      described_class.create_task(values: { schedule_id: 'schedule', occurrence_id: 'occurrence' }, idempotency_key: 'occurrence',
                                  dispatch: dispatch_values(key: 'occurrence'))
      raise Sequel::Rollback
    end
    expect(@database[:tasks].count).to eq(0)
    expect(@database[:task_dispatches].count).to eq(0)
  end

  it 'marks an expired running attempt unknown without authorizing another external effect' do
    task = task_create
    claim = described_class.claim_task(task_id: task[:id], owner: 'crashed', now: Time.now - 120)
    replacement = described_class.claim_task(task_id: task[:id], owner: 'replacement')
    expect(replacement).to include(claimed: false, reason: :unknown)
    expect(replacement[:task][:status]).to eq(task_status(name: :unknown))
    expect(@database[:task_attempts].where(id: claim[:attempt_id]).get(:status)).to eq(task_status(name: :unknown))
    expect(described_class.complete_task(task_id: task[:id], status: task_status(name: :completed), result: {}, token: claim[:token])[:changed]).to be(false)
    expect(@database[:task_attempts].where(task_id: task[:id]).count).to eq(1)
  end

  it 'does not repeat historical running tasks without persisted ownership' do
    task = task_create(status: task_status(name: :running))
    claim = described_class.claim_task(task_id: task[:id], owner: 'replacement')
    expect(claim).to include(claimed: false, reason: :unknown)
    expect(@database[:task_attempts].count).to eq(0)
  end

  it 'prevents cancelled and deadline-expired tasks from being executed or dispatched' do
    cancelled = task_create(cancelled_at: Time.now)
    expired = task_create(status: task_status(name: :delayed), deadline_at: Time.now - 1)
    expect(described_class.claim_task(task_id: cancelled[:id], owner: 'worker')[:reason]).to eq(:cancelled)
    dispatch = described_class.enqueue_task_dispatch(task_id: expired[:id], **dispatch_values, expected_status: task_status(name: :delayed))
    expect(dispatch).to eq(created: false, dispatch: nil)
    expect(@database[:tasks].where(id: expired[:id]).get(:status)).to eq(task_status(name: :expired))
    expect(@database[:task_attempts].count).to eq(0)
  end

  it 'allows cancellation to invalidate a live owner and prevents late success' do
    task = task_create
    claim = described_class.claim_task(task_id: task[:id], owner: 'worker')
    cancelled = described_class.transition_task(task_id: task[:id], status: task_status(name: :cancelled))
    expect(cancelled[:changed]).to be(true)
    expect(described_class.complete_task(task_id: task[:id], status: task_status(name: :completed), result: {}, token: claim[:token])[:changed]).to be(false)
    expect(@database[:task_attempts].where(id: claim[:attempt_id]).get(:status)).to eq(task_status(name: :cancelled))
  end

  it 'allows only the expected stage to record replay output' do
    task = task_create(status: task_status(name: :transformer_queued))
    first = described_class.transition_task(task_id: task[:id], status: task_status(name: :transformer_succeeded),
                                            expected_status: task_status(name: :transformer_queued), values: { transformation_result: { output: [1] } })
    second = described_class.transition_task(task_id: task[:id], status: task_status(name: :transformer_succeeded),
                                             expected_status: task_status(name: :transformer_queued), values: { transformation_result: { output: [2] } })
    expect(first[:changed]).to be(true)
    expect(second[:reason]).to eq(:status_mismatch)
    expect(Legion::JSON.load(second[:task][:transformation_result])).to eq(output: [1])
  end

  it 'records owned failed attempts and waits for configured backoff before a bounded retry' do
    Legion::Settings[:data][:task_execution][:retry][:max_attempts] = 2
    task = task_create
    first = described_class.claim_task(task_id: task[:id], owner: 'worker')
    failure = { success: false, status: task_status(name: :exception), error: 'safe failure' }
    pending = described_class.complete_task(task_id: task[:id], token: first[:token], status: task_status(name: :retry_pending), result: failure)
    expect(pending[:task]).to include(status: task_status(name: :retry_pending), completed_at: nil)
    expect(@database[:task_attempts].where(id: first[:attempt_id]).get(:status)).to eq(task_status(name: :exception))
    expect(described_class.claim_task(task_id: task[:id], owner: 'early')[:reason]).to eq(:not_due)
    second = described_class.claim_task(task_id: task[:id], owner: 'retry', now: pending[:task][:retry_at] + 1)
    expect(second[:claimed]).to be(true)
    exhausted = described_class.complete_task(task_id: task[:id], token: second[:token], status: task_status(name: :retry_pending), result: failure)
    expect(exhausted[:task][:status]).to eq(task_status(name: :failed))
    expect(described_class.transition_task(task_id: task[:id], token: second[:token], status: task_status(name: :retry_pending))[:reason]).to eq(:attempt_limit)
  end

  it 'rejects retry promotion by anyone except the owner of a known failed attempt' do
    task = task_create
    expect(described_class.transition_task(task_id: task[:id], status: task_status(name: :retry_pending))[:reason]).to eq(:owner_mismatch)
    claim = described_class.claim_task(task_id: task[:id], owner: 'worker')
    described_class.complete_task(task_id: task[:id], token: claim[:token], status: task_status(name: :failed), result: { success: false })
    expect(described_class.transition_task(task_id: task[:id], token: 'stale', status: task_status(name: :retry_pending))[:changed]).to be(false)
    expect(described_class.transition_task(task_id: task[:id], token: claim[:token], status: task_status(name: :retry_pending))[:changed]).to be(true)
  end

  it 'atomically promotes delayed tasks and records exactly one dispatch' do
    task = task_create(status: task_status(name: :delayed), function_args: { item: 'one' })
    results = concurrently(count: 4) do
      described_class.enqueue_task_dispatch(task_id: task[:id], **dispatch_values(key: 'delayed'), expected_status: task_status(name: :delayed))
    end
    expect(results.count { |result| result[:created] }).to eq(1)
    expect(@database[:task_dispatches].count).to eq(1)
    expect(@database[:tasks].where(id: task[:id]).get(:status)).to eq(task_status(name: :dispatching))
  end

  it 'keeps scheduled work unclaimable until its scheduler promotes it' do
    task = task_create(status: task_status(name: :scheduled))
    expect(described_class.claim_task(task_id: task[:id], owner: 'early')[:reason]).to eq(:not_due)
    dispatched = described_class.enqueue_task_dispatch(task_id: task[:id], **dispatch_values, expected_status: task_status(name: :scheduled))
    expect(dispatched[:created]).to be(true)
    expect(described_class.claim_task(task_id: task[:id], owner: 'due')[:claimed]).to be(true)
  end

  it 'treats transformer exceptions as terminal outcomes rather than executable work' do
    task = task_create(status: task_status(name: :transformer_queued))
    failed = described_class.complete_task(task_id: task[:id], status: task_status(name: :transformer_exception), result: { error: 'invalid input' })
    expect(failed[:changed]).to be(true)
    expect(described_class.claim_task(task_id: task[:id], owner: 'late')[:reason]).to eq(:terminal)
    expect(described_class.transition_task(task_id: task[:id], status: task_status(name: :queued))[:reason]).to eq(:terminal)
    expect(@database[:task_attempts].count).to eq(0)
  end

  it 'reclaims an expired publication lease with a new token while rejecting a stale acknowledgement' do
    dispatch = described_class.enqueue_dispatch(**dispatch_values)[:dispatch]
    old = described_class.claim_dispatches(owner: 'crashed', now: Time.now - 120).fetch(0)
    reclaimed = described_class.claim_dispatches(owner: 'replacement').fetch(0)
    expect(reclaimed[:id]).to eq(dispatch[:id])
    expect(reclaimed[:token]).not_to eq(old[:token])
    expect(described_class.ack_dispatch(dispatch_id: dispatch[:id], token: old[:token])[:changed]).to be(false)
    expect(described_class.ack_dispatch(dispatch_id: dispatch[:id], token: reclaimed[:token])[:changed]).to be(true)
    expect(described_class.claim_dispatches(owner: 'later')).to eq([])
  end

  it 'keeps rejected publication recoverable and never marks it delivered' do
    described_class.enqueue_dispatch(**dispatch_values)
    claim = described_class.claim_dispatches(owner: 'relay').fetch(0)
    expect(described_class.release_dispatch(dispatch_id: claim[:id], token: claim[:token], error: 'unroutable')).to eq(changed: true)
    stored = @database[:task_dispatches].where(id: claim[:id]).first
    expect(stored).to include(delivered_at: nil, last_error: 'unroutable')
    replacement = described_class.claim_dispatches(owner: 'next').fetch(0)
    expect(described_class.release_dispatch(dispatch_id: claim[:id], token: claim[:token], error: 'late')).to eq(changed: false)
    expect(described_class.ack_dispatch(dispatch_id: claim[:id], token: replacement[:token])).to eq(changed: true)
  end

  it 'never grants one live dispatch to concurrent relays' do
    described_class.enqueue_dispatch(**dispatch_values)
    claims = concurrently(count: 8) { described_class.claim_dispatches(owner: SecureRandom.uuid) }.flatten
    expect(claims.map { |claim| claim[:id] }).to contain_exactly(@database[:task_dispatches].get(:id))
  end

  it 'discards owned cancelled work without claiming it delivered or reclaiming it' do
    described_class.enqueue_dispatch(**dispatch_values)
    claim = described_class.claim_dispatches(owner: 'relay').fetch(0)
    expect(described_class.discard_dispatch(dispatch_id: claim[:id], token: 'stale', reason: 'cancelled')[:changed]).to be(false)
    discarded = described_class.discard_dispatch(dispatch_id: claim[:id], token: claim[:token], reason: 'cancelled')
    expect(discarded[:changed]).to be(true)
    expect(discarded[:dispatch]).to include(delivered_at: nil, discard_reason: 'cancelled')
    expect(discarded[:dispatch][:discarded_at]).to be_a(Time)
    expect(described_class.claim_dispatches(owner: 'later', now: Time.now + 120)).to eq([])
    expect(described_class.ack_dispatch(dispatch_id: claim[:id], token: claim[:token])[:changed]).to be(false)
  end

  it 'recovers committed intent through a replacement database connection' do
    created = described_class.create_task(values: {}, idempotency_key: 'reconnect', dispatch: dispatch_values(key: 'reconnect'))
    @database.disconnect
    replacement = Sequel.connect(@database_options)
    begin
      Legion::Data::Connection.instance_variable_set(:@sequel, replacement)
      expect(described_class.create_task(values: {}, idempotency_key: 'reconnect')[:task][:id]).to eq(created[:task][:id])
      claim = described_class.claim_dispatches(owner: 'reconnected').fetch(0)
      expect(claim[:options][:task_id]).to eq(created[:task][:id])
      expect(described_class.ack_dispatch(dispatch_id: claim[:id], token: claim[:token])[:changed]).to be(true)
    ensure
      replacement.disconnect
    end
  end

  it 'ignores obsolete identity overrides when another loader completes persisted work' do
    task = task_create
    claim = described_class.claim_task(task_id: task[:id], owner: 'first')
    Legion::Settings.loader = Legion::Settings::Loader.new
    Legion::Settings.register_library(:data, Legion::Data::Settings.default)
    Legion::Settings.loader.settings[:task_execution] = {
      statuses: { completed: 'custom.done', running: 'custom.running' }, terminal_statuses: [],
      outbox: { statuses: { delivered: 'custom.delivered' } }
    }
    completed = described_class.complete_task(task_id: task[:id], token: claim[:token], status: 'task.completed', result: {})
    expect(completed[:changed]).to be(true)
    expect(described_class.claim_task(task_id: task[:id], owner: 'late')[:reason]).to eq(:terminal)
    expect { task_create(status: 'custom.done') }.to raise_error(ArgumentError)
    described_class.enqueue_dispatch(**dispatch_values)
    dispatch = described_class.claim_dispatches(owner: 'relay').first
    expect(described_class.ack_dispatch(dispatch_id: dispatch[:id], token: dispatch[:token])[:changed]).to be(true)
    expect(@database[:task_dispatches].where(id: dispatch[:id]).get(:status)).to eq('delivered')
  end

  it 'uses the creation policy for claims, renewal, retry backoff and exhaustion across different loaders' do
    local = Legion::Settings[:data][:task_execution]
    local[:execution].merge!(lease_seconds: 90, heartbeat_seconds: 25)
    local[:retry].merge!(max_attempts: 3, base_delay_seconds: 7, max_delay_seconds: 9)
    task = task_create
    Legion::Settings.loader = Legion::Settings::Loader.new
    Legion::Settings.register_library(:data, Legion::Data::Settings.default)
    data_task_execution_settings[:execution].merge!(lease_seconds: 300, heartbeat_seconds: 100)
    data_task_execution_settings[:retry].merge!(max_attempts: 1, base_delay_seconds: 40, max_delay_seconds: 80)
    now = Time.now
    claim = described_class.claim_task(task_id: task[:id], owner: 'different-node', now: now)
    expect(claim[:policy]).to eq(execution: { lease_seconds: 90, heartbeat_seconds: 25 },
                                 retry:     { max_attempts: 3, base_delay_seconds: 7, max_delay_seconds: 9 })
    expect(claim[:task][:execution_lease_until]).to eq(now + 90)
    renewal = described_class.renew_task_lease(task_id: task[:id], token: claim[:token], now: now + 20)
    expect(renewal[:task][:execution_lease_until]).to eq(now + 110)
    failure = { success: false, status: 'task.exception' }
    allow(Time).to receive(:now).and_return(now + 21)
    pending = described_class.complete_task(task_id: task[:id], token: claim[:token], status: 'task.retry_pending', result: failure)
    expect(pending[:task][:retry_at]).to eq(now + 28)
    expect(described_class.claim_task(task_id: task[:id], owner: 'early', now: now + 27)[:reason]).to eq(:not_due)
    data_task_execution_settings[:retry][:max_attempts] = 100
    second = described_class.claim_task(task_id: task[:id], owner: 'retry', now: now + 28)
    expect(second[:policy]).to eq(claim[:policy])
    allow(Time).to receive(:now).and_return(now + 29)
    capped = described_class.complete_task(task_id: task[:id], token: second[:token], status: 'task.retry_pending', result: failure)
    expect(capped[:task][:retry_at]).to eq(now + 38)
    third = described_class.claim_task(task_id: task[:id], owner: 'last-retry', now: now + 38)
    exhausted = described_class.complete_task(task_id: task[:id], token: third[:token], status: 'task.retry_pending', result: failure)
    expect(exhausted[:task][:status]).to eq('task.failed')
    expect(described_class.transition_task(task_id: task[:id], token: third[:token], status: 'task.retry_pending')[:reason]).to eq(:attempt_limit)
  end

  it 'captures one legacy first-claim policy atomically despite competing local overlays' do
    id = @database[:tasks].insert(status: 'task.queued')
    claims = concurrently(count: 8) do |index|
      Legion::Settings.with_overlay(data: { task_execution: { execution: { lease_seconds: 60 + index } } }) do
        described_class.claim_task(task_id: id, owner: "worker-#{index}")
      end
    end
    winner = claims.select { |claim| claim[:claimed] }
    expect(winner.size).to eq(1)
    stored = Legion::JSON.load(@database[:tasks].where(id: id).get(:execution_policy))
    expect(claims.map { |claim| claim[:policy] }.uniq).to eq([stored])
    data_task_execution_settings[:execution][:lease_seconds] = 500
    renewed_at = Time.now
    renewal = described_class.renew_task_lease(task_id: id, token: winner.first[:token], now: renewed_at)
    expect(renewal[:task][:execution_lease_until]).to eq(renewed_at + stored[:execution][:lease_seconds])
    expect(@database[:task_attempts].where(task_id: id).count).to eq(1)
  end

  it 'protects policy against caller values and mutable claim results' do
    expect { task_create(execution_policy: '{}') }.to raise_error(ArgumentError)
    task = task_create
    expect do
      described_class.transition_task(task_id: task[:id], status: 'task.queued', values: { execution_policy: '{}' })
    end.to raise_error(ArgumentError)
    claim = described_class.claim_task(task_id: task[:id], owner: 'worker')
    expect { claim[:policy][:execution][:lease_seconds] = 1 }.to raise_error(FrozenError)
  end

  it 'uses later live policy for new tasks without resetting connection state' do
    Legion::Settings.loader = Legion::Settings::Loader.new
    Legion::Settings.register_library(:data, Legion::Data::Settings.default)
    Legion::Settings[:data][:connected] = true
    task_create
    Legion::Settings[:data][:task_execution][:execution][:lease_seconds] = 120
    expect(Legion::Data.connected?).to be(true)
    task = task_create
    claim = described_class.claim_task(task_id: task[:id], owner: 'worker')
    expect(claim[:policy][:execution][:lease_seconds]).to eq(120)
  end

  it 'rejects a configured false retry limit instead of substituting defaults' do
    Legion::Settings[:data][:task_execution][:retry][:max_attempts] = false

    expect { task_create }.to raise_error do |error|
      cause = error.respond_to?(:wrapped_exception) ? error.wrapped_exception : error
      expect(cause).to be_a(ArgumentError)
    end
    expect(@database[:tasks].count).to eq(0)
  end

  it 'does not attach one dispatch identity to a different task' do
    first = task_create
    second = task_create(status: task_status(name: :delayed))
    described_class.enqueue_dispatch(**dispatch_values(key: 'identity'), task_id: first[:id])
    expect do
      described_class.enqueue_task_dispatch(task_id: second[:id], **dispatch_values(key: 'identity'), expected_status: task_status(name: :delayed))
    end.to raise_error(StandardError)
    expect(@database[:tasks].where(id: second[:id]).get(:status)).to eq(task_status(name: :delayed))
    expect(@database[:task_dispatches].count).to eq(1)
  end

  it 'adds execution identity without constraining historical duplicate idempotency keys' do
    legacy = Sequel.sqlite(File.join(@directory, 'legacy.db'))
    begin
      migrations = File.expand_path('../../../lib/legion/data/migrations', __dir__)
      Sequel::Migrator.run(legacy, migrations, target: 136)
      2.times { legacy[:tasks].insert(status: task_status(name: :completed), idempotency_key: 'duplicate') }
      Sequel::Migrator.run(legacy, migrations)
      expect(legacy[:tasks].where(idempotency_key: 'duplicate').count).to eq(2)
      expect(legacy[:tasks].where(execution_key: nil).count).to eq(2)
    ensure
      legacy.disconnect
    end
  end

  it 'renews a live attempt through a long execution and preserves completion ownership' do
    task = task_create
    started = Time.now
    lease = data_task_execution_settings.fetch(:execution).fetch(:lease_seconds)
    claim = described_class.claim_task(task_id: task[:id], owner: 'long-running', now: started)
    renewal = described_class.renew_task_lease(task_id: task[:id], token: claim[:token], now: started + lease - 1)
    expect(renewal[:renewed]).to be(true)
    expect(@database[:task_attempts].where(id: claim[:attempt_id]).get(:lease_until)).to be > started + lease
    competitor = described_class.claim_task(task_id: task[:id], owner: 'competitor', now: started + lease + 1)
    expect(competitor[:reason]).to eq(:leased)
    expect(described_class.complete_task(task_id: task[:id], token: claim[:token], status: task_status(name: :completed), result: {})[:changed]).to be(true)
    expect(described_class.renew_task_lease(task_id: task[:id], token: claim[:token])[:renewed]).to be(false)
  end

  it 'rejects stale renewal and does not revive an expired execution' do
    task = task_create
    claim = described_class.claim_task(task_id: task[:id], owner: 'worker')
    expect(described_class.renew_task_lease(task_id: task[:id], token: 'stale')[:renewed]).to be(false)
    expired = described_class.renew_task_lease(task_id: task[:id], token: claim[:token], now: claim[:task][:execution_lease_until] + 1)
    expect(expired[:renewed]).to be(false)
    expect(expired[:task][:status]).to eq(task_status(name: :unknown))
    expect(described_class.complete_task(task_id: task[:id], token: claim[:token], status: task_status(name: :completed), result: {})[:changed]).to be(false)
  end

  it 'checks persisted parent cancellation after the child was published' do
    parent = task_create
    child = task_create(parent_id: parent[:id])
    described_class.transition_task(task_id: parent[:id], status: task_status(name: :cancelled))
    claim = described_class.claim_task(task_id: child[:id], owner: 'late-delivery')
    expect(claim).to include(claimed: false, reason: :cancelled)
    expect(claim[:task][:status]).to eq(task_status(name: :cancelled))
    expect(@database[:task_attempts].where(task_id: child[:id]).count).to eq(0)
  end

  it 'rejects active child completion when its persisted parent deadline has elapsed' do
    parent = task_create(deadline_at: Time.now + 60)
    child = task_create(parent_id: parent[:id])
    claim = described_class.claim_task(task_id: child[:id], owner: 'worker')
    described_class.transition_task(task_id: parent[:id], status: task_status(name: :queued), values: { deadline_at: Time.now - 1 })
    completion = described_class.complete_task(task_id: child[:id], token: claim[:token], status: task_status(name: :completed), result: {})
    expect(completion[:changed]).to be(false)
    expect(completion[:task][:status]).to eq(task_status(name: :expired))
    expect(@database[:task_attempts].where(id: claim[:attempt_id]).get(:status)).to eq(task_status(name: :expired))
  end

  it 'fails safely rather than overwriting an unsupported manually created log table' do
    legacy = Sequel.sqlite(File.join(@directory, 'manual_logs.db'))
    begin
      migrations = File.expand_path('../../../lib/legion/data/migrations', __dir__)
      Sequel::Migrator.run(legacy, migrations, target: 141)
      legacy.create_table(:task_logs) do
        primary_key :id
        String :entry
      end
      legacy[:task_logs].insert(entry: 'existing user evidence')
      expect { Sequel::Migrator.run(legacy, migrations) }.to raise_error(Sequel::DatabaseError)
      expect(legacy[:task_logs].all).to eq([{ id: 1, entry: 'existing user evidence' }])
    ensure
      legacy.disconnect
    end
  end

  context 'when workers use different process timezones' do
    let(:instant) { Time.utc(2026, 11, 3, 12) }

    around do |example|
      timezone = ENV.fetch('TZ', nil)
      database_timezone = Thread.current[:database_timezone]
      application_timezone = Thread.current[:application_timezone]
      begin
        ENV['TZ'] = 'America/Chicago'
        Sequel.thread_database_timezone = :local
        Sequel.thread_application_timezone = :local
        example.run
      ensure
        ENV['TZ'] = timezone
        Sequel.thread_database_timezone = database_timezone
        Sequel.thread_application_timezone = application_timezone
      end
    end

    before do
      allow(Time).to receive(:now).and_return(instant)
    end

    it 'preserves task deadlines and attempt lease instants through creation, renewal and expiration' do
      task = task_create(created: instant, deadline_at: (instant + 120).iso8601)
      claim = described_class.claim_task(task_id: task[:id], owner: 'chicago')
      ENV['TZ'] = 'UTC'
      duplicate = described_class.create_task(values: {}, idempotency_key: task[:execution_key])[:task]
      expect(duplicate).to include(created: instant, deadline_at: instant + 120, execution_lease_until: instant + 60)
      expect(described_class.claim_task(task_id: task[:id], owner: 'early', now: instant + 30)[:reason]).to eq(:leased)
      renewed = described_class.renew_task_lease(task_id: task[:id], token: claim[:token], now: instant + 30)
      expect(renewed[:renewed]).to be(true)
      expect(renewed[:task][:execution_lease_until]).to eq(instant + 90)

      ENV['TZ'] = 'Asia/Kolkata'
      allow(Time).to receive(:now).and_return(instant + 90)
      expired = described_class.claim_task(task_id: task[:id], owner: 'late')
      expect(expired).to include(claimed: false, reason: :unknown)
      ENV['TZ'] = 'UTC'
      expect(@database[:task_attempts].where(id: claim[:attempt_id]).first).to include(
        created_at: instant, lease_until: instant + 90, finished_at: instant + 90, status: 'task.unknown'
      )
    end

    it 'enforces the absolute deadline boundary rather than a reader local wall clock' do
      task = task_create(deadline_at: (instant + 30))
      ENV['TZ'] = 'UTC'
      expect(described_class.claim_task(task_id: task[:id], owner: 'on-time', now: instant + 29)[:claimed]).to be(true)
      ENV['TZ'] = 'Asia/Kolkata'
      expect(described_class.claim_task(task_id: task[:id], owner: 'late', now: instant + 30)[:reason]).to eq(:deadline)
    end

    it 'keeps persisted retry backoff unchanged when another timezone picks up the attempt' do
      data_task_execution_settings[:retry][:base_delay_seconds] = 10
      task = task_create
      claim = described_class.claim_task(task_id: task[:id], owner: 'chicago')
      allow(Time).to receive(:now).and_return(instant + 10)
      retrying = described_class.complete_task(task_id: task[:id], token: claim[:token], status: 'task.retry_pending',
                                               result: { success: false, status: 'task.exception' })
      expect(retrying[:task][:retry_at]).to eq(instant + 20)
      ENV['TZ'] = 'UTC'
      expect(described_class.claim_task(task_id: task[:id], owner: 'early', now: instant + 19)[:reason]).to eq(:not_due)
      ENV['TZ'] = 'Asia/Kolkata'
      retried = described_class.claim_task(task_id: task[:id], owner: 'due', now: instant + 20)
      expect(retried[:claimed]).to be(true)
      expect(retried[:task][:attempt_count]).to eq(2)
      ENV['TZ'] = 'UTC'
      expect(@database[:task_attempts].where(id: claim[:attempt_id]).first).to include(finished_at: instant + 10, status: 'task.exception')
    end

    it 'preserves outbox lease boundaries through reclaim, release and acknowledgement' do
      lease = data_task_execution_settings.fetch(:outbox).fetch(:lease_seconds)
      dispatch = described_class.enqueue_dispatch(**dispatch_values)[:dispatch]
      first = described_class.claim_dispatches(owner: 'chicago').fetch(0)
      ENV['TZ'] = 'UTC'
      expect(described_class.claim_dispatches(owner: 'early', now: instant + lease - 1)).to eq([])
      allow(Time).to receive(:now).and_return(instant + lease)
      expect(described_class.ack_dispatch(dispatch_id: dispatch[:id], token: first[:token])).to eq(changed: false)
      replacement = described_class.claim_dispatches(owner: 'replacement').fetch(0)
      expect(replacement[:token]).not_to eq(first[:token])
      expect(replacement).to include(created_at: instant, lease_until: instant + (2 * lease))

      ENV['TZ'] = 'America/Chicago'
      allow(Time).to receive(:now).and_return(instant + lease + 1)
      expect(described_class.release_dispatch(dispatch_id: dispatch[:id], token: replacement[:token], error: 'unroutable')).to eq(changed: true)
      ENV['TZ'] = 'UTC'
      expect(@database[:task_dispatches].where(id: dispatch[:id]).get(:updated_at)).to eq(instant + lease + 1)
      final = described_class.claim_dispatches(owner: 'final').fetch(0)
      ENV['TZ'] = 'Asia/Kolkata'
      expect(described_class.ack_dispatch(dispatch_id: dispatch[:id], token: final[:token])).to eq(changed: true)
      ENV['TZ'] = 'UTC'
      expect(@database[:task_dispatches].where(id: dispatch[:id]).get(:delivered_at)).to eq(instant + lease + 1)
    end

    it 'restores caller timezone policy after nested operations and exceptions' do
      Sequel.thread_application_timezone = :nil
      described_class.create_task(values: {}, idempotency_key: 'nested-timezone', dispatch: dispatch_values)
      expect(Sequel.database_timezone).to eq(:local)
      expect(Sequel.application_timezone).to be_nil
      expect do
        described_class.create_task(values: {}, idempotency_key: 'failed-timezone', dispatch: dispatch_values.merge(options: 'invalid'))
      end.to raise_error(StandardError)
      expect(Sequel.database_timezone).to eq(:local)
      expect(Sequel.application_timezone).to be_nil
    end
  end

  it 'archives legacy rows while retaining durable execution identities and attempts' do
    old = Time.now - (10 * 86_400)
    legacy_id = @database[:tasks].insert(status: 'task.queued', created: old)
    legacy_claim = described_class.claim_task(task_id: legacy_id, owner: 'legacy-worker')
    described_class.complete_task(task_id: legacy_id, token: legacy_claim[:token], status: 'task.completed', result: {})
    task = task_create(key: 'retained-execution', created: old, idempotency_expires_at: old)
    claim = described_class.claim_task(task_id: task[:id], owner: 'worker')
    described_class.complete_task(task_id: task[:id], token: claim[:token], status: task_status(name: :completed), result: { answer: 42 })
    policy = Legion::Data::Archival::Policy.new(tables: ['tasks'], warm_after_days: 1)
    expect(Legion::Data::Archival.archive!(policy: policy)).to eq(tasks: 1)
    expect(@database[:tasks].where(id: legacy_id).count).to eq(0)
    expect(@database[:tasks_archive].where(original_id: legacy_id).first).to include(execution_key: nil, attempt_count: 1)
    archived_policy = @database[:tasks_archive].where(original_id: legacy_id).get(:execution_policy)
    expect(Legion::JSON.load(archived_policy)).to eq(legacy_claim[:policy])
    expect(Legion::Data::Retention.archive_old_records(table: :tasks, archive_after_days: 1)[:archived]).to eq(0)
    Legion::Data::Archiver.archive_table(table: :tasks, retention_days: 1)
    expect(described_class.create_task(values: {}, idempotency_key: 'retained-execution')).to include(created: false)
    expect(@database[:task_attempts].where(id: claim[:attempt_id]).get(:status)).to eq(task_status(name: :completed))
    expect(@database[:tasks].where(id: task[:id]).get(:results)).to eq(Legion::JSON.dump({ answer: 42 }))
  end
end
