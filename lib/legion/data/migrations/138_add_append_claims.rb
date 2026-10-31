# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:append_claims) do
      String :kind, size: 16, null: false
      String :stream_id, size: 255, null: false
      primary_key %i[kind stream_id]
    end
  end
end
