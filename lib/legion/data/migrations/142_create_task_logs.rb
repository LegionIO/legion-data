# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:task_logs) do
      primary_key :id
      String :uuid, size: 36, null: false, unique: true
      String :access_scope, size: 20, null: false, default: 'global', index: true
      foreign_key :identity_principal_id, :identity_principals, null: true, on_delete: :set_null, on_update: :cascade
      foreign_key :identity_id, :identities, null: true, on_delete: :set_null, on_update: :cascade
      String :identity_canonical_name, size: 255, null: true, index: true
      foreign_key :task_id, :tasks, null: true, on_delete: :set_null, on_update: :cascade
      foreign_key :node_id, :nodes, null: true, on_delete: :set_null, on_update: :cascade
      foreign_key :function_id, :functions, null: true, on_delete: :set_null, on_update: :cascade
      String :entry, text: true, null: false
      DateTime :created, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :inserted_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: true
      index :identity_principal_id
      index :task_id
      index :node_id
      index :function_id
      index :created
    end
  end
end
