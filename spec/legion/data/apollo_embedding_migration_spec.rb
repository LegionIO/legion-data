# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'Apollo embedding and ownership migration' do
  let(:db) { Sequel.sqlite }
  let(:migration_path) { File.expand_path('../../../lib/legion/data/migrations', __dir__) }

  before do
    Sequel::Migrator.run(db, migration_path, target: 138)
  end

  after do
    db.disconnect
  end

  def apollo_insert(table: :apollo_entries, **attributes)
    db[table].insert({ content: 'Original knowledge', content_type: 'fact', source_agent: 'migration-spec' }.merge(attributes))
  end

  def apollo_upgrade(**)
    Sequel::Migrator.run(db, migration_path, target: 139)
  end

  it 'upgrades the real version 138 tables without changing existing records or inventing provenance' do
    apollo_insert(content_hash: 'a' * 64, access_scope: 'private', identity_principal_id: 41)
    apollo_insert(table: :apollo_entries_archive, content_hash: 'a' * 64, access_scope: 'private', identity_principal_id: 41)
    snapshots = %i[apollo_entries apollo_entries_archive].to_h { |table| [table, db[table].all] }

    apollo_upgrade

    snapshots.each do |table, rows|
      expect(db[table].all).to eq(rows.map do |row|
        row.merge(embedding: nil, embedding_space_id: nil, embedding_dimensions: nil, embedding_provenance: nil)
      end)
    end
    expect(db[:schema_info].get(:version)).to eq(139)
  end

  it 'preserves pre-existing SQLite vectors byte-for-byte without guessing their model' do
    %i[apollo_entries apollo_entries_archive].each do |table|
      db.alter_table(table) { add_column :embedding, String, text: true }
      apollo_insert(table: table, content_hash: 'legacy', embedding: '[0.25, 0.75, -0.5]', access_scope: 'team')
    end

    apollo_upgrade

    %i[apollo_entries apollo_entries_archive].each do |table|
      expect(db[table].first).to include(embedding: '[0.25, 0.75, -0.5]', content_hash: 'legacy', access_scope: 'team',
                                         identity_principal_id: nil, embedding_space_id: nil, embedding_dimensions: nil,
                                         embedding_provenance: nil)
    end
  end

  it 'stores different vector dimensions and explicit provenance in both tables' do
    apollo_upgrade
    vectors = [[0.25, 0.75], [0.25, 0.75, -0.5]]

    %i[apollo_entries apollo_entries_archive].each do |table|
      vectors.each do |vector|
        provenance = { space_id: vector.length.to_s * 64, dimensions: vector.length, provider: 'test', model: 'fixture' }
        id = apollo_insert(table: table, embedding: JSON.generate(vector), embedding_dimensions: vector.length,
                           embedding_space_id: provenance[:space_id], embedding_provenance: JSON.generate(provenance))
        row = db[table][id: id]
        expect(JSON.parse(row[:embedding])).to eq(vector)
        expect(JSON.parse(row[:embedding_provenance], symbolize_names: true)).to eq(provenance)
        expect(row).to include(embedding_dimensions: vector.length, embedding_space_id: provenance[:space_id])
      end
    end
  end

  it 'rejects same-owner active duplicates but permits the unchanged hash across owners and scopes' do
    apollo_insert(content_hash: 'unchanged', access_scope: 'private', identity_principal_id: 41)
    apollo_upgrade

    apollo_insert(content_hash: 'unchanged', access_scope: 'private', identity_principal_id: 42)
    apollo_insert(content_hash: 'unchanged', access_scope: 'team', identity_principal_id: 41)
    apollo_insert(content_hash: 'unchanged', access_scope: 'global', identity_principal_id: 41)
    expect do
      apollo_insert(content_hash: 'unchanged', access_scope: 'private', identity_principal_id: 41, status: 'confirmed')
    end.to raise_error(Sequel::UniqueConstraintViolation)
    expect(db[:apollo_entries].select_map(%i[content_hash access_scope identity_principal_id])).to contain_exactly(
      ['unchanged', 'private', 41], ['unchanged', 'private', 42], ['unchanged', 'team', 41], ['unchanged', 'global', 41]
    )
  end

  it 'normalizes global owners while keeping legacy restricted NULL owners separate from real owners' do
    apollo_insert(content_hash: 'legacy-owner', access_scope: 'private', identity_principal_id: nil)
    apollo_upgrade

    apollo_insert(content_hash: 'legacy-owner', access_scope: 'private', identity_principal_id: 41)
    apollo_insert(content_hash: 'legacy-owner', access_scope: 'team', identity_principal_id: nil)
    apollo_insert(content_hash: 'legacy-owner', access_scope: 'global', identity_principal_id: nil)
    expect do
      apollo_insert(content_hash: 'legacy-owner', access_scope: 'private', identity_principal_id: nil)
    end.to raise_error(Sequel::UniqueConstraintViolation)
    expect do
      apollo_insert(content_hash: 'legacy-owner', access_scope: 'global', identity_principal_id: 42)
    end.to raise_error(Sequel::UniqueConstraintViolation)
    expect(db[:apollo_entries].where(content_hash: 'legacy-owner').count).to eq(4)
  end

  it 'allows archived copies and enforces active uniqueness when restoring one' do
    active_id = apollo_insert(content_hash: 'archived-copy', access_scope: 'team', identity_principal_id: 41)
    apollo_upgrade

    archived_id = apollo_insert(content_hash: 'archived-copy', access_scope: 'team', identity_principal_id: 41, status: 'archived')
    2.times do
      apollo_insert(table: :apollo_entries_archive, content_hash: 'archived-copy', access_scope: 'team', identity_principal_id: 41)
    end
    expect do
      db[:apollo_entries].where(id: archived_id).update(status: 'confirmed')
    end.to raise_error(Sequel::UniqueConstraintViolation)

    db[:apollo_entries].where(id: active_id).update(status: 'archived')
    db[:apollo_entries].where(id: archived_id).update(status: 'confirmed')
    expect(db[:apollo_entries].where(content_hash: 'archived-copy', status: 'confirmed').select_map(:id)).to eq([archived_id])
    expect(db[:apollo_entries_archive].where(content_hash: 'archived-copy').count).to eq(2)
  end

  it 'does not deduplicate missing hashes or remove unrelated indexes' do
    apollo_upgrade
    ids = Array.new(2) { apollo_insert(content_hash: nil, access_scope: 'private', identity_principal_id: 41) }

    expect(db[:apollo_entries].where(content_hash: nil).select_map(:id)).to match_array(ids)
    index_names = db[:sqlite_master].where(type: 'index', tbl_name: 'apollo_entries').select_map(:name)
    expect(index_names).to include('idx_apollo_source_agent', 'idx_apollo_embedding_space_dimensions')
  end

  it 'refuses downgrade without changing the records or schema version' do
    apollo_upgrade
    apollo_insert(content_hash: 'two-owners', access_scope: 'private', identity_principal_id: 41, embedding: '[1,2]')
    apollo_insert(content_hash: 'two-owners', access_scope: 'private', identity_principal_id: 42, embedding: '[1,2,3]')
    snapshots = db[:apollo_entries].all

    expect { Sequel::Migrator.run(db, migration_path, target: 138) }.to raise_error(Sequel::Error)
    expect(db[:apollo_entries].all).to eq(snapshots)
    expect(db[:schema_info].get(:version)).to eq(139)
  end
end
