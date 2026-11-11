# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:apollo_entries) do
      drop_index :content_hash, name: :idx_apollo_content_hash
    end
  end

  down do
    raise Sequel::Error, 'Apollo content-hash uniqueness cannot be reversed without losing ownership-scoped records'
  end
end
