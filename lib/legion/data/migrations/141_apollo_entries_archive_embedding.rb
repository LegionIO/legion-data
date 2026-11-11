# frozen_string_literal: true

Sequel.migration do
  up do
    if adapter_scheme == :postgres
      # Mirror of migration 140 for the archive table: migration 047 copied
      # the 012 HNSW index into this table via LIKE INCLUDING ALL. Drop it
      # before widening the column to unconstrained vectors so
      # mixed-dimension inserts stay possible.
      drop_index(:apollo_entries_archive, :embedding, name: :apollo_entries_archive_embedding_idx)
      alter_table(:apollo_entries_archive) do
        set_column_type :embedding, :vector, using: 'embedding::vector'
        add_column :embedding_space_id, String, size: 64, null: true
        add_column :embedding_dimensions, Integer, null: true
        add_column :embedding_provenance, :jsonb, null: true
      end
      from(:apollo_entries_archive).exclude(embedding: nil).update(embedding_dimensions: Sequel.function(:vector_dims, :embedding))
    else
      alter_table(:apollo_entries_archive) do
        add_column :embedding, String, text: true, null: true
        add_column :embedding_space_id, String, size: 64, null: true
        add_column :embedding_dimensions, Integer, null: true
        add_column :embedding_provenance, String, text: true, null: true
      end
    end
  end

  down do
    raise Sequel::Error, 'Apollo embedding contracts cannot be reversed without losing vectors'
  end
end
