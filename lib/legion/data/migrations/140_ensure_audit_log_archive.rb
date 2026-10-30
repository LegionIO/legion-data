# frozen_string_literal: true

Sequel.migration do
  up do
    next if table_exists?(:audit_log_archive)

    source_schema = schema(:audit_log).to_h
    create_table(:audit_log_archive) do
      source_schema.each do |name, info|
        column name, info[:db_type]
      end
      DateTime :archived_at, default: Sequel::CURRENT_TIMESTAMP
    end
  end

  down do
    raise Sequel::Error, 'Cannot remove audit_log_archive without deleting retained audit history'
  end
end
