# frozen_string_literal: true

Sequel.migration do
  change do
    owner = Sequel.case({ { access_scope: 'global' } => 0 }, Sequel.function(:coalesce, :identity_principal_id, 0))
    alter_table(:apollo_entries) do
      add_index [:content_hash, :access_scope, owner],
                unique: true, name: :idx_apollo_content_hash_owner,
                where: Sequel.~(status: 'archived') & Sequel.~(content_hash: nil)
    end
  end
end
