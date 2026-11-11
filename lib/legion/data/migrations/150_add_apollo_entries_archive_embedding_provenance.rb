# frozen_string_literal: true

Sequel.migration do
  up do
    provenance_type = adapter_scheme == :postgres ? :jsonb : :text
    alter_table(:apollo_entries_archive) do
      add_column :embedding_provenance, provenance_type, null: true
    end
  end

  down do
    alter_table(:apollo_entries_archive) do
      drop_column :embedding_provenance
    end
  end
end
