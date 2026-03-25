# frozen_string_literal: true

Sequel.migration do
  up do
    next unless adapter_scheme == :postgres

    # --- Identity columns on apollo_entries ---
    alter_table(:apollo_entries) do
      add_column :submitted_by, String, size: 255
      add_column :submitted_from, String, size: 255
      add_column :content_hash, String, fixed: true, size: 32
    end

    # --- apollo_operations table ---
    run <<~SQL
      CREATE TABLE IF NOT EXISTS apollo_operations (
        id              BIGSERIAL PRIMARY KEY,
        operation       VARCHAR(50)  NOT NULL,
        actor           VARCHAR(100) NOT NULL,
        target_type     VARCHAR(50),
        target_ids      INTEGER[],
        summary         TEXT,
        detail          JSONB,
        old_state       JSONB,
        new_state       JSONB,
        reason          TEXT,
        principal_id    VARCHAR(255),
        created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
      );
    SQL

    # --- apollo_entries_archive table ---
    run <<~SQL
      CREATE TABLE IF NOT EXISTS apollo_entries_archive (
        LIKE apollo_entries INCLUDING ALL,
        archived_at     TIMESTAMPTZ DEFAULT NOW(),
        archive_reason  TEXT
      );
    SQL

    # --- Indexes: apollo_entries ---
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_submitted_by ON apollo_entries (submitted_by);'
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_submitted_from ON apollo_entries (submitted_from);'

    # Content hash dedup (unique among active entries only)
    run <<~SQL
      CREATE UNIQUE INDEX IF NOT EXISTS idx_apollo_content_hash
        ON apollo_entries (content_hash)
        WHERE status != 'archived';
    SQL

    # Status filtering (every read query filters on status)
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_status ON apollo_entries (status);'

    # Partial index: active entries only (hot path)
    run <<~SQL
      CREATE INDEX IF NOT EXISTS idx_apollo_active
        ON apollo_entries (id)
        WHERE status IN ('candidate', 'confirmed', 'disputed');
    SQL

    # Confidence ranking and decay targeting
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_confidence ON apollo_entries (confidence);'

    # Time-based: decay age, archival sweep
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_created ON apollo_entries (created_at);'
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_updated ON apollo_entries (updated_at);'

    # Composite: decay cycle targets
    run <<~SQL
      CREATE INDEX IF NOT EXISTS idx_apollo_decay_target
        ON apollo_entries (updated_at)
        WHERE status != 'archived';
    SQL

    # Composite: corroboration targets
    run <<~SQL
      CREATE INDEX IF NOT EXISTS idx_apollo_candidates
        ON apollo_entries (status, source_provider, source_channel)
        WHERE status = 'candidate' AND embedding IS NOT NULL;
    SQL

    # Knowledge domain (expertise, RBAC)
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_domain ON apollo_entries (knowledge_domain);'

    # Source agent (expertise aggregation)
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_source_agent ON apollo_entries (source_agent);'

    # Drop existing HNSW index and recreate as partial (active entries only)
    run 'DROP INDEX IF EXISTS apollo_entries_embedding_idx;'
    run <<~SQL
      CREATE INDEX IF NOT EXISTS idx_apollo_embedding_active
        ON apollo_entries USING hnsw (embedding vector_cosine_ops)
        WITH (m = 16, ef_construction = 64)
        WHERE status IN ('candidate', 'confirmed', 'disputed');
    SQL

    # --- Indexes: apollo_relations ---
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_rel_from ON apollo_relations (from_entry_id);'
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_rel_to ON apollo_relations (to_entry_id);'
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_rel_type ON apollo_relations (relation_type);'
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_rel_composite ON apollo_relations (from_entry_id, relation_type);'

    # --- Indexes: apollo_expertise ---
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_exp_agent ON apollo_expertise (agent_id);'
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_exp_domain ON apollo_expertise (domain);'
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_exp_composite ON apollo_expertise (agent_id, domain);'

    # --- Indexes: apollo_operations ---
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_ops_created ON apollo_operations (created_at);'
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_ops_operation ON apollo_operations (operation);'
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_ops_actor ON apollo_operations (actor);'
    run 'CREATE INDEX IF NOT EXISTS idx_apollo_ops_target ON apollo_operations USING GIN (target_ids);'

    # --- Indexes: apollo_entries_archive ---
    run 'CREATE INDEX IF NOT EXISTS idx_archive_content_hash ON apollo_entries_archive (content_hash);'
    run 'CREATE INDEX IF NOT EXISTS idx_archive_source_agent ON apollo_entries_archive (source_agent);'
    run 'CREATE INDEX IF NOT EXISTS idx_archive_archived_at ON apollo_entries_archive (archived_at);'
  end

  down do
    next unless adapter_scheme == :postgres

    # Restore original HNSW index (non-partial)
    run 'DROP INDEX IF EXISTS idx_apollo_embedding_active;'
    run <<~SQL
      CREATE INDEX IF NOT EXISTS apollo_entries_embedding_idx
        ON apollo_entries USING hnsw (embedding vector_cosine_ops);
    SQL

    drop_table?(:apollo_entries_archive)
    drop_table?(:apollo_operations)

    # Drop new indexes
    %w[
      idx_apollo_submitted_by idx_apollo_submitted_from idx_apollo_content_hash
      idx_apollo_status idx_apollo_active idx_apollo_confidence
      idx_apollo_created idx_apollo_updated idx_apollo_decay_target
      idx_apollo_candidates idx_apollo_domain idx_apollo_source_agent
      idx_apollo_rel_from idx_apollo_rel_to idx_apollo_rel_type idx_apollo_rel_composite
      idx_apollo_exp_agent idx_apollo_exp_domain idx_apollo_exp_composite
      idx_apollo_ops_created idx_apollo_ops_operation idx_apollo_ops_actor idx_apollo_ops_target
      idx_archive_content_hash idx_archive_source_agent idx_archive_archived_at
    ].each { |idx| run "DROP INDEX IF EXISTS #{idx};" }

    alter_table(:apollo_entries) do
      drop_column :content_hash
      drop_column :submitted_from
      drop_column :submitted_by
    end
  end
end
