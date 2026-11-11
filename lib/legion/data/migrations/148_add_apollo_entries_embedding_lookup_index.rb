# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:apollo_entries) do
      add_index %i[embedding_space_id embedding_dimensions status], name: :idx_apollo_embedding_space_dimensions
    end
  end
end
