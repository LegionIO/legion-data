# frozen_string_literal: true

Sequel.migration do
  up do
    from(:apollo_entries_archive).exclude(embedding: nil).update(embedding_dimensions: Sequel.function(:vector_dims, :embedding)) if adapter_scheme == :postgres
  end

  down do
    raise Sequel::Error, 'Apollo archive dimension backfill cannot be reversed without erasing application-written dimensions' if adapter_scheme == :postgres
  end
end
