# frozen_string_literal: true

require 'spec_helper'
require 'legion/data/storage_tiers'
require 'sequel/extensions/migration'

RSpec.describe Legion::Data::StorageTiers do
  around do |example|
    @database = Sequel.sqlite
    Sequel::Migrator.run(@database, File.expand_path('../../../lib/legion/data/migrations', __dir__))
    original_datasets = [Legion::Data::Model::Task, Legion::Data::Model::GovernanceEvent,
                         Legion::Data::Model::DataArchive].to_h { |model| [model, model.dataset] }
    original_datasets.each_key { |model| model.set_dataset(@database[model.table_name]) }
    example.run
  ensure
    original_datasets&.each { |model, dataset| model.set_dataset(dataset) }
    @database&.disconnect
  end

  describe '.archive_to_warm' do
    it 'returns zero when no connection' do
      allow(Legion::Data).to receive(:connected?).and_return(false)
      result = described_class.archive_to_warm(model: Legion::Data::Model::Task)
      expect(result).to eq(archived: 0, reason: 'no_connection')
    end

    it 'archives ordinary tasks using their age and batch limit' do
      old = Time.now - (120 * 86_400)
      first = Legion::Data::Model::Task.create(created: old, created_at: old, status: 'task.completed')
      second = Legion::Data::Model::Task.create(created: old, created_at: old, status: 'task.completed')
      recent = Legion::Data::Model::Task.create(created: Time.now, created_at: Time.now, status: 'task.completed')

      expect(described_class.archive_to_warm(model: Legion::Data::Model::Task, batch_size: 1)).to eq(archived: 1, table: 'tasks')

      expect(Legion::Data::Model::Task.select_map(:id)).to contain_exactly(second.id, recent.id)
      archived = Legion::Data::Model::DataArchive.first(source_table: 'tasks', source_id: first.id)
      expect(archived.tier).to eq(described_class::TIERS[:warm])
      expect(Legion::JSON.load(archived.data)).to include(id: first.id, status: 'task.completed')
    end

    it 'archives another registered source model without losing row values' do
      old = Time.now - (120 * 86_400)
      first = Legion::Data::Model::GovernanceEvent.create(stream_id: 'first', event_type: 'test', sequence_number: 1,
                                                          data_json: '{"value":"original"}', created_at: old)
      second = Legion::Data::Model::GovernanceEvent.create(stream_id: 'second', event_type: 'test', sequence_number: 1, created_at: old)
      recent = Legion::Data::Model::GovernanceEvent.create(stream_id: 'recent', event_type: 'test', sequence_number: 1, created_at: Time.now)

      expect(described_class.archive_to_warm(model: Legion::Data::Model::GovernanceEvent, batch_size: 1))
        .to eq(archived: 1, table: 'governance_events')
      expect(Legion::Data::Model::GovernanceEvent.select_map(:id)).to contain_exactly(second.id, recent.id)
      archived = Legion::Data::Model::DataArchive.first(source_table: 'governance_events', source_id: first.id)
      expect(Legion::JSON.load(archived.data)).to include(id: first.id, stream_id: 'first', data_json: '{"value":"original"}')
      expect(archived.tier).to eq(described_class::TIERS[:warm])
    end

    it 'rolls back the entire move when an archive insert fails' do
      old = Time.now - (120 * 86_400)
      first = Legion::Data::Model::Task.create(created: old, created_at: old, status: 'task.completed')
      second = Legion::Data::Model::Task.create(created: old, created_at: old, status: 'task.completed')
      @database.run("CREATE TRIGGER reject_archive BEFORE INSERT ON data_archive WHEN NEW.source_id = #{second.id} " \
                    "BEGIN SELECT RAISE(ABORT, 'archive rejected'); END")

      expect { described_class.archive_to_warm(model: Legion::Data::Model::Task) }.to raise_error(Sequel::DatabaseError, /archive rejected/)
      expect(Legion::Data::Model::Task.select_map(:id)).to contain_exactly(first.id, second.id)
      expect(Legion::Data::Model::DataArchive.count).to eq(0)
    end
  end

  describe '.export_to_cold' do
    it 'returns zero when disconnected' do
      allow(Legion::Data).to receive(:connected?).and_return(false)
      expect(described_class.export_to_cold).to eq(exported: 0)
    end

    it 'returns plain archived hashes and moves only eligible warm rows to cold' do
      old = Time.now - (400 * 86_400)
      eligible = Legion::Data::Model::DataArchive.create(source_table: 'tasks', source_id: 1, data: '{"status":"task.completed"}',
                                                         tier: described_class::TIERS[:warm], archived_at: old)
      recent = Legion::Data::Model::DataArchive.create(source_table: 'tasks', source_id: 2, data: '{}',
                                                       tier: described_class::TIERS[:warm], archived_at: Time.now)
      cold = Legion::Data::Model::DataArchive.create(source_table: 'tasks', source_id: 3, data: '{}',
                                                     tier: described_class::TIERS[:cold], archived_at: old)

      result = described_class.export_to_cold

      expect(result).to eq(exported: 1, data: [eligible.values])
      expect(eligible.refresh.tier).to eq(described_class::TIERS[:cold])
      expect(recent.refresh.tier).to eq(described_class::TIERS[:warm])
      expect(cold.refresh.tier).to eq(described_class::TIERS[:cold])
      expect(described_class.stats).to eq(warm: 1, cold: 2)
    end
  end
end
