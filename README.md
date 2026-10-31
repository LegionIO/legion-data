# legion-data

Persistent database storage for the [LegionIO](https://github.com/LegionIO/LegionIO) async job engine and AI coding assistant platform. Provides database connectivity via the [Sequel ORM](https://sequel.jeremyevans.net/), automatic schema migrations, Sequel models for the full LegionIO control plane, and a parallel local SQLite database for on-node agentic cognitive state.

**Version**: 1.10.29 | **Ruby**: >= 3.4 | **License**: Apache-2.0

---

## What It Owns

`legion-data` is the data contract for LegionIO. It owns database connectivity, migrations, model loading, and portable Sequel model definitions for shared platform state. HTTP routes, runtime orchestration, and extension behavior live in other LegionIO repos and call into these models.

Core responsibilities:

| Area | Tables and models |
|------|-------------------|
| Control plane | extensions, functions, runners, nodes, tasks, settings, workers, relationships, chains |
| Audit and governance | `audit_log`, `audit_records`, `governance_events`, archive manifests |
| Identity and RBAC | providers, principals, identities, groups, memberships, role grants, runner grants |
| LLM ledger | conversations, model-visible messages, inference requests/responses, routing, metrics, tool calls, policy/security events |
| Apollo knowledge | PostgreSQL `pgvector` or SQLite JSON-vector entries, relations, expertise, access logs |
| Local state | on-node SQLite cognitive state, independent of the shared database |

The schema is portable by default across SQLite, MySQL, and PostgreSQL. Apollo semantic storage supports PostgreSQL and SQLite; native PostgreSQL vector operations remain adapter-specific.

`Legion::Data.setup` raises on fatal connection configuration, migration, or model-loading failures rather than announcing successful startup. Failed setup closes its database connections and clears readiness; fix the underlying error before retrying. Local migrations registered after startup also propagate failures and leave the local database disconnected until setup succeeds.

## Supported Databases

| Database | Adapter | Gem | Default |
|----------|---------|-----|---------|
| SQLite | `sqlite` | `sqlite3` (bundled) | Yes |
| MySQL | `mysql2` | `mysql2` (optional) | No |
| PostgreSQL | `postgres` | `pg` (optional) | No |

SQLite is the default and requires no additional gems. For MySQL or PostgreSQL, install the corresponding gem and configure the adapter.

---

## Installation

```bash
gem install legion-data
```

Or add to your `Gemfile`:

```ruby
gem 'legion-data'

# For production databases, add one of these:
# gem 'mysql2', '>= 0.5.5'
# gem 'pg', '>= 1.5'
```

---

## Architecture Overview

```
Legion::Data (singleton module)
├── .setup              # Connect, migrate, load models, set up local DB
├── .connection         # Sequel::Database handle (shared/central)
├── .local              # Legion::Data::Local (local SQLite accessor)
├── .stats              # Combined { shared: ..., local: ... } metrics
├── .reload_static_cache  # Refresh in-memory StaticCache after extension hot-load
├── .shutdown           # Close both shared and local connections
│
├── Connection          # Sequel database connection management
│   ├── .adapter        # Reads adapter from settings (:sqlite, :mysql2, :postgres)
│   ├── .setup          # Establish connection (dev_mode fallback to SQLite if unreachable)
│   ├── .sequel         # Raw Sequel::Database accessor
│   ├── .connection_info  # Adapter, liveness, and fallback diagnostics
│   ├── .fallback_active? # True when dev fallback moved a network DB to SQLite
│   ├── .stats          # Pool metrics, tuning snapshot, adapter-specific DB stats
│   └── .shutdown       # Drain accepted work; return true only after cleanup
│
├── Migration           # Auto-migration system (numbered Sequel DSL migrations)
│
├── Model               # Sequel model autoloader
│   └── Models: Extension, Function, Runner, Node, Task, TaskLog, Setting,
│               DigitalWorker, Relationship, AuditLog, AuditRecord, Chain,
│               RbacRoleAssignment, RbacRunnerGrant, RbacCrossTeamGrant,
│               IdentityProvider, Principal, Identity, IdentityGroup,
│               IdentityGroupMembership, IdentityAuditLog, ExtractStepTiming,
│               ApolloEntry, ApolloRelation, ApolloExpertise, ApolloAccessLog (PG only),
│               LLM::Conversation, LLM::Message, LLM::MessageInferenceRequest,
│               LLM::MessageInferenceResponse, LLM::RouteAttempt,
│               LLM::MessageInferenceMetric, LLM::ToolCall, LLM::ToolCallAttempt,
│               LLM::ConversationCompaction, LLM::PolicyEvaluation,
│               LLM::SecurityEvent, LLM::RegistryEvent
│
├── Local               # Parallel local SQLite for agentic cognitive state
│   ├── .setup          # Lazy init — creates legionio_local.db on first access
│   ├── .connection     # Sequel::SQLite::Database handle
│   ├── .model(:table)  # Create Sequel::Model bound to local connection
│   ├── .register_migrations(name:, path:)  # Extensions add their own migration dirs
│   ├── .stats          # Local SQLite metrics (PRAGMAs, file size, registered migrations)
│   └── .shutdown       # Close local connection
│
├── Extract             # 10-handler text extraction registry (txt/md/csv/json/jsonl/html/xlsx/docx/pdf/pptx/vtt)
├── Spool               # Filesystem write buffer for DB-unavailable scenarios
├── Rls                 # PostgreSQL row-level security helpers (tenant isolation)
├── StorageTiers        # Hot/warm/cold archival lifecycle
├── EventStore          # Append-only governance event store with hash chain integrity
├── Vector              # Reusable pgvector helpers (cosine_search, l2_search, ensure_extension!)
└── Settings            # Default configuration with per-adapter credential presets
```

### Two-Database Architecture

`legion-data` maintains two independent databases:

1. **Shared DB** (SQLite / MySQL / PostgreSQL) — control plane data: extensions, tasks, runners, nodes, settings, audit logs, relationships. Shared across the cluster.
2. **Local DB** (always SQLite) — agentic cognitive state: memory traces, trust scores, dream journals. On-node only; no cross-database joins.

Deleting `legionio_local.db` provides cryptographic erasure — no residual data.

---

## Usage

```ruby
require 'legion/data'

# Set up shared DB + local SQLite, run migrations, load models
Legion::Data.setup

# Access the Sequel database handle
Legion::Data.connection              # => Sequel::Database

# Access models
Legion::Data::Model::Extension.all  # => Sequel::Dataset
Legion::Data::Model::Task.first(id: 42)
Legion::Data::Model::Setting.where(key: 'my_setting').first

# Access local cognitive state DB
Legion::Data.local.connection        # => Sequel::SQLite::Database
Legion::Data.local.connected?        # => true
Legion::Data.local.db_path           # => "legionio_local.db"

# Check connection health
Legion::Data.connected?              # => true
Legion::Data.stats                   # => { shared: {...}, local: {...} }

# Inspect shared DB diagnostics, including dev fallback state
Legion::Data::Connection.connection_info
# => { adapter: :sqlite, connected: true, fallback_active: false, ... }

# Shut down both connections
Legion::Data.shutdown
```

### Graceful Database Shutdown

`Legion::Data.shutdown` returns `true` when the shared pool has drained and its connections and query logger are closed. An idle pool closes immediately. Once shutdown starts, new checkouts are rejected; work already accepted by the pool may finish, including nested checkouts in the same execution context.

If `shutdown_timeout` expires, shutdown returns `false` rather than claiming active connections were forcibly closed. The last accepted checkout performs deferred cleanup. `Connection.connection_info[:shutdown]` reports `state` (`open`, `draining`, `closing`, `closed`, or `failed`) and `active_requests`, which counts accepted execution contexts, including pool waiters—not physical connections. A cleanup failure is logged and can be retried by calling shutdown again.

Shutdown does not cancel SQL, kill worker threads, or close borrowed connections. Configure database statement timeouts separately to bound query execution. To resume work after completed shutdown, call `Legion::Data.setup`; it creates a new pool and rebinds loaded models.

### Model Associations

Models use Sequel associations as the public object graph. Prefer association methods and association datasets over hand-written foreign-key lookups when the relationship is part of the schema contract.

```ruby
task = Legion::Data::Model::Task.first(id: 42)
task.function             # many_to_one :function
task.relationship         # many_to_one :relationship
task.task_logs_dataset    # further filter/order without losing the relationship

conversation = Legion::Data::Models::LLM::Conversation.first(uuid: conversation_uuid)
conversation.messages_dataset.order(:seq).all
conversation.security_incident_lineage
```

Official LLM lifecycle data lives under `Legion::Data::Models::LLM`. `legion-llm` and `lex-llm-ledger` should use these models and the `llm_*` migration tables for conversations, model-visible messages, inference requests, responses, route attempts, metrics, tool calls, policy decisions, security events, and registry events. Legacy ledger-only tables are not the canonical schema.

Association rules used in this repo follow Sequel's own association model:

| Relationship | Use this Sequel association |
|--------------|-----------------------------|
| Current table has the foreign key | `many_to_one` |
| Associated table has the foreign key | `one_to_many` or `one_to_one` |
| Join table connects both sides | `many_to_many` |
| One associated record through a join table | `one_through_one` |

When Sequel cannot infer names from the schema, models must be explicit with `:class`, `:key`, `:primary_key`, `:join_table`, `:left_key`, and `:right_key`. Association names must not collide with real column names because Sequel creates methods with the association name.

### Local Database (Agentic Cognitive State)

Extensions register their own migration directories and create models bound to the local connection:

```ruby
# Register extension migrations (called during extension setup)
Legion::Data::Local.register_migrations(name: :memory, path: '/path/to/migrations')

# Create a model class bound to the local DB
MyMemoryTrace = Legion::Data::Local.model(:memory_traces)
MyMemoryTrace.all  # queries legionio_local.db, never the shared DB
```

### Text Extraction

`Legion::Data::Extract` provides a handler registry for extracting text from documents, used by `lex-knowledge` for corpus ingestion:

```ruby
result = Legion::Data::Extract.extract('/path/to/document.pdf')
text = result[:text]
result[:step_timings] # per-step name, start_time, end_time, status, error, duration_ms
```

Supported formats: `.txt`, `.md`, `.csv`, `.json`, `.jsonl`, `.html`, `.xlsx`, `.docx`, `.pdf`, `.pptx`, `.vtt`

When migration 076 is present, Extract also persists the same per-step timing rows to `extract_step_timings`
under the returned `extract_id`.

### Task Idempotency

`Task.idempotency_key_for` computes a stable SHA-256 key from canonical JSON payloads. `Task.create_idempotent`
returns an existing non-terminal task for the same key inside the optional TTL window, or creates a new task
with `idempotency_key` and `idempotency_expires_at` populated:

```ruby
task = Legion::Data::Model::Task.create_idempotent(
  { status: 'pending', payload: Legion::JSON.dump(payload) },
  payload: payload,
  ttl: 300
)
```

Terminal tasks and expired TTLs allow a replacement. This database helper uses a lookup followed by an insert; concurrent callers are not guaranteed to receive the same task. It does not provide RabbitMQ delivery or execution deduplication.

### Serialized Audit and Governance Appends

After migration 138, `AuditRecord.append` serializes each chain and `EventStore.append` serializes each stream with database-backed claims, including empty chains. Different audit/event namespaces remain independent. Claim rows do not accumulate after transactions finish; failed appends roll back both claim and record.

Audit tails, verification, and walks use append IDs rather than timestamps, preserving chain order across writer clock skew. Governance events retain their sequential stream numbering. PostgreSQL lock/statement timeouts and native adapter lock limits bound contention; timeout and unrelated database errors propagate rather than being retried indefinitely. MySQL claims use exclusive duplicate-key locking to avoid InnoDB shared-lock upgrade deadlocks.

### Bounded Retention

```ruby
Legion::Data::Retention.archive_old_records(
  table: :audit_log, archive_after_days: 90, batch_size: 1000
) # => { archived: total_moved, table: :audit_log }
```

Source tables need a declared primary key, including composite keys. `batch_size` must be a positive integer and bounds each materialized batch. Rows are selected in primary-key order; PostgreSQL/MySQL lock them and SQLite uses an immediate write transaction. Each batch copies and deletes exactly the same identities atomically, including when other rows become eligible during the copy.

Outside a caller-owned transaction, each batch commits independently. A later failure is raised without undoing earlier batches; rerun to archive the remaining eligible rows. A successful result sums that invocation's moved rows. If the caller wraps retention in its own transaction, that outer transaction still controls commit and lock lifetime.

### Audit Verification After Retention

`Legion::Data::Model::AuditLog.verify_chain` verifies hot `audit_log` rows together with retained `audit_log_archive` rows in one ordered SQL statement when the archive exists. Moving records between these tables does not discard their predecessors or create a mixed-snapshot boundary. Archived content is rehashed; missing predecessors, modified content, and duplicate copies remain verification failures.

Passing an explicit record collection still verifies exactly that collection from genesis. Cold storage and purged history are not silently trusted: missing archived predecessors remain invalid until the complete history is supplied. This does not change LegionIO's separate tier-verification API.

Before the first retention run, verification reads hot-only history without creating archive schema. It checks again afterward for concurrent archive creation and, if the archive appeared, verifies both tables together. Only an actual missing-table error means the archive is absent; permission, connection, and other database failures propagate.

### Filesystem Spool (Write Buffer)

When the database is unavailable, `Legion::Data::Spool` buffers writes to `~/.legionio/data/spool/` and replays once the connection is restored:

```ruby
spool = Legion::Data::Spool.for(Legion::Extensions::MyLex)
spool.write(:events, { task_id: SecureRandom.uuid, data: payload })
spool.flush(:events) { |entry| process(entry) }
```

Replay claims each event with a nonblocking advisory file lock held through the callback and successful deletion. Concurrent processes cannot replay the same live claim. `read` and `clear` skip in-flight entries; `count` includes them until deletion. Corrupt files are quarantined under the same ownership protocol.

Callback failure retains the event and releases its lock. Process exit also releases the lock automatically, so the next drainer can recover it without stale claim markers. Delivery is **at least once**: a crash after an external side effect but before deletion can replay that effect. Callbacks must provide their own idempotency. Single-drainer filename order is preserved, but concurrent completion order is not guaranteed. The spool filesystem must support cooperative advisory locking.

### Row-Level Security (PostgreSQL)

`Legion::Data::Rls` provides tenant isolation via PostgreSQL session variables (migration 043):

```ruby
Legion::Data::Rls.with_tenant(tenant_id) do
  Legion::Data::Model::Task.all  # scoped to tenant_id via RLS policy
end
```

The scope holds one pooled connection until the block finishes and its prior tenant state has been restored, including when the block raises. Nested scopes restore the outer tenant. Run scoped database work in the calling thread; newly spawned threads do not inherit its tenant scope.

### Permission Checks

```ruby
Legion::Data.can_write?(:tasks)  # => true (SQLite always true)
Legion::Data.can_read?(:tasks)   # => true
Legion::Data.reset_privileges!   # clear cached privilege checks
```

Checks use the active database adapter, including SQLite fallback, and return false while disconnected. PostgreSQL checks table-level SELECT/INSERT grants. MySQL checks base tables with a zero-row SELECT and a nonexecuting `EXPLAIN INSERT`; checking a MySQL view also requires the privileges needed to explain that view, including SHOW VIEW for writes. Neither probe inserts data.

Successful lookups are cached per physical connection. Connection replacement and credential rotation invalidate caches; query or connection failures return false without caching a denial. Call `reset_privileges!` after changing grants or roles on existing sessions.

---

## Configuration

All settings live under the `data` key. The adapter controls which options apply.

### SQLite (default)

```json
{
  "data": {
    "adapter": "sqlite",
    "creds": {
      "database": "legionio.db"
    }
  }
}
```

SQLite lock waits use a Ruby busy handler that releases the GVL between retries, so other threads can finish transactions while a writer waits. `data.timeout` sets the wait limit in milliseconds for both databases; when unset, shared SQLite uses 5,000 ms and local SQLite uses 30,000 ms. Local connection-specific tuning is applied to every pooled connection. `PRAGMA busy_timeout` does not report the Ruby handler's deadline.

### MySQL

```json
{
  "data": {
    "adapter": "mysql2",
    "creds": {
      "username": "legion",
      "password": "legion",
      "database": "legionio",
      "host": "127.0.0.1",
      "port": 3306
    }
  }
}
```

### PostgreSQL

```json
{
  "data": {
    "adapter": "postgres",
    "creds": {
      "user": "legion",
      "password": "legion",
      "database": "legionio",
      "host": "127.0.0.1",
      "port": 5432
    }
  }
}
```

`data.statement_timeout` (default 5,000 ms) and `data.lock_timeout` (default 2,000 ms) are applied before every PostgreSQL connection enters the pool, including startup and replacement connections. Set a value to `null` to leave that server setting unchanged, or `0` to explicitly disable the corresponding PostgreSQL timeout.

PostgreSQL Apollo storage requires these extensions (SQLite uses JSON vectors instead):

```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
```

### Full Configuration Reference

```json
{
  "data": {
    "adapter": "sqlite",
    "connected": false,
    "dev_mode": false,
    "dev_fallback": true,
    "connect_on_start": true,

    "max_connections": 25,
    "pool_timeout": 5,
    "preconnect": "concurrently",
    "single_threaded": false,
    "test": true,

    "log": false,
    "query_log": false,
    "log_warn_duration": 1,
    "sql_log_level": "debug",

    "connection_validation": true,
    "connection_validation_timeout": 600,
    "connection_expiration": true,
    "connection_expiration_timeout": 14400,

    "read_replica_url": null,
    "replicas": [],

    "creds": { "database": "legionio.db" },

    "migrations": {
      "continue_on_fail": false,
      "auto_migrate": true
    },
    "models": {
      "continue_on_load_fail": false,
      "autoload": true
    },
    "local": {
      "enabled": true,
      "database": "legionio_local.db",
      "migrations": { "auto_migrate": true }
    },
    "cache": {
      "connected": false,
      "auto_enable": false,
      "static_cache": false,
      "ttl": 60
    }
  }
}
```

### Dev Mode Fallback

When `dev_mode: true` and a network database is unreachable, the shared connection automatically falls back to SQLite:

```json
{ "data": { "dev_mode": true, "dev_fallback": true } }
```

Fallback is intentionally loud. `Connection.setup` logs the degraded mode at error level, `Connection.fallback_active?` returns `true`, and `Connection.connection_info` reports the configured adapter, actual adapter, connection state, and Sequel liveness. Data written during fallback is local-only SQLite data and will not appear in the configured network database after reconnect.

### HashiCorp Vault Integration

When Vault is connected, credentials are fetched dynamically from `database/creds/legion`, overriding any static `creds` block.

### Caching

Two independent caching tiers, both disabled by default:

| Tier | Setting | Models | Backend |
|------|---------|--------|---------|
| **StaticCache** | `data.cache.static_cache: true` | Extension, Runner, Function | In-process frozen Ruby hash |
| **External Cache** | `data.cache.auto_enable: true` + `Legion::Cache` | Relationship, Node, Setting | Redis/Memcached/Memory |

```ruby
# After hot-loading extensions, refresh the static cache:
Legion::Data.reload_static_cache
```

### Query File Logging

Enable `data.query_log` (or `data.local.query_log`) to write SQL to a dedicated file. Write and close I/O failures, including a full disk, are reported through Legion::Logging without changing the database operation's result or replacing its exception. Opening the configured log file must still succeed during setup.

### Read Replicas (PostgreSQL)

```json
{
  "data": {
    "read_replica_url": "postgres://user:pass@replica1/db",
    "replicas": ["postgres://user:pass@replica2/db"]
  }
}
```

Replica URLs initialize a sharded pool at startup. URL-specific options override primary connection options; omitted credentials and session timeouts are inherited. Duplicate URLs are registered once as `read_0`, `read_1`, and so on. Reads remain on the primary unless explicitly routed, for example `dataset.server(Legion::Data::Connection.read_server)`. With no replicas configured, `read_server` returns `:default`.

### Task Database Archival

`Archival.archive_completed_tasks` and task-policy archival retain every task field after migration 137. Copy/delete and restore are atomic; only copied task IDs are deleted. A task referenced as a parent or master by another live task remains hot, so linked task trees archive from leaves upward across batches.

Restore preserves original IDs and restores parent/master links after inserting the requested rows. Include archived ancestors in the same restore request or restore them first. Occupied IDs or missing referenced functions/relationships cause rollback and leave the archive intact. Fields already discarded by older archival versions cannot be reconstructed by this migration.

### Archive Objects

Each archive batch receives a UUID before upload. S3, Azure, and local object paths use `legion-archive/<table>/<year>/<month>/batch_<uuid>.jsonl.gz`; the same UUID is stored in `archive_manifest.batch_id`. Repeated runs do not reuse numbered object names. Existing manifest paths remain valid; no stored objects are renamed. Direct `Archiver.upload_batch` callers must supply `batch_id:` instead of `batch_n:`.

### Encryption Key Cache

The default scope (`tenant_id: nil`) and tenant IDs have separate cache entries, including a tenant literally named `__default__`. Restart processes or clear existing key-provider caches when upgrading. This fix does not rewrite existing ciphertext: if that tenant name was used with the old cache, assess records encrypted with the wrong scope's key and re-encrypt them with the intended key. The reader does not fall back to another scope's key.

---

## Common Fields Standard

All new tables follow a column convention. Required fields are present on every table. Optional fields are added when the domain warrants them.

### Required

| Column | Type | Notes |
|--------|------|-------|
| `id` | `INTEGER PRIMARY KEY` (auto-increment) | Internal join key. Never expose externally — use a `uuid` column for API/log references. |
| `identity_principal_id` | `INTEGER` FK → `identity_principals.id` | The principal who caused this row to exist. |
| `identity_id` | `INTEGER` FK → `identities.id` | The specific provider-bound identity credential. |
| `identity_canonical_name` | `VARCHAR(255)` | Denormalized snapshot of the principal's canonical name. Point-in-time copy — may become stale if the principal is renamed. Use the FK join for authoritative lookups. Exists for fast filtering without joins. |
| `created_at` | `TIMESTAMPTZ` | Row creation time. |
| `updated_at` | `TIMESTAMPTZ` | Last modification time. |

### Optional (add when applicable)

| Column | Type | Notes |
|--------|------|-------|
| `expires_at` | `TIMESTAMPTZ` | TTL / archival eligibility. |
| `content_type` | `VARCHAR(...)` | Classifier for the row's payload kind. |
| `conversation_id` | `INTEGER` FK → `llm_conversations.id` | Links to the LLM conversation that produced this row. |
| `contains_phi` | `BOOLEAN` | Row contains Protected Health Information. |
| `contains_pii` | `BOOLEAN` | Row contains Personally Identifiable Information. |

### Naming rules

- Identity FKs are always `identity_principal_id` and `identity_id` — not `principal_id`, `agent_id`, `user_id`, or other loose variants on new tables.
- The denormalized string column is always `identity_canonical_name` — not `canonical_name`, `actor`, `agent_id`, or `identity_name`.
- **Existing columns on pre-existing tables are never renamed or removed.** Columns like `agent_id`, `source_agent`, `submitted_by`, and `actor` are historical record. The new identity columns are purely additive.

---

## Data Models

| Model | Table | Description |
|-------|-------|-------------|
| `Extension` | `extensions` | Installed LEX extensions |
| `Function` | `functions` | Available functions per extension (with embeddings) |
| `Runner` | `runners` | Runner definitions (AMQP routing keys) |
| `Node` | `nodes` | Cluster node registry |
| `Task` | `tasks` | Task instances |
| `TaskLog` | `task_logs` | Task execution logs |
| `Setting` | `settings` | Persistent settings store |
| `DigitalWorker` | `digital_workers` | Digital worker registry |
| `Relationship` | `relationships` | Task trigger/action chains between functions |
| `Chain` | `chains` | Task execution chains |
| `AuditLog` | `audit_log` | Tamper-evident audit trail with hash chain |
| `AuditRecord` | `audit_records` | Structured audit records |
| `ExtractStepTiming` | `extract_step_timings` | Per-step Extract pipeline timing metadata |
| `RbacRoleAssignment` | `rbac_role_assignments` | RBAC principal -> role mappings |
| `RbacRunnerGrant` | `rbac_runner_grants` | Per-runner permission grants |
| `RbacCrossTeamGrant` | `rbac_cross_team_grants` | Cross-team access grants |
| `IdentityProvider` | `identity_providers` | Identity provider registrations |
| `Principal` | `principals` | Authentication principals |
| `Identity` | `identities` | Identity records tied to principals |
| `IdentityGroup` | `identity_groups` | Identity groups |
| `IdentityGroupMembership` | `identity_group_memberships` | Group membership records |
| `ApolloEntry` | `apollo_entries` | Knowledge entries — PostgreSQL only (pgvector) |
| `ApolloRelation` | `apollo_relations` | Relations between Apollo entries — PostgreSQL only |
| `ApolloExpertise` | `apollo_expertise` | Per-agent domain expertise — PostgreSQL only |
| `ApolloAccessLog` | `apollo_access_log` | Apollo access audit log — PostgreSQL only |

The legacy flat Apollo classes above remain PostgreSQL-only. Use `Legion::Data::Model::Apollo::{Entry,Relation,Expertise,AccessLog}` for PostgreSQL or SQLite; namespaced models load when their backing tables exist. Migration 139 adds active/archive embedding-space IDs, actual dimensions, and JSONB/PostgreSQL or JSON-text/SQLite provenance. PostgreSQL uses unconstrained native vectors; SQLite uses JSON-text vectors.

Migration 139 preserves existing rows and hashes, replaces active hash uniqueness with scope/owner uniqueness, and leaves legacy provenance unknown for application-driven reembedding. It drops incompatible direct-column ANN indexes while preserving dimension-constrained expression indexes and unrelated indexes. Rollback is intentionally rejected rather than losing valid mixed-dimension or cross-owner records. Apply it before deploying `lex-apollo >= 0.4.45`.

The `Legion::Data::Model::Identity::*`, `Apollo::*`, and `RBAC::*` namespaces provide cleaner Sequel model names for API-facing code while preserving the legacy flat model classes. Official LLM lifecycle models live under `Legion::Data::Models::LLM`.

### Identity Namespace Models

| Model | Table | Description |
|-------|-------|-------------|
| `Identity::Provider` | `identity_providers` | Provider records with integer primary keys and public UUIDs |
| `Identity::ProviderCapability` | `identity_provider_capabilities` | Normalized provider capability declarations |
| `Identity::Principal` | `identity_principals` | Human, service, worker, or system principals |
| `Identity::Identity` | `identities` | Provider-bound identities for principals |
| `Identity::Group` | `identity_groups` | Identity groups |
| `Identity::GroupMembership` | `identity_group_memberships` | Principal and identity group membership rows |
| `Identity::AuditLog` | `identity_audit_log` | Identity lifecycle and lookup audit events |

### LLM Lifecycle Models

| Model | Table | Description |
|-------|-------|-------------|
| `LLM::Conversation` | `llm_conversations` | Conversation container tied to the base user identity |
| `LLM::Message` | `llm_messages` | Model-visible conversation transcript messages |
| `LLM::MessageInferenceRequest` | `llm_message_inference_requests` | Provider request assembled from message, context, tools, policy, and routing inputs |
| `LLM::MessageInferenceResponse` | `llm_message_inference_responses` | Provider/runtime response for one inference request |
| `LLM::RouteAttempt` | `llm_route_attempts` | Provider/model/runner routing attempts, including failures and escalations |
| `LLM::MessageInferenceMetric` | `llm_message_inference_metrics` | Token, latency, cost, and finance usage metrics for an inference pair |
| `LLM::ToolCall` | `llm_tool_calls` | Tool calls requested by an LLM provider response |
| `LLM::ToolCallAttempt` | `llm_tool_call_attempts` | Execution attempts, retries, failures, and results for provider-requested tool calls |
| `LLM::ConversationCompaction` | `llm_conversation_compactions` | Conversation-scoped compaction events |
| `LLM::PolicyEvaluation` | `llm_policy_evaluations` | Policy, classification, RBAC, and enforcement decisions for inference requests |
| `LLM::SecurityEvent` | `llm_security_events` | Security-relevant events tied to conversation, inference, response, or tool attempts |
| `LLM::RegistryEvent` | `llm_registry_events` | Provider/model registry availability and health events |

---

## Dependencies

| Gem | Purpose |
|-----|---------|
| `sequel` (>= 5.70) | ORM and migration framework |
| `sqlite3` (>= 2.0) | SQLite adapter (default, bundled) |
| `csv` (>= 3.2) | CSV extraction handler |
| `legion-json` | JSON serialization via Legion::JSON |
| `legion-logging` (>= 1.5.0) | Structured logging |
| `legion-settings` (>= 1.3.26) | Configuration management |
| `mysql2` (>= 0.5.5) | MySQL adapter (optional) |
| `pg` (>= 1.5) | PostgreSQL adapter (optional) |

---

## Migrations

Numbered Sequel DSL migrations run automatically on startup (`auto_migrate: true`). Key milestones:

| Range | What was added |
|-------|---------------|
| 001–011 | Core schema: nodes, settings, extensions, runners, functions, tasks, digital workers, value metrics |
| 012 | Apollo tables (PG only: pgvector, uuid-ossp, 4 tables) |
| 013–014 | Relationships table with trigger/action FK chains |
| 015 | RBAC tables |
| 017–019 | Audit log with tamper-evident hash chain |
| 020–025 | Webhooks, archive tables, memory traces, tenant partitions |
| 026 | Function embeddings (description + vector on functions) |
| 028–030 | Agent clusters and approval queue |
| 047–048 | Apollo knowledge capture + financial logging (UAIS cost recovery, 7 tables) |
| 050 | Critical indexes across 13 tables |
| 058–067 | Audit records, chains, knowledge tiers, tool embedding cache, identity system (providers, principals, identities, groups) |
| 068–071 | Entity type on audit records, principal on nodes, approval queue resume, engine on relationships |
| 072–073 | Identity audit log and multi-instance identity columns |
| 074–076 | Apollo field width fixes, task idempotency columns, and Extract step timing rows |
| 077–090 | Portable LLM lifecycle schema: conversations, messages, inference requests/responses, route attempts, inference metrics, provider-requested tool calls, compactions, policy/security, and registry events |
| 091–096 | Portable identity companion schema with integer primary keys, public UUIDs, provider capabilities, principals, identities, groups, memberships, and audit log |
| 097 | LLM dispatch identifiers for fleet operation, correlation, idempotency, provider instance, and dispatch path |
| 100–102 | SQLite Apollo entries, ownership, and access-scope indexes |
| 119–120 | Portable missing Apollo tables and indexes |
| 137 | Preserve task archive payloads and identities |
| 138 | Serialized audit and governance append claims |
| 139 | Apollo embedding provenance, mixed-dimension vectors, and ownership-scoped content-hash uniqueness |

Run migrations standalone:

```bash
bundle exec legionio_migrate
```

Migration rules:

- Do not edit published migrations.
- Do not guard migrations with `create_table?`, `table_exists?`, `if_not_exists`, or similar conditional schema logic.
- Add new migrations in the next available number and keep domains split by dependency and rollback risk.
- Use portable Sequel DSL unless a feature truly requires adapter-specific behavior.
- Prefer integer `id` primary keys for joins plus public `uuid` columns for APIs, logs, and external references.
- Avoid JSON columns unless the shape is genuinely provider-specific or dynamic evidence.

---

## CLI Executable

`exe/legionio_migrate` runs database migrations standalone, outside the full LegionIO service:

```bash
bundle exec legionio_migrate
```

---

## Role in LegionIO

`legion-data` is optional but provides core platform persistence. It initializes during `Legion::Service` startup (after transport). Key responsibilities:

1. Extension and function registry
2. Task scheduling, logging, and relationship chains
3. Node cluster membership tracking
4. Persistent settings storage
5. Digital worker registry (AI-as-labor platform)
6. RBAC assignment tables
7. Audit log with tamper-evident hash chain
8. Governance event store with append-only integrity
9. Apollo shared knowledge store (PostgreSQL + pgvector or SQLite, used by `lex-apollo`)
10. Local SQLite for agentic cognitive state — always on-node, independent of shared DB
11. Financial logging for UAIS cost recovery
12. Global tool embedding cache (L4 tier for `Legion::Tools::EmbeddingCache`)
13. Unified identity system (providers, principals, identities, groups)
14. LLM lifecycle ledger for audit, finance metrics, routing reconstruction, tool calls, and security incident lineage

---

## Contributing

```bash
git clone https://github.com/LegionIO/legion-data
cd legion-data
bundle install
bundle exec rspec        # all tests must pass
bundle exec rubocop -A   # zero offenses expected
```

This repo also includes a pre-commit configuration:

```bash
pre-commit install
pre-commit run --all-files
```

The local RuboCop hook auto-corrects staged Ruby files when RuboCop is available and fails the commit when RuboCop reports real offenses. The Ruby syntax hook checks every staged Ruby file.

Follow the [LegionIO contribution guide](https://github.com/LegionIO/.github/blob/main/CONTRIBUTING.md). Open a PR against `main`.

---

**Maintained by**: Matthew Iverson ([@Esity](https://github.com/Esity))
