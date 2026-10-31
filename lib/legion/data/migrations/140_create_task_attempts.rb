# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:task_attempts) do
      primary_key :id
      String :uuid, size: 36, null: false, unique: true
      String :access_scope, size: 20, null: false, default: 'global', index: true
      foreign_key :identity_principal_id, :identity_principals, null: true, on_delete: :set_null, on_update: :cascade
      foreign_key :identity_id, :identities, null: true, on_delete: :set_null, on_update: :cascade
      String :identity_canonical_name, size: 255, null: true, index: true
      foreign_key :task_id, :tasks, null: false, on_delete: :cascade
      Integer :number, null: false
      String :token, size: 36, null: false, unique: true
      String :owner, size: 255, null: false
      String :status, size: 255, null: false
      String :results, text: true, null: true
      DateTime :lease_until, null: false, index: true
      DateTime :finished_at, null: true
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :inserted_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, null: true
      index :identity_principal_id
      index %i[task_id number], unique: true
    end
  end
end
