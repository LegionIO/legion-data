# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:apollo_entries) do
      drop_index :content_hash, name: :idx_apollo_content_hash
    end
  end

  down do
    alter_table(:apollo_entries) do
      add_index :content_hash, unique: true, name: :idx_apollo_content_hash,
                where: Sequel.~(status: 'archived')
    end
  end
end
