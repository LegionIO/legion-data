# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:tasks) do
      add_column :execution_policy, String, text: true, null: true
    end
  end
end
