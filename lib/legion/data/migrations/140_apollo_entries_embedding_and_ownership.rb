# frozen_string_literal: true

Sequel.migration do
  up do
    if adapter_scheme == :postgres
      # pgvector enforces a uniform vector dimension per HNSW/IVFFlat index.
      # Migration 012 created embedding as vector(1536) with a direct-column
      # ANN index, 041 resized it to vector(1024), and 047 added a partial
      # ANN index. Drop both before widening the column to unconstrained
      # vectors so mixed-dimension inserts stay possible; expression indexes
      # and indexes on other columns remain.
      drop_index(:apollo_entries, :embedding, name: :idx_apollo_entries_embedding)
      drop_index(:apollo_entries, :embedding, name: :idx_apollo_embedding_active)
      alter_table(:apollo_entries) do
        set_column_type :embedding, :vector, using: 'embedding::vector'
        add_column :embedding_space_id, String, size: 64, null: true
        add_column :embedding_dimensions, Integer, null: true
        add_column :embedding_provenance, :jsonb, null: true
      end
      from(:apollo_entries).exclude(embedding: nil).update(embedding_dimensions: Sequel.function(:vector_dims, :embedding))
    else
      alter_table(:apollo_entries) do
        add_column :embedding, String, text: true, null: true
        add_column :embedding_space_id, String, size: 64, null: true
        add_column :embedding_dimensions, Integer, null: true
        add_column :embedding_provenance, String, text: true, null: true
      end
    end

    # Ownership-scoped uniqueness: global knowledge has no owner, and legacy
    # restricted NULL owners occupy the owner-zero slot, never a real
    # principal's namespace. Active entries only; archived copies stay free.
    drop_index(:apollo_entries, :content_hash, name: :idx_apollo_content_hash)
    owner = Sequel.case({ { access_scope: 'global' } => 0 }, Sequel.function(:coalesce, :identity_principal_id, 0))
    add_index(:apollo_entries, %i[content_hash access_scope] + [owner],
              unique: true, name: :idx_apollo_content_hash_owner,
              where: Sequel.~(status: 'archived') & Sequel.~(content_hash: nil))
    alter_table(:apollo_entries) do
      add_index %i[embedding_space_id embedding_dimensions status], name: :idx_apollo_embedding_space_dimensions
    end
  end

  down do
    raise Sequel::Error, 'Apollo embedding and ownership contracts cannot be reversed without losing vectors or ownership-scoped records'
  end
end
