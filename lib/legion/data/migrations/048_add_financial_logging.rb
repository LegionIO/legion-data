# frozen_string_literal: true

Sequel.migration do
  up do
    # 1. Identity — who owns the cost (worker, owner, cost center)
    unless table_exists?(:finlog_identities)
      create_table(:finlog_identities) do
        primary_key :id
        String :worker_id, size: 36, null: false
        String :owner_msid, size: 64, null: false
        String :owner_name, size: 255
        String :team, size: 255
        String :cost_center, size: 64
        String :department, size: 255
        String :business_segment, size: 64
        String :tenant_id, size: 64
        DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
        DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

        unique :worker_id, name: :idx_finlog_ident_worker
        index :owner_msid, name: :idx_finlog_ident_owner
        index :cost_center, name: :idx_finlog_ident_cost_center
        index :tenant_id, name: :idx_finlog_ident_tenant
      end
    end

    # 2. Asset — what Entra app / service principal generated the cost
    unless table_exists?(:finlog_assets)
      create_table(:finlog_assets) do
        primary_key :id
        String :worker_id, size: 36, null: false
        String :entra_app_id, size: 36
        String :entra_object_id, size: 36
        String :asset_name, size: 255, null: false
        String :asset_type, size: 64, null: false, default: 'extension'
        String :extension_name, size: 128
        String :risk_tier, size: 32
        String :tenant_id, size: 64
        DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
        DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

        index :worker_id, name: :idx_finlog_asset_worker
        index :entra_app_id, name: :idx_finlog_asset_entra
        index :asset_type, name: :idx_finlog_asset_type
        index :tenant_id, name: :idx_finlog_asset_tenant
      end
    end

    # 3. Environment — where the cost was incurred (cloud, region, account)
    unless table_exists?(:finlog_environments)
      create_table(:finlog_environments) do
        primary_key :id
        String :csp, size: 16, null: false
        String :account_id, size: 64, null: false
        String :account_name, size: 255
        String :askid, size: 64
        String :region, size: 64
        String :environment, size: 32, default: 'prod'
        String :subscription_id, size: 64
        String :resource_group, size: 255
        String :tenant_id, size: 64
        DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP

        index :csp, name: :idx_finlog_env_csp
        index :account_id, name: :idx_finlog_env_account
        index :askid, name: :idx_finlog_env_askid
        index %i[csp region], name: :idx_finlog_env_csp_region
        index :tenant_id, name: :idx_finlog_env_tenant
      end
    end

    # 4. Accounting — how the cost is classified financially
    unless table_exists?(:finlog_accounting)
      create_table(:finlog_accounting) do
        primary_key :id
        String :execution_id, size: 36, null: false
        String :aide_id, size: 64
        String :ucmg_id, size: 64
        String :billing_group, size: 128
        String :funding_source, size: 128
        String :classification, size: 16, null: false, default: 'expense'
        Float :recovery_ratio, default: 2.0
        Float :rate_card_multiplier, default: 1.28
        Float :provider_discount, default: 1.0
        Float :chargeback_amount, default: 0.0
        String :tenant_id, size: 64
        DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP

        index :execution_id, name: :idx_finlog_acct_exec
        index :aide_id, name: :idx_finlog_acct_aide
        index :ucmg_id, name: :idx_finlog_acct_ucmg
        index :billing_group, name: :idx_finlog_acct_billing
        index :classification, name: :idx_finlog_acct_class
        index :tenant_id, name: :idx_finlog_acct_tenant
      end
    end

    # 5. Execution — per-request/task execution record (central fact table)
    unless table_exists?(:finlog_executions)
      create_table(:finlog_executions) do
        primary_key :id
        String :execution_id, size: 36, null: false
        String :worker_id, size: 36, null: false
        Integer :task_id
        String :request_id, size: 64
        String :provider, size: 100, null: false
        String :model_id, size: 255, null: false
        Integer :input_tokens, default: 0
        Integer :output_tokens, default: 0
        Integer :thinking_tokens, default: 0
        Float :latency_ms, default: 0.0
        Float :raw_cost_usd, default: 0.0, null: false
        Float :discounted_cost_usd, default: 0.0
        Float :chargeback_usd, default: 0.0
        String :status, size: 32, default: 'completed'
        Integer :environment_id
        String :tenant_id, size: 64
        DateTime :started_at
        DateTime :completed_at
        DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP

        unique :execution_id, name: :idx_finlog_exec_id
        index :worker_id, name: :idx_finlog_exec_worker
        index :task_id, name: :idx_finlog_exec_task
        index :provider, name: :idx_finlog_exec_provider
        index :model_id, name: :idx_finlog_exec_model
        index :status, name: :idx_finlog_exec_status
        index :created_at, name: :idx_finlog_exec_created
        index %i[worker_id created_at], name: :idx_finlog_exec_worker_time
        index %i[provider model_id created_at], name: :idx_finlog_exec_prov_model_time
        index :tenant_id, name: :idx_finlog_exec_tenant
      end
    end

    # 6. Tags — flexible key-value metadata for cost events
    unless table_exists?(:finlog_tags)
      create_table(:finlog_tags) do
        primary_key :id
        String :execution_id, size: 36, null: false
        String :tag_key, size: 128, null: false
        String :tag_value, size: 512, null: false
        String :tenant_id, size: 64
        DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP

        index :execution_id, name: :idx_finlog_tag_exec
        index :tag_key, name: :idx_finlog_tag_key
        index %i[execution_id tag_key], name: :idx_finlog_tag_exec_key, unique: true
        index :tenant_id, name: :idx_finlog_tag_tenant
      end
    end

    # 7. Usage — aggregated consumption data (daily rollup)
    unless table_exists?(:finlog_usages)
      create_table(:finlog_usages) do
        primary_key :id
        String :worker_id, size: 36, null: false
        DateTime :period_start, null: false
        DateTime :period_end, null: false
        String :provider, size: 100, null: false
        String :model_id, size: 255, null: false
        Integer :total_requests, default: 0, null: false
        Integer :total_input_tokens, default: 0, null: false
        Integer :total_output_tokens, default: 0, null: false
        Integer :total_thinking_tokens, default: 0, null: false
        Float :total_raw_cost_usd, default: 0.0, null: false
        Float :total_discounted_cost_usd, default: 0.0, null: false
        Float :total_chargeback_usd, default: 0.0, null: false
        String :tenant_id, size: 64
        DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP

        unique %i[worker_id provider model_id period_start], name: :idx_finlog_usage_unique
        index :period_start, name: :idx_finlog_usage_period
        index %i[worker_id period_start], name: :idx_finlog_usage_worker_period
        index :tenant_id, name: :idx_finlog_usage_tenant
      end
    end
  end

  down do
    drop_table?(:finlog_usages)
    drop_table?(:finlog_tags)
    drop_table?(:finlog_executions)
    drop_table?(:finlog_accounting)
    drop_table?(:finlog_environments)
    drop_table?(:finlog_assets)
    drop_table?(:finlog_identities)
  end
end
