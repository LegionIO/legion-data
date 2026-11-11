# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'securerandom'

RSpec.describe 'Apollo embedding and ownership migration' do
  let(:postgres) { ENV.fetch('LEGION_DATA_ADAPTER', 'sqlite') == 'postgres' }
  let(:db) { @database }
  let(:migration_path) { File.expand_path('../../../lib/legion/data/migrations', __dir__) }

  around do |example|
    if postgres
      options = {
        adapter:  :postgres,
        host:     ENV.fetch('LEGION_DATA_HOST'),
        port:     Integer(ENV.fetch('LEGION_DATA_PORT', '5432')),
        user:     ENV.fetch('LEGION_DATA_USER'),
        password: ENV.fetch('LEGION_DATA_PASSWORD', ''),
        database: ENV.fetch('LEGION_DATA_DATABASE')
      }
      @database_admin = Sequel.connect(options)
      @database_name = "legion_apollo_spec_#{SecureRandom.hex(8)}"
      @database_admin.run("CREATE DATABASE #{@database_admin.literal(Sequel.identifier(@database_name))}")
      created_database = true
      @database = Sequel.connect(options.merge(database: @database_name))
    else
      @database = Sequel.sqlite
    end
    example.run
  ensure
    @database&.disconnect
    @database_admin.run("DROP DATABASE #{@database_admin.literal(Sequel.identifier(@database_name))}") if created_database
    @database_admin&.disconnect
  end

  before do
    Sequel::Migrator.run(db, migration_path, target: 139)
  end

  def apollo_insert(table: :apollo_entries, **attributes)
    db[table].insert({ content: 'Original knowledge', content_type: 'fact', source_agent: 'migration-spec' }.merge(attributes))
  end

  def apollo_upgrade(**)
    Sequel::Migrator.run(db, migration_path, target: 155)
  end

  it 'upgrades the real version 139 tables without changing existing records or inventing provenance' do
    embedding = postgres ? { embedding: JSON.generate(Array.new(1024, 0.125)) } : {}
    apollo_insert(content_hash: 'a' * 64, access_scope: 'private', identity_principal_id: 41, **embedding)
    apollo_insert(table: :apollo_entries_archive, content_hash: 'a' * 64, access_scope: 'private', identity_principal_id: 41, **embedding)
    snapshots = %i[apollo_entries apollo_entries_archive].to_h { |table| [table, db[table].all] }

    apollo_upgrade

    snapshots.each do |table, rows|
      expect(db[table].all).to eq(rows.map do |row|
        row.merge(embedding_space_id: nil, embedding_dimensions: postgres ? 1024 : nil, embedding_provenance: nil)
           .merge(postgres ? {} : { embedding: nil })
      end)
    end
    expect(db[:schema_info].get(:version)).to eq(155)
  end

  context 'with SQLite', if: ENV.fetch('LEGION_DATA_ADAPTER', 'sqlite') == 'sqlite' do
    it 'fails cleanly when a manually added embedding column already exists' do
      %i[apollo_entries apollo_entries_archive].each do |table|
        db.alter_table(table) { add_column :embedding, String, text: true }
        apollo_insert(table: table, content_hash: 'legacy', embedding: '[0.25, 0.75, -0.5]', access_scope: 'team')
      end

      expect { apollo_upgrade }.to raise_error(Sequel::DatabaseError)
      expect(db[:schema_info].get(:version)).to eq(142)
      expect(db[:apollo_entries].first).to include(embedding: '[0.25, 0.75, -0.5]', content_hash: 'legacy')
    end

    it 'keeps the active storage change when the separate archive storage migration fails' do
      active_id = apollo_insert(content_hash: 'active')
      db.alter_table(:apollo_entries_archive) { add_column :embedding, String, text: true }
      archive_id = apollo_insert(table: :apollo_entries_archive, content_hash: 'archive', embedding: '[0.25,0.75]')

      expect { apollo_upgrade }.to raise_error(Sequel::DatabaseError)

      expect(db[:schema_info].get(:version)).to eq(143)
      expect(db[:apollo_entries][id: active_id]).to include(content_hash: 'active', embedding: nil)
      expect(db[:apollo_entries_archive][id: archive_id]).to include(content_hash: 'archive', embedding: '[0.25,0.75]')
    end

    it 'reverses metadata additions independently without removing stored vectors' do
      Sequel::Migrator.run(db, migration_path, target: 144)
      apollo_insert(content_hash: 'active', embedding: '[0.25,0.75]')
      apollo_insert(table: :apollo_entries_archive, content_hash: 'archive', embedding: '[0.25,0.75,-0.5]')
      snapshots = %i[apollo_entries apollo_entries_archive].to_h { |table| [table, db[table].all] }

      Sequel::Migrator.run(db, migration_path, target: 153)
      Sequel::Migrator.run(db, migration_path, target: 144)

      snapshots.each do |table, rows|
        expect(db[table].all).to eq(rows)
      end
      expect(db[:schema_info].get(:version)).to eq(144)

      apollo_upgrade

      expect(db[:apollo_entries].get(:embedding)).to eq('[0.25,0.75]')
      expect(db[:apollo_entries_archive].get(:embedding)).to eq('[0.25,0.75,-0.5]')
    end
  end

  it 'keeps global deduplication enforced if creation of the replacement index fails' do
    attributes = { content_hash: 'unchanged', access_scope: 'private', identity_principal_id: 41 }
    apollo_insert(**attributes)
    Sequel::Migrator.run(db, migration_path, target: 153)
    db.add_index(:apollo_entries, :source_agent, name: :idx_apollo_content_hash_owner)

    expect { apollo_upgrade }.to raise_error(Sequel::DatabaseError)
    expect(db[:schema_info].get(:version)).to eq(153)
    expect { apollo_insert(**attributes, identity_principal_id: 42) }.to raise_error(Sequel::UniqueConstraintViolation)

    db.drop_index(:apollo_entries, :source_agent, name: :idx_apollo_content_hash_owner)
    Sequel::Migrator.run(db, migration_path, target: 154)
    expect { apollo_insert(**attributes, identity_principal_id: 42) }.to raise_error(Sequel::UniqueConstraintViolation)
    Sequel::Migrator.run(db, migration_path, target: 153)
    expect { apollo_insert(**attributes, identity_principal_id: 42) }.to raise_error(Sequel::UniqueConstraintViolation)

    apollo_upgrade
    apollo_insert(**attributes, identity_principal_id: 42)
    expect(db[:apollo_entries].where(content_hash: 'unchanged').select_map(:identity_principal_id)).to contain_exactly(41, 42)
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
    content_hash = 'b' * 64
    apollo_insert(content_hash: content_hash, access_scope: 'private', identity_principal_id: 41)
    apollo_upgrade

    apollo_insert(content_hash: content_hash, access_scope: 'private', identity_principal_id: 42)
    apollo_insert(content_hash: content_hash, access_scope: 'team', identity_principal_id: 41)
    apollo_insert(content_hash: content_hash, access_scope: 'global', identity_principal_id: 41)
    expect do
      apollo_insert(content_hash: content_hash, access_scope: 'private', identity_principal_id: 41, status: 'confirmed')
    end.to raise_error(Sequel::UniqueConstraintViolation)
    expect(db[:apollo_entries].select_map(%i[content_hash access_scope identity_principal_id])).to contain_exactly(
      [content_hash, 'private', 41], [content_hash, 'private', 42], [content_hash, 'team', 41], [content_hash, 'global', 41]
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
    expect(db.indexes(:apollo_entries).keys).to include(:idx_apollo_source_agent, :idx_apollo_embedding_space_dimensions)
  end

  it 'refuses downgrade without changing the records or schema version' do
    apollo_upgrade
    apollo_insert(content_hash: 'two-owners', access_scope: 'private', identity_principal_id: 41, embedding: '[1,2]')
    apollo_insert(content_hash: 'two-owners', access_scope: 'private', identity_principal_id: 42, embedding: '[1,2,3]')
    snapshots = db[:apollo_entries].all

    expect { Sequel::Migrator.run(db, migration_path, target: 154) }.to raise_error(Sequel::Error)
    expect(db[:apollo_entries].all).to eq(snapshots)
    expect(db[:schema_info].get(:version)).to eq(155)
  end

  context 'with PostgreSQL', if: ENV['LEGION_DATA_ADAPTER'] == 'postgres' do
    it 'preserves constrained expression indexes while allowing mixed native vector dimensions' do
      %i[apollo_entries apollo_entries_archive].each do |table|
        apollo_insert(table: table, embedding: JSON.generate(Array.new(1024, 0.125)))
        db.add_index(table, Sequel.cast(Sequel.function(:subvector, :embedding, 1, 1024), 'vector(1024)'),
                     name: "spec_#{table}_embedding", type: :hnsw, opclass: :vector_cosine_ops,
                     where: { Sequel.function(:vector_dims, :embedding) => 1024 })
      end

      apollo_upgrade

      %i[apollo_entries apollo_entries_archive].each do |table|
        expect(db[table].get(:embedding_dimensions)).to eq(1024)
        index_names = db[:pg_indexes].where(schemaname: 'public', tablename: table.to_s).select_map(:indexname)
        expect(index_names).to include("spec_#{table}_embedding")
        expect(index_names & %w[idx_apollo_entries_embedding idx_apollo_embedding_active apollo_entries_archive_embedding_idx]).to be_empty
        apollo_insert(table: table, embedding: '[1,2]', embedding_dimensions: 2)
        apollo_insert(table: table, embedding: '[1,2,3]', embedding_dimensions: 3)
        expect(db[table].select_map(Sequel.function(:vector_dims, :embedding))).to contain_exactly(1024, 2, 3)
      end
      distance = db[:apollo_entries].where(embedding_dimensions: 2).get(Sequel.lit("embedding <=> '[1,2]'::vector"))
      expect(distance).to be_within(0.000001).of(0)
    end

    it 'restores dropped indexes after a partial direct ANN index blocks widening and resumes after reconciliation' do
      apollo_insert(embedding: JSON.generate(Array.new(1024, 0.125)))
      snapshot = db[:apollo_entries].all
      db.add_index(:apollo_entries, :embedding, name: :spec_extra_ann, type: :hnsw, opclass: :vector_cosine_ops,
                   where: { Sequel.function(:vector_dims, :embedding) => 1024 })

      expect { apollo_upgrade }.to raise_error(Sequel::DatabaseError)
      expect(db[:schema_info].get(:version)).to eq(142)
      expect(db[:apollo_entries].all).to eq(snapshot)

      Sequel::Migrator.run(db, migration_path, target: 139)

      indexes = db[:pg_indexes].where(schemaname: 'public').to_hash(:indexname, :indexdef)
      %w[idx_apollo_entries_embedding idx_apollo_embedding_active apollo_entries_archive_embedding_idx].each do |name|
        expect(indexes.fetch(name)).to include('USING hnsw', 'vector_cosine_ops')
      end
      expect(indexes.fetch('idx_apollo_embedding_active')).to include('WHERE', 'candidate', 'confirmed', 'disputed')
      expect(db[:apollo_entries].all).to eq(snapshot)

      db.drop_index(:apollo_entries, :embedding, name: :spec_extra_ann)
      apollo_upgrade
      apollo_insert(embedding: '[1,2]', embedding_dimensions: 2)
      expect(db[:apollo_entries].select_map(Sequel.function(:vector_dims, :embedding))).to contain_exactly(1024, 2)
    end

    it 'requires reconciliation of a retained unfiltered direct ANN index before inserting new dimensions' do
      apollo_insert(embedding: JSON.generate(Array.new(1024, 0.125)))
      db.add_index(:apollo_entries, :embedding, name: :spec_extra_ann, type: :hnsw, opclass: :vector_cosine_ops)
      apollo_upgrade
      snapshot = db[:apollo_entries].all

      expect { apollo_insert(embedding: '[1,2]', embedding_dimensions: 2) }.to raise_error(Sequel::DatabaseError)
      expect(db[:apollo_entries].all).to eq(snapshot)

      db.drop_index(:apollo_entries, :embedding, name: :spec_extra_ann)
      apollo_insert(embedding: '[1,2]', embedding_dimensions: 2)
      expect(db[:apollo_entries].select_map(Sequel.function(:vector_dims, :embedding))).to contain_exactly(1024, 2)
    end

    it 'refuses backfill rollback without erasing application-written dimensions' do
      apollo_insert(embedding: JSON.generate(Array.new(1024, 0.125)))
      apollo_insert(table: :apollo_entries_archive, embedding: JSON.generate(Array.new(1024, 0.125)))
      Sequel::Migrator.run(db, migration_path, target: 151)
      apollo_insert(embedding: '[1,2]', embedding_dimensions: 2)
      active_rows = db[:apollo_entries].all

      expect { Sequel::Migrator.run(db, migration_path, target: 150) }.to raise_error(Sequel::Error)
      expect(db[:schema_info].get(:version)).to eq(151)
      expect(db[:apollo_entries].all).to eq(active_rows)
      expect(db[:apollo_entries_archive].get(:embedding_dimensions)).to be_nil

      Sequel::Migrator.run(db, migration_path, target: 152)
      apollo_insert(table: :apollo_entries_archive, embedding: '[1,2,3]', embedding_dimensions: 3)
      archive_rows = db[:apollo_entries_archive].all
      expect { Sequel::Migrator.run(db, migration_path, target: 151) }.to raise_error(Sequel::Error)
      expect(db[:schema_info].get(:version)).to eq(152)
      expect(db[:apollo_entries_archive].all).to eq(archive_rows)
    end
  end
end
