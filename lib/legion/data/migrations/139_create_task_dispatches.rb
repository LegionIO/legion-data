# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:task_dispatches) do
      primary_key :id
      String :uuid, size: 36, null: false, unique: true
      String :access_scope, size: 20, null: false, default: 'global', index: true
      foreign_key :identity_principal_id, :identity_principals, null: true, on_delete: :set_null, on_update: :cascade
      foreign_key :identity_id, :identities, null: true, on_delete: :set_null, on_update: :cascade
      String :identity_canonical_name, size: 255, null: true, index: true
      foreign_key :task_id, :tasks, null: true, on_delete: :set_null
      String :event_key, size: 255, null: false, unique: true
      String :message_type, size: 64, null: false
      String :options, text: true, null: false
      String :owner, size: 255, null: true
      String :token, size: 36, null: true
      String :status, size: 64, null: false
      DateTime :lease_until, null: true
      DateTime :delivered_at, null: true
      Integer :delivery_attempts, null: false, default: 0
      String :last_error, text: true, null: true
      DateTime :discarded_at, null: true
      String :discard_reason, text: true, null: true
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :inserted_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: true
      index :identity_principal_id
      index :task_id
      index %i[delivered_at lease_until]
    end
  end
end
