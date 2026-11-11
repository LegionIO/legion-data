# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:apollo_entries) do
      add_column :embedding_dimensions, Integer, null: true
    end
  end
end
