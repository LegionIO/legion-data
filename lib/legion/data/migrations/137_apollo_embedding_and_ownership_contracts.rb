# frozen_string_literal: true

Sequel.migration do
  up do
    next unless %i[postgres sqlite].include?(adapter_scheme)

    postgres = adapter_scheme == :postgres
    %i[apollo_entries apollo_entries_archive].each do |table|
      columns = schema(table).map(&:first)
      alter_table(table) do
        add_column :embedding, String, text: true unless postgres || columns.include?(:embedding)
        add_column :embedding_space_id, String, size: 64
        add_column :embedding_dimensions, Integer
        add_column :embedding_provenance, postgres ? :jsonb : :text
      end

      next unless postgres

      # Direct-column ANN indexes require a fixed vector dimension. Discover
      # copied archive indexes too; dimension-constrained expression indexes
      # and indexes on other columns remain valid and must not be removed.
      ann_indexes = fetch(<<~SQL, table.to_s).all
        SELECT namespace.nspname AS schema_name, index_relation.relname AS index_name
        FROM pg_index AS index_definition
        JOIN pg_class AS index_relation ON index_relation.oid = index_definition.indexrelid
        JOIN pg_namespace AS namespace ON namespace.oid = index_relation.relnamespace
        JOIN pg_am AS access_method ON access_method.oid = index_relation.relam
        JOIN pg_attribute AS attribute
          ON attribute.attrelid = index_definition.indrelid
          AND attribute.attnum = ANY(index_definition.indkey)
        WHERE index_definition.indrelid = to_regclass(?)
          AND attribute.attname = 'embedding'
          AND access_method.amname IN ('hnsw', 'ivfflat')
      SQL
      ann_indexes.each do |index|
        run "DROP INDEX #{quote_identifier(index[:schema_name])}.#{quote_identifier(index[:index_name])}"
      end
      run "ALTER TABLE #{quote_identifier(table)} ALTER COLUMN embedding TYPE vector USING embedding::vector"
      self[table].exclude(embedding: nil).update(embedding_dimensions: Sequel.function(:vector_dims, :embedding))
    end

    alter_table(:apollo_entries) do
      drop_index :content_hash, name: :idx_apollo_content_hash, if_exists: true
    end
    # Global knowledge has no owner. Legacy restricted NULL owners occupy a
    # separate scope/owner-zero slot, never a real principal's namespace.
    run <<~SQL
      CREATE UNIQUE INDEX idx_apollo_content_hash_owner
        ON apollo_entries (
          content_hash,
          access_scope,
          (CASE WHEN access_scope = 'global' THEN 0 ELSE COALESCE(identity_principal_id, 0) END)
        )
        WHERE status != 'archived' AND content_hash IS NOT NULL
    SQL
    alter_table(:apollo_entries) do
      add_index %i[embedding_space_id embedding_dimensions status], name: :idx_apollo_embedding_space_dimensions
    end
  end

  down do
    raise Sequel::Error, 'Apollo embedding and ownership contracts cannot be reversed without losing vectors or ownership-scoped records'
  end
end
