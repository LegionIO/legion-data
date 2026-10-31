# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:tasks) do
      add_column :execution_key, String, size: 255, null: true
      add_index :execution_key, unique: true
      add_column :execution_token, String, size: 36, null: true
      add_column :execution_owner, String, size: 255, null: true
      add_column :execution_lease_until, DateTime, null: true, index: true
      add_column :attempt_count, Integer, null: false, default: 0
      add_column :lock_version, Integer, null: false, default: 0
      add_column :deadline_at, DateTime, null: true, index: true
      add_column :retry_at, DateTime, null: true, index: true
      add_column :completed_at, DateTime, null: true, index: true
      add_column :schedule_id, String, size: 255, null: true, index: true
      add_column :occurrence_id, String, size: 255, null: true, index: true
      add_column :transformation_result, String, text: true, null: true
    end
  end
end
