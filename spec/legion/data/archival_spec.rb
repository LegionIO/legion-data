# frozen_string_literal: true

require 'spec_helper'
require 'legion/data/archival'

RSpec.describe Legion::Data::Archival do
  let(:db) { Sequel.sqlite }
  let(:old) { Time.utc(2020, 1, 2, 3, 4, 5) }
  let(:policy) { Legion::Data::Archival::Policy.new(tables: ['tasks']) }

  before do
    Legion::Data::Migration.migrate(db)
    allow(Legion::Data).to receive(:connection).and_return(db)
  end

  after do
    db.disconnect
  end

  def populated_task_values
    extension = db[:extensions].insert(name: 'archive-fixture')
    runner = db[:runners].insert(extension_id: extension, name: 'archive-fixture')
    function = db[:functions].insert(runner_id: runner, name: 'perform')
    relationship = db[:relationships].insert(action_id: function)
    {
      status: 'completed', function_id: function, relationship_id: relationship,
      function_args: '{"argument":42}', results: '{"success":true}', payload: '{"message":"payload"}',
      created: old, updated: old + 60, created_at: old + 1, worker_id: 'worker', tenant_id: 'tenant',
      depth: 2, cancelled_at: old + 120, task_delay: 7, idempotency_key: 'archive-key', idempotency_expires_at: old + 300
    }
  end

  %i[scheduled policy].each do |entry_point|
    it "roundtrips every migrated task field through #{entry_point} archival" do
      id = db[:tasks].insert(populated_task_values)
      original = db[:tasks][id: id]
      if entry_point == :scheduled
        expect(described_class.archive_completed_tasks[:archived]).to eq(1)
      else
        expect(described_class.archive!(policy: policy)).to eq(tasks: 1)
      end

      expect(db[:tasks][id: id]).to be_nil
      expect(described_class.restore(table: :tasks, ids: [id])).to eq(1)
      expect(db[:tasks][id: id]).to eq(original)
      expect(db[:tasks_archive].where(original_id: id).count).to eq(0)
    end
  end

  it 'keeps referenced parents hot and restores parent/master links across separate batches' do
    parent = db[:tasks].insert(status: 'completed', created: old)
    child = db[:tasks].insert(status: 'running', created: old, parent_id: parent, master_id: parent)
    expect(described_class.archive_completed_tasks[:archived]).to eq(0)
    expect(db[:tasks][id: child].slice(:parent_id, :master_id)).to eq(parent_id: parent, master_id: parent)

    db[:tasks].where(id: child).update(status: 'completed')
    original = db[:tasks].order(:id).all
    expect(described_class.archive_completed_tasks[:archived]).to eq(1)
    expect(db[:tasks][id: parent]).to eq(original.first)
    expect(described_class.archive_completed_tasks[:archived]).to eq(1)
    expect(described_class.restore(table: :tasks, ids: [child, parent])).to eq(2)
    expect(db[:tasks].order(:id).all).to eq(original)
  end

  it 'rolls back all restores when an original ID is occupied' do
    ids = Array.new(2) { db[:tasks].insert(status: 'completed', created: old) }
    described_class.archive_completed_tasks
    db[:tasks].insert(id: ids.last, status: 'running')

    expect { described_class.restore(table: :tasks, ids: ids) }.to raise_error(Sequel::UniqueConstraintViolation)
    expect(db[:tasks][id: ids.first]).to be_nil
    expect(db[:tasks][id: ids.last][:status]).to eq('running')
    expect(db[:tasks_archive].select_map(:original_id)).to contain_exactly(*ids)
  end

  it 'retains the archive when a referenced function no longer exists' do
    id = db[:tasks].insert(populated_task_values)
    function = db[:tasks][id: id][:function_id]
    described_class.archive_completed_tasks
    db[:functions].where(id: function).delete

    expect { described_class.restore(table: :tasks, ids: [id]) }.to raise_error(Sequel::ForeignKeyConstraintViolation)
    expect(db[:tasks][id: id]).to be_nil
    expect(db[:tasks_archive].where(original_id: id).count).to eq(1)
  end

  it 'rolls back copying and deletion when any archive insert fails' do
    ids = %w[keep reject].map { |payload| db[:tasks].insert(status: 'completed', created: old, payload: payload) }
    db.run("CREATE TRIGGER reject_archive BEFORE INSERT ON tasks_archive WHEN NEW.payload = 'reject' BEGIN SELECT RAISE(ABORT, 'archive rejected'); END")

    expect { described_class.archive_completed_tasks }.to raise_error(Sequel::DatabaseError, /archive rejected/)
    expect(db[:tasks].select_map(:id)).to contain_exactly(*ids)
    expect(db[:tasks_archive].count).to eq(0)
  end

  it 'deletes only copied IDs when another row becomes eligible during the copy' do
    later = db[:tasks].insert(status: 'running', created: old)
    selected = db[:tasks].insert(status: 'completed', created: old)
    db.run("CREATE TRIGGER make_eligible AFTER INSERT ON tasks_archive BEGIN UPDATE tasks SET status = 'completed' WHERE id = #{later}; END")

    expect(described_class.archive_completed_tasks(batch_size: 1)[:archived]).to eq(1)
    expect(db[:tasks][id: selected]).to be_nil
    expect(db[:tasks][id: later][:status]).to eq('completed')
    expect(db[:tasks_archive].select_map(:original_id)).to eq([selected])
  end

  it 'uses the legacy creation timestamp for a non-mutating dry run' do
    id = db[:tasks].insert(status: 'completed', created: old)
    expect(described_class.archive!(policy: policy, dry_run: true)).to eq(tasks: 1)
    expect(db[:tasks][id: id][:created_at]).to be_nil
    expect(db[:tasks_archive].count).to eq(0)
  end

  it 'returns empty results when the database is unavailable' do
    allow(Legion::Data).to receive(:connection).and_return(nil)
    expect(described_class.archive!(policy: policy)).to eq({})
    expect(described_class.search(table: :tasks)).to eq([])
    expect(described_class.restore(table: :tasks, ids: [1])).to eq(0)
  end
end
