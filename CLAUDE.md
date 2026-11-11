# legion-data

Persistent storage gem for LegionIO. Owns Sequel database connections, numbered migrations, models, local SQLite state, extract timing persistence, audit/governance storage, identity/RBAC storage, Apollo storage, and the LLM lifecycle ledger.

## Commands

```bash
bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt
```

RSpec output belongs in `tmp/`. On failure, extract only failures:

```bash
jq '[.examples[] | select(.status != "passed") | {file_path, line_number, full_description, status, exception: .exception}]' tmp/rspec_results.json > tmp/rspec_failures.json
```

## Architecture

- `lib/legion/data/connection.rb`: Sequel connection setup, diagnostics, fallback, query logging.
- `lib/legion/data/migration.rb`: numbered Sequel migrations.
- `lib/legion/data/model.rb`: shared model loader.
- `lib/legion/data/models/`: flat and namespaced Sequel model classes (`Identity::*`, `Apollo::*`, `RBAC::*`, `LLM::*`).
- `lib/legion/data/local.rb`: local SQLite database for on-node state.
- `lib/legion/data/extract.rb`: text extraction and persisted extract step timings.
- `lib/legion/data/spool.rb`: filesystem write buffer when DB writes are unavailable.

## Migration Rules

- Never edit published migrations. Add a new migration.
- Do not guard migrations with `create_table?`, `drop_table?`, `table_exists?`, `if_exists`, `if_not_exists`, `next if`, or `next unless`.
- **One change per migration file.** Each migration modifies exactly ONE table. Never loop over tables. If a migration fails, you must be able to identify exactly what broke and roll back cleanly.
- Never use `.each`, `.map`, or any iterator in a migration. If 12 tables need the same column, that's 12 migration files.
- Never use raw SQL (`run '...'`) when Sequel DSL supports the operation. Use `add_index`, `drop_index`, `add_column`, `drop_column`, etc.
- Use portable Sequel DSL unless the feature truly requires adapter-specific behavior.
- Use integer `id` primary keys for joins and public `uuid` columns for APIs/logs/external references.
- Normalize stable fields. Use JSON only for genuinely dynamic provider payloads or evidence.

### Sequel Migration DSL Reference

**Create table**: https://sequel.jeremyevans.net/rdoc/classes/Sequel/Database.html#method-i-create_table
**Column options**: https://sequel.jeremyevans.net/rdoc/classes/Sequel/Schema/CreateTableGenerator.html#method-i-column

### Create Table Pattern

```ruby
# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:example_records) do
      primary_key :id
      String :uuid, size: 36, null: false, unique: true

      # Identity columns (required on every table)
      String :access_scope, size: 20, null: false, default: 'global', index: true
      foreign_key :identity_principal_id, :identity_principals, null: true, on_delete: :set_null, on_update: :cascade
      foreign_key :identity_id, :identities, null: true, on_delete: :set_null, on_update: :cascade
      String :identity_canonical_name, size: 255, null: true, index: true

      # Domain columns here...

      # Timestamps (required on every table)
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP  # reflects when the event happened (request/AMQP timestamp)
      DateTime :inserted_at, null: false, default: Sequel::CURRENT_TIMESTAMP # when the row was physically written to the database
      DateTime :updated_at, null: true                                        # set on row update; NULL means never updated

      index :identity_principal_id
    end
  end
end
```

### Alter Table Pattern (adding a column)

```ruby
# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:target_table) do
      add_column :new_column, String, size: 128, null: true, index: true
    end
  end

  down do
    alter_table(:target_table) do
      drop_index :new_column
      drop_column :new_column
    end
  end
end
```

### Foreign Key Conventions

```ruby
# FK to identity tables — always cascade updates, set null on delete
foreign_key :identity_principal_id, :identity_principals, null: true, on_delete: :set_null, on_update: :cascade
foreign_key :identity_id, :identities, null: true, on_delete: :set_null, on_update: :cascade

# FK to domain tables — cascade delete (child dies with parent)
foreign_key :conversation_id, :llm_conversations, null: false, on_delete: :cascade

# FK to optional parent — set null on delete (orphan is ok)
foreign_key :parent_message_id, :llm_messages, null: true, on_delete: :set_null
```

### Timestamp Semantics

| Column | Meaning | Default | Nullable |
|--------|---------|---------|----------|
| `created_at` | When the event/action occurred in the real world (e.g. AMQP message timestamp, API request time) | `CURRENT_TIMESTAMP` | NOT NULL |
| `inserted_at` | When the row was physically written to this database — always DB clock time | `CURRENT_TIMESTAMP` | NOT NULL |
| `updated_at` | Last time the row was modified after initial insert. NULL means never updated. | none | NULL |

`created_at` vs `inserted_at`: a message published at 14:00:00 that gets consumed and written at 14:00:03 has `created_at = 14:00:00` and `inserted_at = 14:00:03`. For synchronous writes they will be the same.

### Index Conventions

- `access_scope` — always indexed (high cardinality filter for multi-tenant queries)
- `identity_canonical_name` — always indexed (user-facing search/filter)
- `identity_principal_id` — always indexed (join path to identity tables)
- `uuid` — always unique index (external reference lookups)
- Timestamp columns used in WHERE clauses — indexed
- Composite indexes for common query patterns: `index [:provider, :model_key]`

## Sequel ORM Rules

Use Sequel associations as the object graph. References:
- https://sequel.jeremyevans.net/rdoc/classes/Sequel/Model/Associations/ClassMethods.html
- https://github.com/jeremyevans/sequel/blob/master/doc/association_basics.rdoc

Association mapping:
- Foreign key on this model: `many_to_one`.
- Foreign key on the associated model: `one_to_many` or `one_to_one`.
- Join table between models: `many_to_many`.
- Single associated record through a join table: `one_through_one`.

When Sequel cannot infer names, set `:class`, `:key`, `:primary_key`, `:join_table`, `:left_key`, and `:right_key` explicitly. Do not create association names that collide with real columns.

## Common Fields Standard

All new tables in legion-data should follow this column convention. Required fields must be present on every table. Optional fields are added when the domain warrants them.

### Required (every table, in this order)

| Column | Sequel DSL | Purpose |
|--------|-----------|---------|
| `id` | `primary_key :id` | Auto-increment integer PK — internal join key, never exposed externally |
| `uuid` | `String :uuid, size: 36, null: false, unique: true` | External reference — used in APIs, logs, AMQP correlation |
| `access_scope` | `String :access_scope, size: 20, null: false, default: 'global', index: true` | Multi-tenant scoping (global, personal, team, org) |
| `identity_principal_id` | `foreign_key :identity_principal_id, :identity_principals, null: true, on_delete: :set_null, on_update: :cascade` | FK to the principal who caused this row |
| `identity_id` | `foreign_key :identity_id, :identities, null: true, on_delete: :set_null, on_update: :cascade` | FK to the specific provider-bound identity credential |
| `identity_canonical_name` | `String :identity_canonical_name, size: 255, null: true, index: true` | Point-in-time snapshot of the identity's canonical name. NOT a FK. May become stale if principal is renamed — use FK join for authoritative lookups. |
| `created_at` | `DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP` | When the event/action occurred (AMQP timestamp, request time) |
| `inserted_at` | `DateTime :inserted_at, null: false, default: Sequel::CURRENT_TIMESTAMP` | When the row was physically written to the database |
| `updated_at` | `DateTime :updated_at, null: true` | Set on row update; NULL means never updated after insert |

### Optional (add when applicable)

| Column | Type | Purpose |
|--------|------|---------|
| `expires_at` | `DateTime, null: true` | TTL / archival eligibility |
| `content_type` | `String, size: 64` | Classifier for the row's payload kind |
| `conversation_id` | `foreign_key ..., :llm_conversations, on_delete: :cascade` | Links to the LLM conversation that produced this row |
| `task_id` | `foreign_key ..., :tasks, on_delete: :set_null` | Links to the task that triggered this row |
| `contains_phi` | `TrueClass, default: false` | Row contains Protected Health Information |
| `contains_pii` | `TrueClass, default: false` | Row contains Personally Identifiable Information |

### Naming rules

- Identity FKs always use `identity_principal_id` and `identity_id` — never `agent_id`, `principal_id`, `user_id`, or other loose variants for new tables.
- The denormalized string field is always `identity_canonical_name` — not `canonical_name`, `actor`, `agent_id`, or `identity_name`.
- Existing columns (`agent_id`, `source_agent`, `submitted_by`, `actor`, etc.) on pre-existing tables are **not renamed or removed** — they are historical record and intentionally left as-is. New identity columns are purely additive.

## Boundaries

- REST APIs belong in LegionIO, not this gem.
- Extension runtime behavior belongs in the owning extension repos.
- Do not commit generated DBs, logs, coverage output, built gems, or workspace `/docs` files from outside this repo.
