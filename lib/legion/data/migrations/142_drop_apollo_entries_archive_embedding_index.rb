# frozen_string_literal: true

Sequel.migration do
  up do
    if adapter_scheme == :postgres
      alter_table(:apollo_entries_archive) do
        drop_index :embedding, name: :apollo_entries_archive_embedding_idx
      end
    end
  end

  down do
    if adapter_scheme == :postgres
      alter_table(:apollo_entries_archive) do
        add_index :embedding, name: :apollo_entries_archive_embedding_idx, type: :hnsw, opclass: :vector_cosine_ops
      end
    end
  end
end
