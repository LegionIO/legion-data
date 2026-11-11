# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'securerandom'

RSpec.describe 'Apollo embedding and ownership migration' do
  let(:postgres) { ENV.fetch('LEGION_DATA_ADAPTER', 'sqlite') == 'postgres' }
  let(:db) { @database }
  let(:migration_path) { File.expand_path('../../../lib/legion/data/migrations', __dir__) }
  let(:vector) { Array.new(1024, 0.125) }

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
    begin
      @database&.disconnect
      @database_admin.run("DROP DATABASE #{@database_admin.literal(Sequel.identifier(@database_name))}") if created_database
    ensure
      @database_admin&.disconnect
    end
  end

  before do
    Sequel::Migrator.run(db, migration_path, target: 139)
  end

  def apollo_insert(table: :apollo_entries, **attributes)
    db[table].insert({ content: 'Original knowledge', content_type: 'fact', source_agent: 'migration-spec' }.merge(attributes))
  end

  def apollo_index_names(table: :apollo_entries)
    if postgres
      db[:pg_indexes].where(schemaname: 'public', tablename: table.to_s).select_map(:indexname)
    else
      db[:sqlite_master].where(type: 'index', tbl_name: table.to_s).select_map(:name)
    end
  end

  it 'preserves historical records, hashes and native vectors without inventing legacy metadata' do
    embedding = postgres ? { embedding: JSON.generate(vector) } : {}
    apollo_insert(content_hash: 'a' * 64, access_scope: 'private', identity_principal_id: 41, **embedding)
    apollo_insert(table: :apollo_entries_archive, content_hash: 'a' * 64, access_scope: 'private', identity_principal_id: 41, **embedding)
    snapshots = %i[apollo_entries apollo_entries_archive].to_h { |table| [table, db[table].all] }

    Sequel::Migrator.run(db, migration_path, target: 150)

    snapshots.each do |table, rows|
      expect(db[table].all).to eq(rows.map do |row|
        row.merge(embedding_space_id: nil, embedding_dimensions: nil, embedding_provenance: nil)
           .merge(postgres ? {} : { embedding: nil })
      end)
    end
    expect(db[:schema_info].get(:version)).to eq(150)
  end

  context 'with SQLite', if: ENV.fetch('LEGION_DATA_ADAPTER', 'sqlite') == 'sqlite' do
    it 'preserves manually stored vectors and global uniqueness if the active storage migration collides' do
      db.alter_table(:apollo_entries) { add_column :embedding, String, text: true }
      id = apollo_insert(content_hash: 'legacy', embedding: JSON.generate(vector), access_scope: 'team')
      snapshot = db[:apollo_entries][id: id]

      expect { Sequel::Migrator.run(db, migration_path, target: 150) }.to raise_error(Sequel::DatabaseError)

      expect(db[:schema_info].get(:version)).to eq(139)
      expect(db[:apollo_entries][id: id]).to eq(snapshot)
      expect { apollo_insert(content_hash: 'legacy', access_scope: 'private') }.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it 'retains the committed active storage change when the separate archive storage migration collides' do
      active_id = apollo_insert(content_hash: 'active')
      db.alter_table(:apollo_entries_archive) { add_column :embedding, String, text: true }
      archive_id = apollo_insert(table: :apollo_entries_archive, content_hash: 'archive', embedding: JSON.generate(vector))
      archive_snapshot = db[:apollo_entries_archive][id: archive_id]

      expect { Sequel::Migrator.run(db, migration_path, target: 150) }.to raise_error(Sequel::DatabaseError)

      expect(db[:schema_info].get(:version)).to eq(140)
      expect(db[:apollo_entries][id: active_id]).to include(content_hash: 'active', embedding: nil)
      expect(db[:apollo_entries_archive][id: archive_id]).to eq(archive_snapshot)
    end
  end

  it 'round trips 1024-dimensional vectors and explicit provenance in both tables and queries by embedding space' do
    Sequel::Migrator.run(db, migration_path, target: 150)
    spaces = %w[a b]

    %i[apollo_entries apollo_entries_archive].each do |table|
      spaces.each do |space|
        provenance = { space_id: space * 64, dimensions: 1024, provider: 'test', model: "fixture-#{space}" }
        id = apollo_insert(table: table, embedding: JSON.generate(vector), embedding_dimensions: 1024,
                           embedding_space_id: provenance[:space_id], embedding_provenance: JSON.generate(provenance))
        row = db[table][id: id]

        expect(JSON.parse(row[:embedding])).to eq(vector)
        stored_provenance = row[:embedding_provenance]
        stored_provenance = if stored_provenance.is_a?(String)
                              JSON.parse(stored_provenance, symbolize_names: true)
                            else
                              stored_provenance.transform_keys(&:to_sym)
                            end
        expect(stored_provenance).to eq(provenance)
        expect(row).to include(embedding_dimensions: 1024, embedding_space_id: provenance[:space_id])
        expect(db[table].where(embedding_space_id: provenance[:space_id], embedding_dimensions: 1024,
                               status: 'candidate').select_map(:id)).to eq([id])
      end
    end
  end

  it 'reverses metadata independently without erasing stored vectors and can reapply the additions' do
    Sequel::Migrator.run(db, migration_path, target: 141)
    apollo_insert(content_hash: 'active', embedding: JSON.generate(vector))
    apollo_insert(table: :apollo_entries_archive, content_hash: 'archive', embedding: JSON.generate(vector))
    snapshots = %i[apollo_entries apollo_entries_archive].to_h { |table| [table, db[table].all] }
    Sequel::Migrator.run(db, migration_path, target: 150)
    %i[apollo_entries apollo_entries_archive].each do |table|
      db[table].update(embedding_space_id: 'a' * 64, embedding_dimensions: 1024,
                       embedding_provenance: JSON.generate(provider: 'test', model: 'fixture'))
    end

    Sequel::Migrator.run(db, migration_path, target: 141)

    snapshots.each do |table, rows|
      expect(db[table].all).to eq(rows)
    end
    expect(db[:schema_info].get(:version)).to eq(141)

    Sequel::Migrator.run(db, migration_path, target: 150)

    %i[apollo_entries apollo_entries_archive].each do |table|
      expect(JSON.parse(db[table].get(:embedding))).to eq(vector)
      expect(db[table].first).to include(embedding_space_id: nil, embedding_dimensions: nil, embedding_provenance: nil)
    end
  end

  it 'keeps global deduplication enforced through replacement-index failure, rollback and resume' do
    attributes = { content_hash: 'unchanged', access_scope: 'private', identity_principal_id: 41 }
    apollo_insert(**attributes)
    Sequel::Migrator.run(db, migration_path, target: 148)
    db.add_index(:apollo_entries, :source_agent, name: :idx_apollo_content_hash_owner)
    snapshot = db[:apollo_entries].all

    expect { Sequel::Migrator.run(db, migration_path, target: 150) }.to raise_error(Sequel::DatabaseError)
    expect(db[:schema_info].get(:version)).to eq(148)
    expect(db[:apollo_entries].all).to eq(snapshot)
    expect { apollo_insert(**attributes, identity_principal_id: 42) }.to raise_error(Sequel::UniqueConstraintViolation)

    db.drop_index(:apollo_entries, :source_agent, name: :idx_apollo_content_hash_owner)
    Sequel::Migrator.run(db, migration_path, target: 149)
    expect { apollo_insert(**attributes, identity_principal_id: 42) }.to raise_error(Sequel::UniqueConstraintViolation)
    Sequel::Migrator.run(db, migration_path, target: 148)
    expect { apollo_insert(**attributes, identity_principal_id: 42) }.to raise_error(Sequel::UniqueConstraintViolation)

    Sequel::Migrator.run(db, migration_path, target: 150)
    apollo_insert(**attributes, identity_principal_id: 42)
    expect { apollo_insert(**attributes) }.to raise_error(Sequel::UniqueConstraintViolation)
    expect(db[:apollo_entries].where(content_hash: 'unchanged').select_map(:identity_principal_id)).to contain_exactly(41, 42)
  end

  it 'rejects same-owner active duplicates but permits the unchanged hash across owners and scopes' do
    content_hash = 'b' * 64
    apollo_insert(content_hash: content_hash, access_scope: 'private', identity_principal_id: 41)
    Sequel::Migrator.run(db, migration_path, target: 150)

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

  it 'normalizes global owners while keeping restricted NULL owners separate from real owners' do
    apollo_insert(content_hash: 'legacy-owner', access_scope: 'private', identity_principal_id: nil)
    Sequel::Migrator.run(db, migration_path, target: 150)

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
    Sequel::Migrator.run(db, migration_path, target: 150)

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
    Sequel::Migrator.run(db, migration_path, target: 150)
    ids = Array.new(2) { apollo_insert(content_hash: nil, access_scope: 'private', identity_principal_id: 41) }

    expect(db[:apollo_entries].where(content_hash: nil).select_map(:id)).to match_array(ids)
    expect(apollo_index_names).to include('idx_apollo_source_agent', 'idx_apollo_embedding_space_dimensions')
  end

  it 'safely downgrades to the original schema and restores global uniqueness without changing historical records' do
    embedding = postgres ? { embedding: JSON.generate(vector) } : {}
    apollo_insert(content_hash: 'rollback', access_scope: 'private', identity_principal_id: 41, **embedding)
    apollo_insert(table: :apollo_entries_archive, content_hash: 'rollback', **embedding)
    snapshots = %i[apollo_entries apollo_entries_archive].to_h { |table| [table, db[table].all] }
    columns = snapshots.to_h { |table, _rows| [table, db.schema(table).map(&:first)] }
    Sequel::Migrator.run(db, migration_path, target: 150)

    Sequel::Migrator.run(db, migration_path, target: 139)

    expect(db[:schema_info].get(:version)).to eq(139)
    snapshots.each do |table, rows|
      expect(db[table].all).to eq(rows)
      expect(db.schema(table, reload: true).map(&:first)).to eq(columns.fetch(table))
    end
    expect(apollo_index_names).to include('idx_apollo_content_hash')
    expect(apollo_index_names).not_to include('idx_apollo_content_hash_owner', 'idx_apollo_embedding_space_dimensions')
    expect do
      apollo_insert(content_hash: 'rollback', access_scope: 'team', identity_principal_id: 42)
    end.to raise_error(Sequel::UniqueConstraintViolation)
    apollo_insert(content_hash: 'rollback', status: 'archived')
    expect(db[:apollo_entries].where(content_hash: 'rollback').count).to eq(2)
  end

  it 'retains records, scoped uniqueness and version when old uniqueness cannot be restored, then rolls back after reconciliation' do
    Sequel::Migrator.run(db, migration_path, target: 150)
    content_hash = 'c' * 64
    attributes = { content_hash: content_hash, access_scope: 'private', embedding: JSON.generate(vector),
                   embedding_space_id: 'a' * 64, embedding_dimensions: 1024,
                   embedding_provenance: JSON.generate(provider: 'test', model: 'fixture') }
    apollo_insert(**attributes, identity_principal_id: 41)
    duplicate_id = apollo_insert(**attributes, identity_principal_id: 42)
    apollo_insert(table: :apollo_entries_archive, **attributes, identity_principal_id: 41)
    snapshots = %i[apollo_entries apollo_entries_archive].to_h { |table| [table, db[table].order(:id).all] }

    expect { Sequel::Migrator.run(db, migration_path, target: 149) }.to raise_error(Sequel::UniqueConstraintViolation)

    expect(db[:schema_info].get(:version)).to eq(150)
    snapshots.each do |table, rows|
      expect(db[table].order(:id).all).to eq(rows)
    end
    expect(apollo_index_names).to include('idx_apollo_content_hash_owner')
    expect(apollo_index_names).not_to include('idx_apollo_content_hash')
    expect { apollo_insert(**attributes, identity_principal_id: 41) }.to raise_error(Sequel::UniqueConstraintViolation)

    db[:apollo_entries].where(id: duplicate_id).update(status: 'archived')
    Sequel::Migrator.run(db, migration_path, target: 139)

    expect(db[:schema_info].get(:version)).to eq(139)
    expect(db[:apollo_entries].where(content_hash: content_hash).select_map(%i[identity_principal_id status])).to contain_exactly(
      [41, 'candidate'], [42, 'archived']
    )
    expect(db[:apollo_entries_archive].get(:content_hash)).to eq(content_hash)
    expect(apollo_index_names).to include('idx_apollo_content_hash')
    expect(apollo_index_names).not_to include('idx_apollo_content_hash_owner')
    expect do
      apollo_insert(content_hash: content_hash, access_scope: 'private', identity_principal_id: 43)
    end.to raise_error(Sequel::UniqueConstraintViolation)
  end

  context 'with PostgreSQL', if: ENV['LEGION_DATA_ADAPTER'] == 'postgres' do
    it 'retains vector(1024) and all canonical and operator ANN indexes unchanged across upgrade and downgrade' do
      tables = %i[apollo_entries apollo_entries_archive]
      tables.each do |table|
        apollo_insert(table: table, embedding: JSON.generate(vector))
        db.add_index(table, :embedding, name: "spec_#{table}_direct", type: :hnsw, opclass: :vector_cosine_ops)
        db.add_index(table, :embedding, name: "spec_#{table}_partial", type: :hnsw, opclass: :vector_cosine_ops,
                     where: { Sequel.function(:vector_dims, :embedding) => 1024 })
        db.add_index(table, Sequel.cast(Sequel.function(:subvector, :embedding, 1, 1024), 'vector(1024)'),
                     name: "spec_#{table}_expression", type: :hnsw, opclass: :vector_cosine_ops,
                     where: { Sequel.function(:vector_dims, :embedding) => 1024 })
      end
      indexes = db[:pg_indexes].where(schemaname: 'public', tablename: tables.map(&:to_s))
                               .where(Sequel.like(:indexdef, '% USING hnsw %'))
                               .select(:indexname, :indexdef).order(:indexname)
      original_indexes = indexes.all
      expect(original_indexes.map { |index| index[:indexname] }).to include(
        'idx_apollo_entries_embedding', 'idx_apollo_embedding_active', 'apollo_entries_archive_embedding_idx'
      )

      [150, 139].each do |target|
        Sequel::Migrator.run(db, migration_path, target: target)

        expect(indexes.all).to eq(original_indexes)
        tables.each do |table|
          column_type = db[:pg_attribute].where(attrelid: Sequel.cast(table.to_s, :regclass), attname: 'embedding')
                                         .get(Sequel.function(:format_type, :atttypid, :atttypmod))
          expect(column_type).to eq('vector(1024)')
          expect(JSON.parse(db[table].get(:embedding))).to eq(vector)
          expect(db[table].get(Sequel.function(:vector_dims, :embedding))).to eq(1024)
        end
      end
    end

    it 'rejects non-1024-dimensional native writes after upgrade without altering stored vectors' do
      Sequel::Migrator.run(db, migration_path, target: 150)

      %i[apollo_entries apollo_entries_archive].each do |table|
        apollo_insert(table: table, embedding: JSON.generate(vector), embedding_dimensions: 1024)
        snapshot = db[table].all

        expect do
          apollo_insert(table: table, embedding: '[0.25,0.75]', embedding_dimensions: 2)
        end.to raise_error(Sequel::DatabaseError)
        expect do
          db[table].update(embedding: JSON.generate(Array.new(1025, 0.125)))
        end.to raise_error(Sequel::DatabaseError)
        expect(db[table].all).to eq(snapshot)
      end
    end
  end
end
