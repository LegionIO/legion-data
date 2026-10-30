# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:task_idempotency_claims) do
      String :idempotency_key, size: 64, null: false, primary_key: true
    end
  end
end
