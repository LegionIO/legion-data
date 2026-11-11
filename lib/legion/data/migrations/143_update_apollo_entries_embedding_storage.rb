# frozen_string_literal: true

Sequel.migration do
  up do
    if adapter_scheme == :postgres
      alter_table(:apollo_entries) do
        set_column_type :embedding, :vector, using: Sequel.cast(:embedding, :vector)
      end
    else
      alter_table(:apollo_entries) do
        add_column :embedding, String, text: true, null: true
      end
    end
  end

  down do
    raise Sequel::Error, 'Apollo embedding storage cannot be reversed without losing mixed-dimension vectors'
  end
end
