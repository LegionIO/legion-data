# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Migrations' do
  # By the time spec_helper runs, Legion::Data.setup has auto-migrated to the latest version.
  # This spec verifies that all migrations applied cleanly and the final schema is coherent.

  let(:db) { Legion::Data::Connection.sequel }
  let(:migration_path) { File.expand_path('../../../lib/legion/data/migrations', __dir__) }

  before do
    skip 'no global database connection configured' if db.nil?
  end

  it 'has run all migrations to the latest version' do
    max_migration = Dir.glob(File.join(migration_path, '*.rb'))
                       .filter_map { |f| File.basename(f, '.rb')[/\A(\d+)/, 1]&.to_i }
                       .max
    raise 'no migrations found' unless max_migration

    # Sequel default is schema_migrations, but try common variants
    version_table = %i[schema_migrations schema_info sequel_migrations].find { |t| db.table_exists?(t) }
    skip "no migration version table found (#{db.adapter_scheme})" unless version_table

    applied = db[version_table].select_map(:version).map(&:to_i).sort
    expect(applied.last).to eq(max_migration)
  end

  it 'has all expected tables' do
    # Authoritative list of all tables that should exist after all migrations run.
    # Derived from the actual production schema, not from scanning migration files
    # (which can't track renames and drops correctly).
    expected_tables = %i[
      apollo_access_log apollo_entries apollo_entries_archive
      apollo_expertise apollo_operations apollo_relations
      audit_log audit_records chains
      conversations
      llm_conversation_compactions llm_conversations
      llm_message_inference_metrics llm_message_inference_requests
      llm_message_inference_responses llm_messages llm_policy_evaluations
      llm_registry_events llm_route_attempts
      llm_security_events llm_tool_call_attempts llm_tool_calls
      digital_workers extensions extensions_registry functions
      identities identity_audit_log identity_group_memberships
      identity_groups identity_principals identity_provider_capabilities
      identity_providers
      memory_associations memory_traces
      metering_hourly_rollup metering_records_archive
      rbac_cross_team_grants rbac_role_assignments rbac_runner_grants
      nodes relationships runners schema_info settings
      tasks tasks_archive tenants
      webhooks
    ]

    expected_tables.each do |table|
      exists = db.table_exists?(table)
      raise "expected table #{table} to exist" unless exists
    end
  end

  it 'has critical indexes on key tables' do
    critical_indexes = {
      llm_tool_calls: ['idx_tool_calls_identity_principal_id'],
      functions:      ['idx_functions_component_type']
    }

    critical_indexes.each do |table, index_names|
      indexes = if db.adapter_scheme == :postgres
                  db.indexes(table, include_partial: true).keys.map(&:to_s)
                else
                  db[:sqlite_master].where(type: 'index', tbl_name: table.to_s).select_map(:name)
                end

      index_names.each do |name|
        expect(indexes).to include(name), "expected index #{name} on #{table}"
      end
    end
  end
end
