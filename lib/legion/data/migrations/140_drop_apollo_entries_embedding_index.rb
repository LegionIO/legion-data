# frozen_string_literal: true

Sequel.migration do
  up do
    if adapter_scheme == :postgres
      alter_table(:apollo_entries) do
        drop_index :embedding, name: :idx_apollo_entries_embedding
      end
    end
  end

  down do
    if adapter_scheme == :postgres
      alter_table(:apollo_entries) do
        add_index :embedding, name: :idx_apollo_entries_embedding, type: :hnsw, opclass: :vector_cosine_ops
      end
    end
  end
end
