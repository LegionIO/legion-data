# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:tasks_archive) do
      add_column :function_id, Integer
      add_column :parent_id, Integer
      add_column :master_id, Integer
      add_column :payload, String, text: true
      add_column :worker_id, String, size: 36
      add_column :tenant_id, String, size: 64
      add_column :depth, Integer
      add_column :cancelled_at, DateTime
      add_column :task_delay, Integer
      add_column :created_at, DateTime
      add_column :idempotency_key, String, size: 64
      add_column :idempotency_expires_at, DateTime
    end
  end

  down do
    alter_table(:tasks_archive) do
      drop_column :function_id
      drop_column :parent_id
      drop_column :master_id
      drop_column :payload
      drop_column :worker_id
      drop_column :tenant_id
      drop_column :depth
      drop_column :cancelled_at
      drop_column :task_delay
      drop_column :created_at
      drop_column :idempotency_key
      drop_column :idempotency_expires_at
    end
  end
end
