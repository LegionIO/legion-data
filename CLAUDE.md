# legion-data: Persistent Storage for LegionIO

**Repository Level 3 Documentation**
- **Parent**: `/Users/miverso2/rubymine/legion/CLAUDE.md`

## Purpose

Manages persistent database storage for the LegionIO framework. Supports SQLite (default), MySQL, and PostgreSQL via Sequel ORM. Provides automatic schema migrations and data models for extensions, functions, runners, nodes, tasks, settings, digital workers, task relationships, Apollo shared knowledge tables (PostgreSQL only), tenants, webhooks, audit log, and archive tables. Also provides a parallel local SQLite database (`Legion::Data::Local`) for agentic cognitive state persistence.

**GitHub**: https://github.com/LegionIO/legion-data
**Version**: 1.6.0
**License**: Apache-2.0

## Supported Databases

| Database | Adapter | Gem | Use Case |
|----------|---------|-----|----------|
| SQLite | `sqlite` | `sqlite3` (bundled) | Default, dev/test, single-node |
| MySQL | `mysql2` | `mysql2` (optional) | Production |
| PostgreSQL | `postgres` | `pg` (optional) | Production |

Adapter is set via `Legion::Settings[:data][:adapter]`. All migrations use Sequel DSL for cross-database compatibility.

## Architecture

```
Legion::Data (singleton module)
├── .setup             # Connect, migrate, load models, setup cache, setup local
├── .connection        # Sequel database handle (shared/central)
├── .local             # Legion::Data::Local accessor
├── .stats             # Combined { shared: Connection.stats, local: Local.stats }
├── .reload_static_cache  # Refresh in-memory StaticCache after hot-loading extensions
├── .shutdown          # Close both connections
│
├── Connection         # Sequel database connection management (shared)
│   ├── .adapter       # Reads from settings (sqlite, mysql2, postgres)
│   ├── .setup         # Establish connection (dev_mode fallback to SQLite if network DB unreachable)
│   ├── .sequel        # Raw Sequel::Database accessor
│   ├── .stats         # Pool metrics, tuning snapshot, adapter-specific DB stats
│   ├── .pool_stats    # Connection pool usage (size, available, in_use, waiting)
│   ├── .shutdown      # Close connection
│   ├── GENERIC_KEYS   # Pool options forwarded to Sequel (:max_connections, :pool_timeout, etc.)
│   ├── ADAPTER_KEYS   # Per-adapter option whitelists (sqlite, postgres, mysql2)
│   ├── ADAPTER_DEFAULTS # Built-in defaults per adapter when user hasn't set a value
│   ├── SlowQueryLogger    # Wraps Legion::Logging with [slow-query] prefix for Sequel warn
│   └── QueryFileLogger    # Thread-safe file logger for query_log mode (~/.legionio/logs/)
│
├── Local              # Local SQLite database for agentic cognitive state
│   ├── .setup         # Lazy init — creates legionio_local.db on first access
│   ├── .connection    # Sequel::SQLite::Database handle
│   ├── .connected?    # Whether local DB is active
│   ├── .db_path       # Path to the local SQLite file
│   ├── .model(:table) # Create Sequel::Model bound to local connection
│   ├── .register_migrations(name:, path:) # Extensions register their migration dirs
│   ├── .stats         # Local SQLite metrics (PRAGMAs, file size, registered migrations)
│   ├── .shutdown      # Close local connection
│   └── .reset!        # Clear all state (testing)
│
├── Migration          # Auto-migration system (26 migrations, Sequel DSL)
│   └── migrations/
│       ├── 001_add_schema_columns
│       ├── 002_add_nodes
│       ├── 003_add_settings
│       ├── 004_add_extensions
│       ├── 005_add_runners
│       ├── 006_add_functions
│       ├── 007_add_default_extensions
│       ├── 008_add_tasks
│       ├── 009_add_digital_workers
│       ├── 010_add_value_metrics
│       ├── 011_add_extensions_registry
│       ├── 012_add_apollo_tables      # postgres-only: pgvector, uuid-ossp, 4 apollo tables
│       ├── 013_add_relationships      # relationships table with trigger/action FK to functions
│       ├── 014_add_relationship_columns  # delay, chain_id, debug, conditions, transformation, active, allow_new_chains
│       ├── 015_add_rbac_tables
│       ├── 016_add_worker_health
│       ├── 017_add_audit_log
│       ├── 018_add_governance_events    # append-only event store with hash chain
│       ├── 019_add_audit_hash_chain
│       ├── 020_add_webhooks
│       ├── 021_add_archive_tables
│       ├── 022_add_memory_traces
│       ├── 023_add_data_archive
│       ├── 024_add_tenant_partition_columns
│       ├── 025_add_tenants_table
│       └── 026_add_function_embeddings  # description + embedding (TEXT) on functions; postgres: embedding_vector vector(1536) with HNSW cosine index
│
├── Model              # Sequel model loader
│   └── Models/
│       ├── Extension      # Installed LEX extensions
│       ├── Function       # Available functions per extension (with trigger/action relationship associations)
│       ├── Runner         # Runner definitions (extension + function bindings)
│       ├── Node           # Cluster node registry
│       ├── Task           # Task instances (belongs_to Relationship, belongs_to DigitalWorker)
│       ├── TaskLog        # Task execution logs
│       ├── Setting        # Persistent settings store
│       ├── DigitalWorker  # Digital worker registry (lifecycle: bootstrap/active/paused/retired/terminated)
│       ├── Relationship   # Task trigger/action relationships between functions (migration 013/014)
│       ├── ApolloEntry    # Apollo knowledge entries — postgres only (pgvector embedding, confidence lifecycle)
│       ├── ApolloRelation # Weighted relations between Apollo entries — postgres only
│       ├── ApolloExpertise  # Per-agent domain expertise tracking — postgres only
│       ├── ApolloAccessLog  # Apollo entry access audit log — postgres only
│       ├── AuditLog       # Audit trail entries (AMQP + query layer)
│       ├── RbacRoleAssignment  # RBAC principal -> role mappings
│       ├── RbacRunnerGrant     # RBAC per-runner permission grants
│       └── RbacCrossTeamGrant  # RBAC cross-team access grants
│   Note: value_metrics table (migration 010) is accessed via raw Sequel dataset,
│         not via a named Sequel::Model subclass.
│   Note: Apollo models are guarded with `return unless adapter == :postgres` at load time.
│
├── Settings           # Default DB config with per-adapter credential presets
└── Version
```

### Key Design Patterns

- **Two-Database Architecture**: Shared (MySQL/PG/SQLite) for control plane data + Local (always SQLite) for agentic cognitive state. Two files, always separate, no cross-database joins.
- **Adapter-Driven**: `Connection.adapter` reads from settings; all adapters (including SQLite) use `Sequel.connect` so all options flow through uniformly
- **Flat Settings**: all connection/pool/adapter options live directly on `data.*` — legion-data resolves which options apply to the current adapter via `ADAPTER_KEYS` whitelists
- **Per-Adapter Defaults**: `ADAPTER_DEFAULTS` provides built-in defaults (e.g., sqlite timeout 5000, postgres connect_timeout 20) when user hasn't set a value; nil in settings means "use adapter default"
- **Dev Mode Fallback**: When `dev_mode: true` and network DB unreachable, shared connection falls back to SQLite (`legionio.db`) with warning log
- **Connection Health**: `connection_validator` (pings idle connections) and `connection_expiration` (retires old connections) extensions auto-enabled for non-SQLite adapters
- **Cross-DB Migrations**: Shared migrations use IntegerMigrator (Sequel DSL), local migrations use TimestampMigrator (per-extension registration)
- **Auto-Migration**: Runs Sequel migrations on startup (`auto_migrate: true` by default)
- **Sequel ORM**: Shared models are `Sequel::Model` subclasses (inherit global connection). Local models use `Legion::Data::Local.model(:table)` (explicit connection binding).
- **Two-Tier Caching**: StaticCache (in-process frozen hash, no external deps) for lookup models (Extension, Runner, Function) + external Caching plugin (via `Legion::Cache` — Redis/Memcached/Memory) for dynamic models (Relationship, Node, Setting). Both disabled by default.
- **Query Log Isolation**: `query_log` flag pipes all SQL to dedicated files (`~/.legionio/logs/data-shared-query.log`, `data-local-query.log`) via `QueryFileLogger` — completely isolated from the `Legion::Logging` domain
- **Cryptographic Erasure**: Deleting `legionio_local.db` is a hard guarantee — no residual data. Used by `lex-privatecore`.
- **CLI Executable**: Ships with `legionio_migrate` executable in `exe/` for running database migrations standalone

## Default Settings

```json
{
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
  "name": null,

  "log": false,
  "query_log": false,
  "log_connection_info": false,
  "log_warn_duration": 1,
  "sql_log_level": "debug",

  "connection_validation": true,
  "connection_validation_timeout": 600,
  "connection_expiration": true,
  "connection_expiration_timeout": 14400,

  "connect_timeout": null,
  "read_timeout": null,
  "write_timeout": null,
  "encoding": null,
  "sql_mode": null,
  "sslmode": null,
  "sslrootcert": null,
  "search_path": null,
  "timeout": null,
  "readonly": null,
  "disable_dqs": null,

  "read_replica_url": null,
  "replicas": [],

  "creds": {
    "database": "legionio.db"
  },
  "migrations": {
    "continue_on_fail": false,
    "auto_migrate": true,
    "ran": false,
    "version": null
  },
  "models": {
    "continue_on_load_fail": false,
    "autoload": true
  },
  "local": {
    "enabled": true,
    "database": "legionio_local.db",
    "query_log": false,
    "migrations": {
      "auto_migrate": true
    }
  },
  "cache": {
    "connected": false,
    "auto_enable": false,
    "static_cache": false,
    "ttl": 60
  },
  "archival": {
    "retention_days": 90,
    "batch_size": 1000,
    "storage_backend": null
  }
}
```

Settings are **flat** — all pool, logging, health, and adapter-specific options live directly on `data.*`. Adapter-specific options (e.g., `connect_timeout`, `encoding`, `sslmode`) default to `null` and resolve to per-adapter built-in defaults at connection time:

| Adapter | Applied Options | Defaults |
|---------|----------------|----------|
| sqlite | `timeout`, `readonly`, `disable_dqs` | `timeout: 5000`, `readonly: false`, `disable_dqs: true` |
| postgres | `connect_timeout`, `sslmode`, `sslrootcert`, `search_path` | `connect_timeout: 20`, `sslmode: "disable"` |
| mysql2 | `connect_timeout`, `read_timeout`, `write_timeout`, `encoding`, `sql_mode` | `connect_timeout: 120`, `encoding: "utf8mb4"` |

### Caching

Two independent caching tiers, both disabled by default:

| Tier | Setting | Models | Backend | Use Case |
|------|---------|--------|---------|----------|
| **StaticCache** | `data.cache.static_cache: true` | Extension, Runner, Function | In-process frozen Ruby hash | Zero-DB-hit reads for lookup tables. No external deps. Call `Legion::Data.reload_static_cache` after hot-loading extensions. |
| **External Cache** | `data.cache.auto_enable: true` + `Legion::Cache` loaded | Relationship (10s), Node (10s), Setting (ttl) | `Legion::Cache` (Redis/Memcached/Memory) | Cross-process cache sharing for dynamic models. Requires `legion-cache` gem connected. |

For thousands of agents, enable `static_cache` first — biggest impact, zero dependencies. External cache only adds value when you need cross-process sharing via Redis/Memcached.

Per-adapter credential defaults are defined in `Settings::CREDS`:
- **sqlite**: `{ database: "legionio.db" }`
- **mysql2**: `{ username: "legion", password: "legion", database: "legionio", host: "127.0.0.1", port: 3306 }`
- **postgres**: `{ user: "legion", password: "legion", database: "legionio", host: "127.0.0.1", port: 5432 }`

## Dependencies

| Gem | Purpose |
|-----|---------|
| `sequel` (>= 5.70) | ORM and migration framework |
| `sqlite3` (>= 2.0) | SQLite adapter (default, bundled) |
| `mysql2` (>= 0.5.5) | MySQL adapter (optional) |
| `pg` (>= 1.5) | PostgreSQL adapter (optional) |
| `legion-logging` | Logging |
| `legion-settings` | Configuration |

## File Map

| Path | Purpose |
|------|---------|
| `lib/legion/data.rb` | Module entry, setup/shutdown lifecycle |
| `lib/legion/data/connection.rb` | Sequel database connection (adapter selection) |
| `lib/legion/data/migration.rb` | Migration runner |
| `lib/legion/data/migrations/` | 26 numbered migration files (Sequel DSL) |
| `lib/legion/data/model.rb` | Model autoloader |
| `lib/legion/data/local.rb` | Local SQLite module for agentic cognitive state |
| `lib/legion/data/models/` | Sequel models (Extension, Function, Runner, Node, Task, TaskLog, Setting, DigitalWorker, Relationship, ApolloEntry, ApolloRelation, ApolloExpertise, ApolloAccessLog, AuditLog, RbacRoleAssignment, RbacRunnerGrant, RbacCrossTeamGrant) |
| `lib/legion/data/encryption/cipher.rb` | AES-256-GCM encrypt/decrypt with versioned binary format and AAD |
| `lib/legion/data/encryption/key_provider.rb` | Vault-backed key derivation with per-tenant scope and local fallback |
| `lib/legion/data/encryption/sequel_plugin.rb` | Transparent `encrypted_column` DSL for Sequel models |
| `lib/legion/data/event_store.rb` | Append-only governance event store with hash chain integrity |
| `lib/legion/data/event_store/projection.rb` | Projection base class, ConsentState, GovernanceTimeline |
| `lib/legion/data/vector.rb` | Reusable pgvector helpers: `available?`, `cosine_search`, `l2_search`, `ensure_extension!` |
| `lib/legion/data/storage_tiers.rb` | Hot/warm/cold archival lifecycle: `archive_to_warm`, `export_to_cold`, `stats` |
| `lib/legion/data/archival.rb` | Archival module entry point and configuration |
| `lib/legion/data/archival/` | Archival strategy implementations |
| `lib/legion/data/settings.rb` | Default configuration with per-adapter credential presets |
| `lib/legion/data/version.rb` | VERSION constant |
| `exe/legionio_migrate` | CLI executable for running database migrations standalone |

## Role in LegionIO

Optional persistent storage initialized during `Legion::Service` startup (after transport). Provides:
1. Extension and function registry (which LEXs are installed, what functions they expose)
2. Task scheduling and logging
3. Node cluster membership tracking
4. Persistent settings storage
5. Digital worker registry (AI-as-labor platform)
6. Task relationship graph (trigger/action chains)
7. Apollo shared knowledge store (PostgreSQL + pgvector only, used by lex-apollo)
8. Local SQLite for agentic cognitive state (memory traces, trust scores, dream journals) — always on-node, independent of shared DB
9. RBAC assignment tables (migrations 015 — role assignments, runner grants, cross-team grants)
10. Audit log with tamper-evident hash chain (migrations 017, 019)
11. Governance event store with append-only integrity (migration 018)
12. Webhook subscription storage (migration 020)
13. Archive, memory traces, and tenant partition tables (migrations 021–025)
14. Function embeddings for semantic runner discovery (migration 026 — description + vector columns on functions table)

---

**Maintained By**: Matthew Iverson (@Esity)
