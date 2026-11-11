# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:apollo_entries) do
      add_column :embedding_space_id, String, size: 64, null: true
    end
  end
end
