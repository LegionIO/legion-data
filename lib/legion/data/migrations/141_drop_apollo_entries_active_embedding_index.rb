# frozen_string_literal: true

Sequel.migration do
  up do
    if adapter_scheme == :postgres
      alter_table(:apollo_entries) do
        drop_index :embedding, name: :idx_apollo_embedding_active
      end
    end
  end

  down do
    if adapter_scheme == :postgres
      alter_table(:apollo_entries) do
        add_index :embedding, name: :idx_apollo_embedding_active, type: :hnsw, opclass: :vector_cosine_ops,
                              where: { status: %w[candidate confirmed disputed] }
      end
    end
  end
end
