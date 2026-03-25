# Legion::Data Changelog

## [1.6.4] - 2026-03-25

### Added
- Migration 047: Apollo identity columns (submitted_by, submitted_from), content hash dedup, apollo_operations table, apollo_entries_archive table, comprehensive indexes including partial HNSW on active entries only

## [1.6.2] - 2026-03-25

### Changed
- Migration 041: Resize all pgvector columns from `vector(1536)` to `vector(1024)` for cross-provider embedding compatibility (apollo_entries.embedding, functions.embedding_vector, memory_traces.embedding). Drops and recreates HNSW cosine indexes.

## [1.6.1] - 2026-03-25

### Fixed
- Load Sequel `pg_array` extension on Postgres connections — required by Apollo for `text[]` column inserts

## [1.6.0] - 2026-03-25

### Fixed
- **Connection pool starvation**: `max_connections`, `pool_timeout`, `preconnect`, and all other Sequel options were never forwarded to `Sequel.connect` — pool was stuck at Sequel's default of 4 connections regardless of settings. 5+ second "slow queries" in daemon logs were actually pool wait time (5s `pool_timeout`) + fast query (~19ms). Now all configured options flow through properly.
- **Local DB had same issue**: `Legion::Data::Local.setup` used bare `Sequel.sqlite(path)` with no options. Now forwards SQLite adapter options (`timeout`, `readonly`, `disable_dqs`) via `Sequel.connect`.

### Changed
- **Flat settings structure**: all connection settings now live directly on `data.*` instead of nested `data.connection.*` or `data.adapter_opts.*`. Users configure `data.max_connections`, `data.pool_timeout`, `data.connect_timeout`, etc. regardless of adapter — legion-data figures out which options apply.
- Default `max_connections` raised from 10 to 25 (was never applied before anyway)
- Default `preconnect` set to `'concurrently'` (warm pool at boot)
- Default `pool_timeout` remains 5s (now actually enforced)
- Per-adapter defaults applied at connection time via `ADAPTER_DEFAULTS`: sqlite (`timeout: 5000`, `readonly: false`, `disable_dqs: true`), postgres (`connect_timeout: 20`, `sslmode: 'disable'`), mysql2 (`connect_timeout: 120`, `encoding: 'utf8mb4'`)
- Adapter-specific settings (`connect_timeout`, `read_timeout`, `write_timeout`, `encoding`, `sql_mode`, `sslmode`, `sslrootcert`, `search_path`, `timeout`, `readonly`, `disable_dqs`) default to nil in settings and resolve to adapter built-in defaults — only forwarded when the current adapter supports them

### Added
- `GENERIC_KEYS`, `ADAPTER_KEYS`, `ADAPTER_DEFAULTS` constants on `Connection` for option whitelisting and defaults
- Connection health extensions (non-SQLite only): `connection_validator` (pings idle connections, default timeout 600s) and `connection_expiration` (retires old connections, default timeout 14400s) — both enabled by default via `data.connection_validation` and `data.connection_expiration`
- `Legion::Data::Connection.stats` — comprehensive connection metrics: pool stats (type, size, available, in_use, waiting), tuning snapshot, and adapter-specific database stats (postgres: `pg_stat_activity`, `pg_database_size`, server settings; sqlite: PRAGMAs, file size; mysql: `information_schema`, `SHOW STATUS`)
- `Legion::Data::Connection.pool_stats` — works across all Sequel pool types (`timed_queue`, `threaded`, `single`, sharded variants)
- `Legion::Data::Local.stats` — local SQLite metrics: PRAGMAs, file size, database size, registered migrations
- `Legion::Data.stats` — combined `{ shared: Connection.stats, local: Local.stats }` for `/api/stats` endpoint
- `data.query_log` flag (default `false`): when enabled, pipes ALL SQL queries to `~/.legionio/logs/data-shared-query.log` (shared) or `data-local-query.log` (local) via dedicated `QueryFileLogger` — isolated from the main `Legion::Logging` domain so debug query floods don't pollute application logs
- `Legion::Data::Connection::QueryFileLogger` — thread-safe file-based logger with timestamped entries, used by both shared and local query log modes
- `Legion::Data::Connection::SlowQueryLogger` — wraps tagged `Legion::Logging::Logger`, prefixes warn-level messages with `[slow-query]`
- `data.local.query_log` flag (default `false`): same as above but for the local SQLite connection
- **StaticCache infrastructure** for lookup models: `Legion::Data.setup_static_cache` applies `Sequel::Plugins::StaticCache` to `Extension`, `Runner`, `Function` — loads entire tables into frozen in-memory hashes for zero-DB-hit reads. Enabled via `data.cache.static_cache: true` (default `false`).
- `Legion::Data.reload_static_cache` — refreshes in-memory static cache after hot-loading new extensions
- **External cache infrastructure**: `Legion::Data.setup_external_cache` applies `Sequel::Plugins::Caching` to `Relationship` (ttl 10s), `Node` (ttl 10s), `Setting` (ttl configurable) via `Legion::Cache` backend. Activates when `data.cache.auto_enable` is true and `Legion::Cache` is loaded.
- `data.cache.static_cache` setting (default `false`)

## [1.5.3] - 2026-03-25

### Added
- Migration 040: add indexes on tasks table for slow query optimization (`idx_tasks_created`, `idx_tasks_status_func_rel`)

## [1.5.2] - 2026-03-24

### Fixed
- TLS spec mock `resolve` methods used `_port:` keyword which mismatched production `port:` call, causing `ArgumentError: unknown keyword: :port` on CI

## [1.5.1] - 2026-03-24

### Changed
- `Legion::Data::Connection#merge_tls_creds` — now respects explicit `data.tls.enabled` flag; TLS opt-in only (no behavior change when flag is absent or false)

### Added
- Migration 039: `audit_archive_manifests` table for tracking cold storage uploads (tier, storage_url, date range, entry count, SHA-256 checksum, hash chain anchors)
- `spec/legion/data/tls_spec.rb` — full coverage for merge_tls_creds feature flag behavior

## [1.5.0] - 2026-03-24

### Fixed
- Slow query warnings now tagged with `[data][slow-query]` instead of bare timestamps
- SQL log output uses tagged Legion::Logging::Logger for consistent `[data]` prefix
- Fix Style/SymbolArray in conversations migration

## [1.4.18] - 2026-03-23

### Fixed
- Fix extension migration timing: late `register_migrations` calls now run immediately if DB is connected
- Fix cross-extension schema_migrations conflicts with per-extension migration tables

## [1.4.17] - 2026-03-22

### Added
- `Legion::Data::Helper` mixin module with data convenience methods for LEX extensions (data_path, data_class, models_class, data_connected?, data_connection, local_data_connected?, local_data_connection, local_data_model)

### Fixed
- Add missing `require 'spec_helper'` in `helper_spec.rb` that caused `NameError: uninitialized constant Legion::Data::Helper`

## [1.4.16] - 2026-03-22

### Changed
- Add version constraints to gemspec dependencies: `legion-logging >= 1.2.8`, `legion-settings >= 1.3.12`

## [1.4.15] - 2026-03-22

### Changed
- Added `Legion::Logging` calls (guarded with `defined?`) to all previously silent rescue blocks
- `archival/policy.rb`: warn log on `Policy.from_settings` failure
- `archival.rb`: debug log on `db_ready?` failure
- `connection.rb`: debug log on `data_tls_settings` failure
- `event_store.rb`: debug log on `db_ready?` failure
- `models/audit_log.rb`: warn log on `parsed_detail` JSON parse failure
- `models/function.rb`: debug log on `embedding_vector` JSON parse failure
- `models/node.rb`: debug log on `parsed_metrics` and `parsed_hosted_worker_ids` JSON parse failures
- `partition_manager.rb`: warn log (via `log_warn`) on `partition_names_for` failure
- `storage_tiers.rb`: debug log on `count_tier` failure
- `vector.rb`: debug log on `available?` check failure

## [1.4.14] - 2026-03-22

### Changed
- Boot connection log for non-SQLite adapters now includes username: `adapter://user@host:port/db`

## [1.4.13] - 2026-03-22

### Added
- Comprehensive logging across data operations: connection lifecycle, archival, retention, storage tiers, event store, encryption key provider, spool drain, and vector search
- `Connection.setup`: `.info` on successful connect (adapter://host:port/db or SQLite path)
- `Connection.shutdown`: `.info` on disconnect
- `Connection.connect_with_replicas`: `.debug` with replica count
- `Data.setup`: `.info` on setup completion
- `Data.shutdown`: `.info` on shutdown
- `Archiver.archive_table`: `.info` on start and completion with table name and row count; `.warn` before re-raising S3/Azure upload failures
- `Archival.archive!`: `.info` with table, destination, cutoff, and dry_run flag; `.info` on restore with row count
- `Retention.archive_old_records`: `.info` with table name and archived row count
- `Retention.purge_expired_records`: `.info` with archive table name and purged row count
- `StorageTiers.archive_to_warm`: `.info` with table name and row count
- `StorageTiers.export_to_cold`: `.info` with exported row count
- `EventStore.append`: `.debug` with stream, event type, and sequence number
- `EventStore.verify_chain`: `.warn` when hash chain is broken, with stream and sequence number
- `Encryption::KeyProvider`: `.warn` on dev key fallback; `.debug` on Vault key derivation
- `Encryption::SequelPlugin`: `.warn` on decrypt failure before re-raise
- `Spool#write`: `.debug` with sub-namespace and filename
- `Spool#flush`: `.info` with sub-namespace and drained item count
- `Vector.ensure_extension!`: `.info` on successful pgvector setup
- `Vector.cosine_search` / `Vector.l2_search`: `.debug` with table, column, and limit

## [1.4.12] - 2026-03-21

### Added
- Migration 035: apollo_entries source_channel column (postgres-only)
- Migration 036: audit_log context_snapshot column
- Migration 037: apollo_entries knowledge_domain column with index (postgres-only)

## v1.4.11

### Added
- Read replica support: `read_replica_url` and `replicas` settings, `Connection.connect_with_replicas` via Sequel `server_block` extension, `read_server` and `replica_servers` class methods for read/write splitting
- `PartitionManager`: PostgreSQL range partitioning helper — `ensure_partitions`, `drop_old_partitions`, `list_partitions` for monthly table partitioning
- `Archiver`: cold storage archival pipeline — batch export to JSONL+gzip, SHA-256 manifest, pluggable upload backends (S3, Azure, local tmpdir)
- Migration 034: `archive_manifest` table (PostgreSQL only) for tracking archived batches
- Archival settings: `retention_days`, `batch_size`, `storage_backend` defaults
- 58 new specs (257 total, 0 failures)

## v1.4.10

### Added
- TLS support for PostgreSQL connections: `sslmode`, `sslrootcert`, `sslcert`, `sslkey`
- TLS support for MySQL connections: `ssl_mode`, `sslca`, `sslcert`, `sslkey`
- `Connection.merge_tls_creds` resolves TLS config via `Legion::Crypt::TLS.resolve`
- SQLite connections skip TLS entirely (local file, no network)

## v1.4.8

### Fixed
- Migration 033: adds `task_delay` column (Integer, nullable) to tasks table to resolve `PG::UndefinedColumn` error when lex-tasker queries `tasks.task_delay`

## v1.4.7

### Added
- Migration 031: adds `depth` column (Integer, default 0) to tasks table for sub-agent recursion tracking
- Migration 032: adds `cancelled_at` column (DateTime, nullable) to tasks table for cancellation support
- `cancelled?` predicate method on Task model

## v1.4.6

### Added
- Migration 028: agent_cluster_nodes table (stub for agent cluster support)
- Migration 029: agent_cluster_tasks table (stub for agent cluster task tracking)
- Migration 030: approval_queue table for governance board with status, requester, reviewer, and tenant filtering

## v1.4.5

### Added
- Migration 027: add `source_provider` column to `apollo_entries` (postgres-only)
  Tracks the LLM provider or data origin of each knowledge entry for source diversity
  enforcement in Apollo corroboration

## v1.4.4

### Added
- Migration 026: `description` (TEXT) and `embedding` (TEXT, JSON-serialized vector) columns on `functions` table
- Postgres-only: `embedding_vector vector(1536)` column with HNSW cosine index for semantic similarity search
- `Function#embedding_vector` / `Function#embedding_vector=` helper methods for JSON serialization

## v1.4.3

### Added
- `Legion::Data::Spool`: filesystem-based event buffer at `~/.legionio/data/spool/`

## v1.4.2

### Fixed
- Migration 015: use `create_table?` instead of `create_table` for idempotent RBAC table creation

## v1.4.1

### Added
- Migration 025: tenants table (tenant_id, name, status, quotas, token limits)

## v1.4.0

### Added
- `Legion::Data::Vector`: reusable pgvector helpers (available?, cosine_search, l2_search, ensure_extension!)
- `Legion::Data::StorageTiers`: hot/warm/cold archival lifecycle (archive_to_warm, export_to_cold, stats)
- Migration 022: memory_traces table with optional pgvector embedding column (1536-dim, HNSW index)
- Migration 023: data_archive table for generic storage tier archival
- Migration 024: tenant_id partition columns on tasks, digital_workers, audit_log, memory_traces

## v1.3.8

### Added
- `Legion::Data::Archival`: hot/warm/cold archival pipeline for tasks and metering records
- `Legion::Data::Archival::Policy`: configurable retention policies (warm_after_days, cold_after_days, batch_size)
- Archive, restore, and cross-table search operations with dry-run support
- Migration 021: archive tables for tasks and metering_records

## v1.3.7

### Added
- Migration 020: `webhooks`, `webhook_deliveries`, `webhook_dead_letters` tables

### Fixed
- Migration 019: guard against duplicate column adds when `record_hash` already exists from migration 017

## v1.3.6

### Added
- Migration 019: adds `record_hash`, `previous_hash`, `retention_tier` columns to `audit_log`

## v1.3.5

### Added
- `Legion::Data::EventStore`: append-only governance event store with stream semantics
- Hash chain integrity verification for tamper detection
- `EventStore::Projection` base class with `build_from` stream replay
- `ConsentState` projection: rebuild consent state from event history
- `GovernanceTimeline` projection: chronological governance event timeline
- Migration 018: governance_events table with stream/sequence indexing

## v1.3.4

### Added
- `Legion::Data::Encryption::Cipher`: AES-256-GCM with versioned binary format, random IV, and AAD
- `Legion::Data::Encryption::KeyProvider`: Vault-backed key derivation with local fallback for dev mode
- `Legion::Data::Encryption::SequelPlugin`: transparent `encrypted_column` DSL for Sequel models
- Per-tenant key scope support for cryptographic erasure compliance

## v1.3.3

### Added
- Migration 017: `audit_log` table with SHA-256 hash chain columns (`record_hash`, `prev_hash`)
- `Legion::Data::Model::AuditLog` immutable Sequel model with event type/status validation
- Indexes on `event_type`, `principal_id`, and `created_at` for audit query performance

## v1.3.2

### Added
- Migration 016: worker health columns (`health_status`, `last_heartbeat_at`, `health_node` on digital_workers; `metrics`, `hosted_worker_ids`, `version` on nodes)
- `DigitalWorker#health_status` validation against `HEALTH_STATUSES` (`online`, `offline`, `unknown`)
- `DigitalWorker#online?` and `DigitalWorker#offline?` convenience methods
- `Node#parsed_metrics` and `Node#parsed_hosted_worker_ids` JSON deserialization helpers

## v1.3.1

### Added
- Migration 015: RBAC tables (rbac_role_assignments, rbac_runner_grants, rbac_cross_team_grants)
- `Legion::Data::Model::RbacRoleAssignment` Sequel model with expiry and validation
- `Legion::Data::Model::RbacRunnerGrant` Sequel model with actions_list helper
- `Legion::Data::Model::RbacCrossTeamGrant` Sequel model with cross-team validation

## v1.3.0

### Added
- `Legion::Data::Local` module — parallel local SQLite database for agentic cognitive state persistence
- TimestampMigrator-based migration registration for per-extension local schemas
- `Legion::Data::Local.model(:table)` helper for local-bound Sequel models
- Dev mode fallback: shared DB falls back to SQLite when `dev_mode: true` and network DB unreachable
- New settings: `data.local.enabled`, `data.local.database`, `data.dev_mode`, `data.dev_fallback`
- `Legion::Data.local` accessor for the Local module
- Local connection lifecycle wired into `Legion::Data.setup` / `.shutdown`
- 13 new specs (62 total)

## v1.2.2

### Added
- Migration 014: add missing columns to `relationships` table (`delay`, `chain_id`, `debug`, `allow_new_chains`, `conditions`, `transformation`, `active`) required by lex-tasker query helpers

## v1.2.1

### Added
- Migration 013: `relationships` table with trigger/action foreign keys to functions
- `Legion::Data::Model::Relationship` Sequel model with trigger/action associations
- Relationship model registered in model loader (loaded before Task for association resolution)
- Uncommented `trigger_relationships` and `action_relationships` associations on Function model

## v1.2.0
Moving from BitBucket to GitHub. All git history is reset from this point on
