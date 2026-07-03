# frozen_string_literal: true

# The (conversation_id, seq) UNIQUE constraint modeled a conversation as a flat
# line, but a conversation is a tree: a single parent can legitimately have two
# children at the same depth (e.g. a failed branch and the branch that
# succeeded), so two distinct messages can share the same (conversation_id, seq)
# and that is TRUTH, not a duplicate. The unique constraint rejected those
# legitimate siblings and forced the ledger into a racy MAX(seq)+1 generation
# that collided under concurrent writers.
#
# Message identity is guaranteed by the unique `uuid` (producer-derived, stable
# across redelivery). seq/parent become descriptive ordering data, so we keep a
# NON-unique composite index for conversation-ordered reads.
Sequel.migration do
  up do
    alter_table(:llm_messages) do
      drop_constraint(:llm_messages_conversation_id_seq_key, type: :unique) # rubocop:disable Legion/Llm/TaxonomyEnum
      add_index %i[conversation_id seq], name: :idx_llm_messages_conversation_seq
    end
    # SQLite emulates the constraint drop by rebuilding the table, which drops
    # the inline `uuid` UNIQUE. Re-assert it so message identity/dedup is never
    # lost. On PostgreSQL DROP CONSTRAINT is surgical and the original uuid index
    # already exists, so this is a no-op there.
    alter_table(:llm_messages) do
      add_index :uuid, unique: true, name: :idx_llm_messages_uuid_unique, if_not_exists: true
    end
  end

  down do
    alter_table(:llm_messages) do
      drop_index :uuid, name: :idx_llm_messages_uuid_unique, if_exists: true
      drop_index %i[conversation_id seq], name: :idx_llm_messages_conversation_seq
      add_unique_constraint %i[conversation_id seq], name: :llm_messages_conversation_id_seq_key
    end
  end
end
