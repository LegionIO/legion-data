# frozen_string_literal: true

require 'spec_helper'
require 'legion/data/storage_tiers'
require 'sequel/extensions/migration'
require 'legion/data/task/execution'

RSpec.describe Legion::Data::StorageTiers do
  describe '.archive_to_warm' do
    it 'returns zero when no connection' do
      allow(Legion::Data).to receive(:connection).and_return(nil)
      result = described_class.archive_to_warm(table: :tasks)
      expect(result[:archived]).to eq(0)
      expect(result[:reason]).to eq('no_connection')
    end

    it 'returns zero when no archive table' do
      conn = Legion::Data.connection
      allow(conn).to receive(:table_exists?).with(:data_archive).and_return(false)
      result = described_class.archive_to_warm(table: :tasks)
      expect(result[:archived]).to eq(0)
      expect(result[:reason]).to eq('no_archive_table')
    end

    context 'with an isolated migrated SQLite database' do
      include Legion::Data::Task::Status::Helper

      around do |example|
        original = Legion::Data::Connection.instance_variable_get(:@sequel)
        original_adapter = Legion::Data::Connection.instance_variable_get(:@adapter)
        original_settings = Legion::Settings[:data][:task_execution]
        @database = Sequel.sqlite
        begin
          Sequel::Migrator.run(@database, File.expand_path('../../../lib/legion/data/migrations', __dir__))
          Legion::Data::Connection.instance_variable_set(:@sequel, @database)
          Legion::Data::Connection.instance_variable_set(:@adapter, :sqlite)
          Legion::Settings[:data][:task_execution] = Legion::Data::Settings.task_execution
          example.run
        ensure
          Legion::Data::Connection.instance_variable_set(:@sequel, original)
          Legion::Data::Connection.instance_variable_set(:@adapter, original_adapter)
          Legion::Settings[:data][:task_execution] = original_settings
          @database.disconnect
        end
      end

      it 'retains old durable outcomes and attempts without making the execution key executable again' do
        old = Time.now - (120 * 86_400)
        execution = Legion::Data::Task::Execution
        task = execution.create_task(
          values:          { created: old, created_at: old, idempotency_expires_at: old },
          idempotency_key: 'warm-retained'
        ).fetch(:task)
        claim = execution.claim_task(task_id: task[:id], owner: 'warm-worker')
        expect(claim[:claimed]).to be(true)
        completed = execution.complete_task(
          task_id: task[:id], token: claim[:token], status: task_status(name: :completed), result: { answer: 42 }
        )
        expect(completed[:changed]).to be(true)
        persisted_task = @database[:tasks].where(id: task[:id]).first
        persisted_attempts = @database[:task_attempts].where(task_id: task[:id]).all
        expect(persisted_attempts.size).to eq(1)

        expect(described_class.archive_to_warm(table: :tasks)).to eq(archived: 0)

        expect(@database[:tasks].where(id: task[:id]).first).to eq(persisted_task)
        expect(Legion::JSON.load(persisted_task[:results])).to eq(answer: 42)
        expect(@database[:task_attempts].where(task_id: task[:id]).all).to eq(persisted_attempts)
        expect(@database[:data_archive].where(source_table: 'tasks').count).to eq(0)
        duplicate = execution.create_task(values: {}, idempotency_key: 'warm-retained')
        expect(duplicate[:created]).to be(false)
        expect(duplicate[:task]).to include(id: task[:id], status: task_status(name: :completed), results: persisted_task[:results])
        expect(execution.claim_task(task_id: duplicate[:task][:id], owner: 'duplicate')[:claimed]).to be(false)
      end

      it 'archives eligible legacy tasks without letting protected rows consume the batch' do
        old = Time.now - (120 * 86_400)
        durable = Legion::Data::Task::Execution.create_task(
          values: { created: old, created_at: old }, idempotency_key: 'protected-first'
        ).fetch(:task)
        legacy_id = @database[:tasks].insert(created: old, created_at: old, status: task_status(name: :completed))
        recent_id = @database[:tasks].insert(created: Time.now, created_at: Time.now, status: task_status(name: :completed))

        expect(described_class.archive_to_warm(table: 'tasks', batch_size: 1)).to eq(archived: 1, table: 'tasks')

        expect(@database[:tasks].where(id: legacy_id).count).to eq(0)
        expect(@database[:tasks].select_map(:id)).to contain_exactly(durable[:id], recent_id)
        archived = @database[:data_archive].where(source_table: 'tasks', source_id: legacy_id).first
        expect(archived[:tier]).to eq(described_class::TIERS[:warm])
        expect(Legion::JSON.load(archived[:data])).to include(id: legacy_id, execution_key: nil)
      end

      it 'archives ordinary non-task rows using their age and batch limit' do
        @database.create_table(:warm_items) do
          primary_key :id
          String :value
          DateTime :created_at
        end
        old = Time.now - (120 * 86_400)
        first_id = @database[:warm_items].insert(value: 'first', created_at: old)
        second_id = @database[:warm_items].insert(value: 'second', created_at: old)
        recent_id = @database[:warm_items].insert(value: 'recent', created_at: Time.now)

        expect(described_class.archive_to_warm(table: :warm_items, batch_size: 1)).to eq(archived: 1, table: 'warm_items')

        expect(@database[:warm_items].select_map(:id)).to contain_exactly(second_id, recent_id)
        archived = @database[:data_archive].where(source_table: 'warm_items', source_id: first_id).first
        expect(Legion::JSON.load(archived[:data])).to include(id: first_id, value: 'first')
        expect(archived[:tier]).to eq(described_class::TIERS[:warm])
      end
    end
  end

  describe '.export_to_cold' do
    it 'returns zero when no archive table' do
      conn = Legion::Data.connection
      allow(conn).to receive(:table_exists?).with(:data_archive).and_return(false)
      result = described_class.export_to_cold
      expect(result[:exported]).to eq(0)
    end
  end
end
