# frozen_string_literal: true

Sequel.migration do
  up do
    unless adapter_scheme == :postgres
      alter_table(:apollo_entries_archive) do
        add_column :embedding, String, text: true, null: true
      end
    end
  end

  down do
    unless adapter_scheme == :postgres
      alter_table(:apollo_entries_archive) do
        drop_column :embedding
      end
    end
  end
end
