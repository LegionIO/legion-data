# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Migration 047: apollo knowledge capture schema' do
  let(:db) { Legion::Data::Connection.sequel }

  before(:all) do
    migration_path = File.expand_path('../../lib/legion/data/migrations', __dir__)
    Sequel::Migrator.run(Legion::Data::Connection.sequel, migration_path, target: 47)
  end

  context 'when postgres', if: Legion::Data::Connection.adapter == :postgres do
    describe 'apollo_entries identity columns' do
      it 'has submitted_by column' do
        columns = db.schema(:apollo_entries).map(&:first)
        expect(columns).to include(:submitted_by)
      end

      it 'has submitted_from column' do
        columns = db.schema(:apollo_entries).map(&:first)
        expect(columns).to include(:submitted_from)
      end

      it 'has content_hash column' do
        columns = db.schema(:apollo_entries).map(&:first)
        expect(columns).to include(:content_hash)
      end
    end

    describe 'apollo_operations table' do
      it 'creates the table' do
        expect(db.table_exists?(:apollo_operations)).to be true
      end

      it 'has all required columns' do
        columns = db.schema(:apollo_operations).map(&:first)
        expect(columns).to include(
          :id, :operation, :actor, :target_type, :target_ids,
          :summary, :detail, :old_state, :new_state, :reason,
          :principal_id, :created_at
        )
      end
    end

    describe 'apollo_entries_archive table' do
      it 'creates the table' do
        expect(db.table_exists?(:apollo_entries_archive)).to be true
      end

      it 'has archived_at column' do
        columns = db.schema(:apollo_entries_archive).map(&:first)
        expect(columns).to include(:archived_at, :archive_reason)
      end
    end

    describe 'indexes' do
      it 'has partial HNSW index on active entries' do
        indexes = db.indexes(:apollo_entries)
        expect(indexes.keys.map(&:to_s)).to include('idx_apollo_embedding_active')
      end

      it 'has content hash unique index' do
        indexes = db.indexes(:apollo_entries)
        hash_idx = indexes[:idx_apollo_content_hash]
        expect(hash_idx).not_to be_nil
        expect(hash_idx[:unique]).to be true
      end
    end

    it 'is idempotent when run twice' do
      migration_path = File.expand_path('../../lib/legion/data/migrations', __dir__)
      expect do
        Sequel::Migrator.run(db, migration_path, target: 47)
      end.not_to raise_error
    end
  end

  context 'when not postgres', unless: Legion::Data::Connection.adapter == :postgres do
    it 'skips the migration silently' do
      expect(db.table_exists?(:apollo_operations)).to be false
    end
  end
end
