# frozen_string_literal: true

require 'spec_helper'
require 'legion/data/storage_tiers'
require 'sequel/extensions/migration'

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
        @database = Sequel.sqlite
        begin
          Sequel::Migrator.run(@database, File.expand_path('../../../lib/legion/data/migrations', __dir__))
          Legion::Data::Connection.instance_variable_set(:@sequel, @database)
          Legion::Data::Connection.instance_variable_set(:@adapter, :sqlite)
          example.run
        ensure
          Legion::Data::Connection.instance_variable_set(:@sequel, original)
          Legion::Data::Connection.instance_variable_set(:@adapter, original_adapter)
          @database.disconnect
        end
      end

      it 'archives ordinary tasks using their age and batch limit' do
        old = Time.now - (120 * 86_400)
        legacy_id = @database[:tasks].insert(created: old, created_at: old, status: task_status(name: :completed))
        second_id = @database[:tasks].insert(created: old, created_at: old, status: task_status(name: :completed))
        recent_id = @database[:tasks].insert(created: Time.now, created_at: Time.now, status: task_status(name: :completed))

        expect(described_class.archive_to_warm(table: 'tasks', batch_size: 1)).to eq(archived: 1, table: 'tasks')

        expect(@database[:tasks].where(id: legacy_id).count).to eq(0)
        expect(@database[:tasks].select_map(:id)).to contain_exactly(second_id, recent_id)
        archived = @database[:data_archive].where(source_table: 'tasks', source_id: legacy_id).first
        expect(archived[:tier]).to eq(described_class::TIERS[:warm])
        expect(Legion::JSON.load(archived[:data])).to include(id: legacy_id, status: task_status(name: :completed))
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
