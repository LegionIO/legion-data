# Legion::Data Changelog

## [1.10.6] - 2026-07-03

### Changed
- Migration 136: drops the `(conversation_id, seq)` UNIQUE constraint on `llm_messages`, replacing it with a NON-unique composite index. A conversation is a tree, not a line — a single parent can legitimately have two children at the same depth (e.g. a failed branch and the branch that continued), so two distinct messages can share `(conversation_id, seq)` and that is truth, not a duplicate. The unique constraint rejected legitimate siblings and forced the centralized ledger into a racy `MAX(seq)+1` generation that collided under concurrent writers (`PG::UniqueViolation` on `llm_messages_conversation_id_seq_key`). Message identity remains guaranteed by the unique `uuid`; `seq` becomes descriptive tree-depth. On SQLite the constraint drop rebuilds the table (dropping the inline `uuid` UNIQUE), so the migration re-asserts the uuid unique index — a no-op on PostgreSQL where `DROP CONSTRAINT` is surgical.

## [1.10.5] - 2026-06-16

### Added
- Migration 135: adds context token accounting columns to `llm_message_inference_metrics` — `llm_message_inference_metrics` is now the canonical source of truth for all pipeline context token metrics (request messages, loaded/curated/archived history, thinking strip savings, context-window enforcement savings, RAG injection, system/baseline prompt, tool definitions, final context estimate). Includes `context_accounting_status` and `context_accounting_json` for provenance.
- Migration 135: creates `llm_context_accounting_events` table for drill-down evidence rows (not a second source of token truth — totals reconcile to the canonical metrics row).
- Model: `Legion::Data::Models::LLM::ContextAccountingEvent` with foreign key associations to request, response, and metric.
- Association: `MessageInferenceMetric#context_accounting_events`.

## [1.10.4] - 2026-06-12

### Added
- Migration 134: adds `operation` (String 64), `dispatch_path` (String 32), and `idempotency_key` (String 128) columns to `llm_route_attempts` with indexes on `operation` and `idempotency_key`. Enables per-attempt tracking of the LLM operation type, routing path, and deduplication key.

## [1.10.3] - 2026-06-10

### Changed
- `connection_validation` now defaults to `false` — the Sequel connection_validator extension issues a `SELECT NULL` on every pool checkout/checkin and before real queries, which measurably degrades throughput; query-time error handling already recovers stale/dead connections. Set `connection_validation: true` in settings to opt back in (timeout semantics unchanged: `-1` validates every checkout)
- Pool timeout assignments read `connection_validation_timeout` / `connection_expiration_timeout` directly from settings — removed inline `|| 600` / `|| 14_400` shadow defaults that disagreed with the documented settings defaults

## [1.10.2] - 2026-06-02

### Fixed
- Replace `return` with `next` in migration blocks — Sequel uses `instance_exec`, bare `return` raises `LocalJumpError` (migrations 019, 044, 045, 046, 118, 120)
- Make migrations 118-130 idempotent with schema column checks for safe re-run after partial failures
- Restore migration 131 (`add_column :schema_version` to `llm_tool_calls`) with idempotent guard — preserves contiguous migration sequence for existing installations

### Added
- Migration 132: drops unused `schema_version` column from `llm_tool_calls` (no code reads/writes it)
- Migration 133: allows NULL on `context_tokens` in `llm_message_inference_requests` — prevents NOT NULL violations when token counts are unavailable

## [1.10.1] - 2026-06-01

### Added

- Migration 130: adds `pii_types_json` (TEXT) and `jurisdictions_json` (TEXT) to `llm_conversations`. Required by lex-llm-ledger OfficialRecordWriter for compliance metadata.

### Removed

- `schema_version` column removed from lex-llm-ledger writer — no longer written to any table. Column remains on `llm_skill_events` (migration 129) but is not actively populated.

## [1.10.0] - 2026-06-01

### Added

- Migration 129: creates `llm_skill_events` table as a core LLM lifecycle table (moved from lex-llm-ledger extension). Columns: `uuid`, `conversation_id`, `request_ref`, `skill_name`, `skill_version`, `trigger`, `status`, `duration_ms`, `identity_canonical_name`, `identity_principal_id`, `identity_id`, `schema_version`, `recorded_at`, `inserted_at`. Indexes on `conversation_id`, `request_ref`, `skill_name`, `identity_canonical_name`, `recorded_at`, `inserted_at`.

## [1.9.0] - 2026-06-01

### Added

- Migration 123: audit columns on `llm_tool_calls` — `tool_arguments_json` (TEXT), `tool_result_json` (TEXT), `tool_category` (String(64)), `data_handling_classification` (String(32)), `policy_decision` (String(32)), `requires_human_approval` (Boolean) plus indexes on `tool_category`, `data_handling_classification`, `policy_decision`.
- Migration 124: audit columns on `llm_tool_call_attempts` — `attempt_input_json` (TEXT), `attempt_output_json` (TEXT), `error_details_json` (TEXT).
- Migration 125: audit columns on `llm_escalation_events` — `history_json` (TEXT), `outcome` (String(32)), `total_attempts` (Integer) plus index on `outcome`.
- Migration 126: audit columns on `llm_message_inference_responses` — `route_attempts` (Integer, default 0), `escalation_chain_ref` (String(128)) plus index on `escalation_chain_ref`. Skips `response_content_hash` (already exists since migration 080).
- Migration 127: audit columns on `llm_message_inference_requests` — `parent_request_id` (Integer, self-referencing FK on_delete: :set_null). Skips `request_content_hash`, `curation_strategy`, `tool_policy` (all already exist since migration 079).

## [1.8.9] - 2026-05-26

### Changed
- Migration 116: make `llm_tool_calls.message_inference_response_id` nullable and drop composite unique index on `[message_inference_response_id, tool_call_index]`. Eliminates 30-40% dead-letter rate on tool audit messages caused by AMQP race between response and tool call writers.
- Migration 117: add nullable `conversation_id` FK to `llm_tool_calls` referencing `llm_conversations`, so tool call rows can track their conversation even when the response row hasn't been written yet.
- Add `many_to_one :conversation` association to `LLM::ToolCall` model.

## [1.8.8] - 2026-05-20

### Added
- `Legion::Data::Connection.reconnect_with_fresh_creds` — updates Sequel's internal connection opts with fresh credentials from `Legion::Settings[:data][:creds]` and reconnects the pool. Called by `LeaseManager#trigger_postgresql_reconnect` after Vault dynamic PostgreSQL lease rotation.

### Fixed
- Vault dynamic PostgreSQL credential rotation: after lease expiry, connections would fail with `PG::ConnectionBad: role "v-legionio-node-..." does not exist` because Sequel retained the original (revoked) credentials in `@opts`. The legacy fallback (`disconnect` + `test_connection`) was insufficient since it doesn't update stored credentials.

## [1.8.7] - 2026-05-17

### Added
- Migrations 103-114: adds standardized identity columns (`access_scope`, `identity_principal_id`, `identity_id`, `identity_canonical_name`) to all 12 LLM lifecycle tables. Tables that already carried identity columns under legacy names (`principal_id`/`identity_id` on `llm_conversations`, `caller_principal_id`/`caller_identity_id` on `llm_message_inference_requests`) receive only `access_scope` and `identity_canonical_name` — existing columns are not renamed. Each table is its own migration with full `access_scope` index and partial `identity_principal_id` index.

## [1.8.6] - 2026-05-15

### Added
- Migration 100: creates `apollo_entries` and `apollo_entries_archive` tables on non-Postgres adapters (SQLite etc.), bringing them to parity with the existing Postgres schema.
- Migration 101: adds `access_scope VARCHAR(20) NOT NULL DEFAULT 'global'`, `identity_principal_id INTEGER`, `identity_id INTEGER`, `identity_canonical_name VARCHAR(255)` columns on both `apollo_entries` and `apollo_entries_archive` across all adapters. Existing rows default to `global` access scope.
- Migration 102: adds indexes on `apollo_entries` — full index on `access_scope`, partial indexes on `identity_principal_id` and `identity_id` (WHERE NOT NULL) across all adapters.

## [1.8.5] - 2026-05-09

### Removed
- Unnecessary `defined?(Legion::Logging)` guards from connection and local database setup — legion-logging is a hard gemspec dependency and always available

## [1.8.4] - 2026-05-08

### Removed
- Dropped legacy postgres-only identity tables (`principals`, `identity_providers`, `identities`, `identity_groups`, `identity_group_memberships`, `identity_audit_log`) via migration 098.
- Removed `table_available?` guards from all identity model files — models load unconditionally.

### Changed
- Renamed `portable_identity_*` tables to canonical names (`identity_principals`, `identity_providers`, `identities`, `identity_groups`, `identity_group_memberships`, `identity_audit_log`, `identity_provider_capabilities`) via migration 099.
- Updated all identity models to reference the new table names.

## [1.8.3] - 2026-05-07

### Removed
- Legacy top-level identity model files (`identity.rb`, `principal.rb`, `identity_provider.rb`, `identity_group.rb`, `identity_group_membership.rb`, `identity_audit_log.rb`) — superseded by the portable `identity/` namespace models backed by `portable_*` tables.

### Fixed
- `TypeError: superclass mismatch for class Identity` on postgres startup caused by `model_helpers.rb` defining `class Identity` as a plain namespace before `identity.rb` tried to reopen it as `< Sequel::Model(:identities)`.

## [1.8.2] - 2026-05-07

### Changed
- Refactored `Legion::Data.setup` to call `setup_global`, `setup_cache`, then `setup_local` in explicit order — eliminates the `ensure setup_local` footgun that ran local SQLite even when global setup failed.
- Extracted `setup_global` (connection + migrate + load_models) and promoted `setup_local` and `setup_cache` to top-level public methods with their own `rescue` blocks (`fatal` for local/global, `error` for cache).
- SQLite main database now resolves to `~/.legionio/data/legionio.db` instead of a relative path in the process working directory; existing absolute path overrides in settings are unchanged.

## [1.8.1] - 2026-05-07

### Fixed
- `TypeError: superclass mismatch for class Identity` on startup: moved `require_relative 'identity/model_helpers'` inside the `Identity < Sequel::Model(:identities)` class body so the Sequel superclass is established before `model_helpers.rb` reopens the constant.

## [1.8.0] - 2026-05-06

### Added
- Migration 097 adds official LLM dispatch fields for fleet operation, correlation, idempotency, provider instance, and dispatch path tracking.

### Changed
- LLM lifecycle Sequel models now live under `Legion::Data::Models::LLM` to match the official data model namespace.

## [1.7.5] - 2026-05-05

### Added
- Migrations 077-090: portable LLM lifecycle schema covering conversations, messages, message inference requests/responses, route attempts, inference metrics, provider-requested tool calls, tool call attempts, conversation compactions, policy evaluations, security events, and registry events.
- Migrations 091-096: portable identity companion schema with integer primary keys, public UUIDs, normalized provider capabilities, principals, identities, groups, memberships, and audit events.
- Sequel models and associations for the new `Legion::Data::Models::LLM` lifecycle tables.
- Nested Sequel model namespaces for Identity, Apollo, and RBAC tables.
- Lookup helpers for nested and legacy identity models.
- LLM reconstruction query helpers for audit lineage, finance rollups, security incident lineage, and message-to-tool incident flow.
- Additional Sequel associations for core execution and identity models, including function/task, relationship/chain, task/worker, task log aliases, and principal/group many-to-many membership helpers.

## [1.7.4] - 2026-04-28

### Fixed
- Pre-commit RuboCop hook now distinguishes missing tools from real RuboCop failures and propagates failures instead of silently passing.
- Ruby syntax pre-commit hook now checks every staged Ruby file instead of only the first argument.
- Connection setup now refreshes the configured adapter before each setup call and clears fallback state on shutdown so fallback health checks do not stay stale across reconnects.

### Changed
- README refreshed for the current migration count, version line, fallback diagnostics, pre-commit workflow, and recent model surface.

## [1.7.3] - 2026-04-27

### Added
- Migration 074: widens Apollo `content_hash` to 64 fixed characters and `knowledge_domain` / `source_provider` / `source_agent` to 255 characters so SHA-256 hashes and real-world identifiers fit without ingestion truncation failures. (Fixes #33, #34)
- Migration 075: adds task `idempotency_key` and `idempotency_expires_at` columns plus indexes for SHA-256 payload deduplication windows. (Fixes #14)
- Migration 076: adds `extract_step_timings` for per-step Extract pipeline timing visibility. (Fixes #15)
- `Task.idempotency_key_for`, `Task.find_active_by_idempotency_key`, and `Task.create_idempotent` for stable content-addressed task dispatch deduplication. (Fixes #14)
- Extract results now include `extract_id` and `step_timings`, and persist timing rows when the migration is present. (Fixes #15)
- `AuditLogHashChain` plus `AuditLog.compute_hash` / `AuditLog.verify_chain` as the canonical data-side audit log hash-chain implementation for standard write paths to share. (Refs #13)

### Fixed
- Migration 051 now adds SQLite/MySQL `tasks.created_at` without a non-constant default before backfilling from `created`, allowing later migration specs and fresh SQLite databases to migrate cleanly.

## [1.7.2] - 2026-04-27

### Fixed
- Dev-fallback to SQLite now logs at `:error` level with explicit warnings that data written to SQLite will not be visible when the configured network database reconnects.

### Added
- `Connection.connection_info` — returns adapter, connection state, and fallback status for health checks and diagnostics
- `Connection.fallback_active?` — returns true when the data layer fell back to SQLite from a configured network database; Apollo and other services can check this to detect degraded mode and log appropriate warnings

## [1.7.1] - 2026-04-27

### Fixed
- `QueryFileLogger` now treats writes after `close` as no-ops, preventing repeated `IOError: closed stream` warnings from late Sequel query callbacks during shutdown. (Fixes #35)

## [1.7.0] - 2026-04-24

### Added
- Migration 072: `identity_audit_log` table (Postgres-only) with indexes
- Migration 073: `employee_id` on principals, `account_type`/`qualifier`/`is_default`/`link_evidence` on identities, partial unique index for one-default-per-provider
- `IdentityAuditLog` model added to model loader

## [1.6.30] - 2026-04-22

### Fixed
- `Spool.extension_path` now accepts any module under `Legion::`, not just `Legion::Extensions::` — fixes `ArgumentError` when core gems like `legion-llm` spool events via `Spool.for(Legion::LLM)`

## [1.6.29] - 2026-04-17

### Fixed
- `Connection#log_connection_info`: renamed local variables `user`/`host`/`port`/`db` to `conn_user`/`conn_host`/`conn_port`/`conn_db` to avoid shadowing outer-scope names and resolve `rb/uninitialized-local-variable` CodeQL alert
- CI workflow: added explicit `permissions:` block to all jobs (`contents: read` for checkout jobs, `{}` for reusable workflow calls) to satisfy `actions/missing-workflow-permissions` code scanning alerts
- Spec: replaced deprecated `raise_exception` matcher with `raise_error` in `connection_spec.rb` and `model_spec.rb`; updated stale test description in `model_spec.rb`

## [1.6.28] - 2026-04-17

### Changed
- `legion-json` added as explicit gemspec runtime dependency — `Legion::JSON` is used throughout and was previously only an implicit transitive dependency
- Rewrote `README.md` with accurate architecture diagram, full model table, migration history, configuration reference, and usage examples
- Updated `CLAUDE.md` with mandatory `bundle exec rspec` + `bundle exec rubocop -A` reminder for AI agents
- Added `AGENTS.md` with mandatory rspec/rubocop reminder and gem overview
- Updated `.github/CODEOWNERS` to `@Esity @LegionIO/core`
- Added `*.gem` to `.gitignore` to prevent build artifacts from being committed
- Removed `sonar-project.properties`

## [1.6.27] - 2026-04-17

### Fixed
- `load_sequel_model` now reads `settings[:models][:continue_on_load_fail]` (was erroneously reading `continue_on_fail`, a key that never existed — LoadError was always re-raised regardless of the setting). (Fixes #22)
- `load_models` now skips model loading when `settings[:models][:autoload]` is `false`, honoring the documented knob. (Fixes #22)
- Audit record live-path specs (`append`, `verify`, `walk`, `query_by_type`, immutability guards) are now self-sufficient: the `before` block reconnects the DB if a prior spec tore it down, eliminating 19 pending examples when running the full suite. (Fixes #22)
- Default `preconnect` changed from `'concurrently'` to `false`. The concurrent preconnect mode spawned background threads that emitted noisy connection errors when a network adapter was unreachable before dev-fallback could catch the failure. `false` preserves identical behavior for SQLite (default) and avoids the noise for production deployments where operators can opt-in explicitly. (Fixes #22)

## [1.6.26] - 2026-04-17

### Fixed
- `connection_validation_timeout` default reduced from 600s to -1 (validate every checkout) for non-SQLite adapters. The previous 10-minute window meant stale PG connections from a VPN drop, sleep/wake, or network interface change were not evicted until the next scheduled validation cycle, causing `Sequel::DatabaseDisconnectError` to repeat on every actor tick. With -1, Sequel pings the connection on every pool checkout and discards dead connections immediately. (Fixes #28)

## [1.6.24] - 2026-04-13

### Added
- Migration 070: `resume_routing_key` and `resume_exchange` columns on `approval_queue` table (nullable String 255) to support fleet pipeline resume on approval
- Migration 071: `engine` VARCHAR(50) NULL column on `relationships` table — enables fleet pipeline to store explicit transformer engine selection per relationship

## [1.6.23] - 2026-04-07

### Fixed
- Migration 067: parenthesize CASE expression in `idx_memberships_trust_tiebreak` index (PG syntax error)

## [1.6.22] - 2026-04-06

### Added
- Migration 063: `identity_providers` table (provider_type, facing, priority, trust_weight, capabilities)
- Migration 064: `principals` table (canonical_name regex constraint, kind, unique composite)
- Migration 065: `identities` table (principal/provider FKs, partial unique index on active)
- Migration 066: `identity_groups` table (source: ldap/entra/manual)
- Migration 067: `identity_group_memberships` table (status, trust_weight, discovered_by, tie-break index)
- Migration 068: `entity_type` column on `audit_records` with index
- Migration 069: `principal_id` FK on `nodes` table
- 5 Sequel models: `IdentityProvider`, `Principal`, `Identity`, `IdentityGroup`, `IdentityGroupMembership`
- `Identity` model wired through `SequelPlugin` `encrypted_column :profile` for at-rest encryption
- `Node` model gains `many_to_one :principal` association

### Changed
- Migration mode gate: only `:infra` mode runs migrations when `Legion::Mode` is available
- `auto_migrate` settings check wired into `Data.setup` (skips migrations when `auto_migrate: false`)
- Mode guard added to both `Data.migrate` and `Migration.migrate` for defense-in-depth

## [1.6.21] - 2026-04-05

### Added
- Migration 062: `tool_embedding_cache` table for global embedding persistence

## [1.6.20] - 2026-04-03

### Fixed
- Local SQLite now uses WAL journal mode, 30s busy_timeout, and synchronous=NORMAL to reduce write contention
- Local SQLite path resolved to `~/.legionio/` absolute path instead of using relative CWD

## [1.6.19] - 2026-04-02

### Changed
- Logging uplift across non-API `lib/` modules to use `Legion::Logging::Helper` and `log.*` instead of direct `Legion::Logging.*` calls
- Removed direct `log_info` / `log_warn` wrapper usage in partition management and aligned logging with helper-backed tagged loggers
- Added broader info-level operational logs for archival, retention, spool, extract, storage-tier, and partition workflows

### Fixed
- Added `handle_exception(...)` coverage to rescue paths across non-API data modules so failures are logged consistently without changing existing fallback behavior
- Added compatibility fallback for `handle_exception` when older `legion-logging` releases are present in the runtime
- Included `metadata_json` in EventStore integrity hashes for new events while preserving verification compatibility for legacy rows
- Fixed encrypted Sequel columns to re-encrypt newly-created rows with their persisted primary key and maintain legacy read compatibility
- Hardened spool persistence with atomic writes, deterministic replay ordering, and corrupt-file quarantine during read/flush
- Updated partition manager specs to assert against helper-backed logger behavior

## [1.6.18] - 2026-03-30

### Added
- Migration 061: versioning and expiry columns on `apollo_entries` — `parent_knowledge_id` (UUID), `is_latest` (boolean, default true), `supersession_type` (VARCHAR 20), `expires_at` (timestamptz), `forget_reason` (VARCHAR 255), `is_inference` (boolean, default false) — postgres only
- Migration 061: 4 named indexes including partial indexes: `idx_apollo_parent_knowledge`, `idx_apollo_version_chain` (partial WHERE is_latest), `idx_apollo_expiry` (partial WHERE expires_at IS NOT NULL), `idx_apollo_inference` (partial WHERE is_inference)
- Spec for migration 061 covering column presence, types, nullability, defaults, all 4 indexes, and idempotency

## [1.6.17] - 2026-03-30

### Added
- Migration 060: L0/L1 summary columns on `apollo_entries` (`summary_l0` VARCHAR 500, `summary_l1` TEXT, `knowledge_tier` VARCHAR 4 default 'L2', `parent_entry_id` UUID, `l0_generated_at` timestamptz, `l1_generated_at` timestamptz) — postgres only
- Migration 060: named indexes `idx_apollo_knowledge_tier` and `idx_apollo_parent_entry` on `apollo_entries`
- Spec for migration 060 covering column presence, types, nullability, defaults, indexes, and idempotency

## [1.6.16] - 2026-03-30

### Fixed
- Migration 019: widen `record_hash` column to size 255 via `set_column_type` (column added in migration 017)
- Migration 019: rename `prev_hash` to `previous_hash` via `rename_column` instead of adding a duplicate column
- Migration 019: decouple index creation from column existence checks so indexes are always guarded by their own `idxs.key?` check
- Migration 019: `down` no longer drops `record_hash` (owned by migration 017, not 019)
- Migration 019: replace `db.indexes` with bare `indexes()` — inside a `Sequel.migration` block `self` is the DB object, so `db` is undefined
- Updated to rubocop-legion (`inherit_gem: config/core.yml`) for shared LegionIO cop configuration

### Added
- Migration 019 spec: 8 examples covering column presence, defaults, indexes, idempotency, and rollback

## [1.6.15] - 2026-03-29

### Added
- `data_adapter` — current database adapter type (:sqlite, :mysql2, :postgres)
- `data_pool_stats` — connection pool metrics (size, available, in_use, waiting)
- `data_stats` — combined shared + local database statistics
- `local_data_stats` — local SQLite database statistics
- `data_can_read?(table_name)` — table read permission check
- `data_can_write?(table_name)` — table write permission check

## [1.6.14] - 2026-03-29

### Added
- Migration 059: `chains` table (id, name, active, created, updated) for workflow bundle chain tracking
- `Legion::Data::Model::Chain` — Sequel model with `one_to_many :relationships` association

## [1.6.13] - 2026-03-28

### Added
- `Legion::Data::AuditRecord` — tamper-evident audit record primitive with SHA-256 hash chain (closes #7)
  - `append(chain_id:, content_type:, content_hash:, metadata: {}, sign: false)` — inserts a new record, linking it to the previous tail via `parent_hash` and `chain_hash`
  - `verify(chain_id:)` — walks the chain and re-derives every hash, returning `{ valid:, length: }` or `{ valid: false, broken_at:, reason: }` on tampering
  - `walk(chain_id:, since: nil, limit: 1000)` — return deserialized records in chronological order
  - `query_by_type(content_type:, since: nil, limit: 100)` — cross-chain query by content_type
  - `compute_chain_hash(parent_hash, content_hash, timestamp, content_type)` — public for independent verification
  - Multiple independent chains share a single `audit_records` table, keyed by `chain_id`
  - Chain hash formula: `SHA256("parent_hash:content_hash:unix_ns:content_type")` — timezone-independent via nanosecond epoch
  - Optional signing via `Legion::Crypt.sign` when `sign: true`; signature column is nil when signing is unavailable
- Migration 058: `audit_records` table with `chain_id`, `content_type`, `content_hash`, `parent_hash`, `chain_hash` (unique), `signature`, `metadata`, `created_at`; PostgreSQL `NO UPDATE/DELETE` rules for DB-level append-only enforcement
- `Legion::Data::Model::AuditRecord` — Sequel model with `before_update`/`before_destroy` immutability guards and `parsed_metadata` helper
- 29 new specs covering constant, hash computation, DB-unavailable guards, chain creation, chain verification, tamper detection, walk/query operations, and model immutability

## [1.6.12] - 2026-03-28

### Added
- VTT (WebVTT) extract handler for meeting transcript parsing (`Handlers::Vtt`)
  - Parses speaker tags (`<v SpeakerName>`), timestamps, and WEBVTT header
  - `preserve_speakers: true` (default) prefixes each line with speaker name
  - Accepts inline VTT string content or a file path
  - Returns `{ text:, metadata: { bytes:, speakers:, line_count: } }`
- `.vtt` extension registered in `TypeDetector::EXTENSION_MAP` (maps to `:vtt`)

## [1.6.11] - 2026-03-28

### Added
- Migration 050: critical missing indexes across 13 tables (runners, tasks, digital_workers, audit_log, webhook_deliveries, webhook_dead_letters, conversations, approval_queue, rbac_role_assignments, rbac_cross_team_grants, memory_traces, agent_cluster_tasks, finlog_executions)
- Migration 051: fix tasks archival column mismatch — adds `created_at` column (PG: generated from `created`, SQLite/MySQL: backfilled)
- Migration 052: drop redundant Apollo indexes (PG only) — auto-named duplicates from migration 012 superseded by explicit indexes in migration 047
- Migration 053: FK constraint for `tasks.relationship_id` (PG only) with orphan cleanup and ON DELETE SET NULL
- Migration 054: add `component_type` column to functions table (v3.0 naming convention — runner/hook/absorber)
- Migration 055: add nullable `definition` text column to functions table (v3.0 method contract storage)
- Migration 056: add `absorber_patterns` table for pattern-matched content acquisition (v3.0)
- Migration 057: add `routing_key` column to runners table (v3.0 AMQP routing key storage)

### Fixed
- `Archival::Policy` now includes `DATE_COLUMN_OVERRIDES` map for legacy tables using non-standard date columns

## [1.6.10] - 2026-03-28

### Added
- Migration 049: adds `remote_invocable` boolean column (default: true) to the `functions` table. Allows per-function control over whether a registered function can be dispatched remotely via AMQP from the `LexDispatch` API layer.

## [1.6.9] - 2026-03-27

### Added
- Migration 048: financial logging schemas (7 tables) for UAIS cost recovery model
  - `finlog_identities` — worker/owner identity for cost attribution (worker_id, owner_msid, cost_center, business_segment)
  - `finlog_assets` — Entra app / service principal metadata (entra_app_id, asset_type, extension_name, risk_tier)
  - `finlog_environments` — cloud/infrastructure environment context (csp, account_id, askid, region, environment)
  - `finlog_accounting` — financial classification per execution (aide_id, ucmg_id, billing_group, classification, recovery_ratio, rate_card_multiplier, provider_discount, chargeback_amount)
  - `finlog_executions` — per-request execution record / central fact table (worker_id, task_id, provider, model_id, tokens, costs, latency)
  - `finlog_tags` — flexible key-value metadata tags per execution
  - `finlog_usages` — aggregated consumption rollup (daily period, per worker/provider/model)

## [1.6.8] - 2026-03-27

### Changed
- Documentation updates (CLAUDE.md, README.md)

## [1.6.7] - 2026-03-26

### Removed
- Legacy Vault credential fetch in `Connection#creds_builder` — hardcoded `database/creds/legion` path removed. Database credentials are now exclusively managed by the LeaseManager via `lease://postgresql#username` / `lease://postgresql#password` URI references in data settings.

## [1.6.6] - 2026-03-25

### Added
- `connected?` — returns true when the shared DB is connected (reads `Settings[:data][:connected]`)
- `can_write?(table_name)` — checks INSERT privilege; sqlite always returns true, postgres queries `has_table_privilege`, results cached per table
- `can_read?(table_name)` — checks SELECT privilege; sqlite always returns true, postgres queries `has_table_privilege`, results cached per table
- `reset_privileges!` — clears cached privilege results (used in tests and after re-connect)
- `Legion::Data::Extract` — file format extraction with handler registry
- Built-in handlers: text, markdown, csv, json, jsonl (no external gems required)
- Optional handlers: pdf (pdf-reader), docx (docx), pptx (rubyzip), xlsx (rubyXL), html (nokogiri) — lazy-loaded, degrade gracefully if gem not installed
- `Extract.register_handler(type, klass)` — register custom format handlers
- `Extract.can_extract?(type)` — check if a type can be extracted (handler present and gem available)
- `Extract.supported_types` — list all registered types
- Added `csv` gem dependency (Ruby 3.4 stdlib split)

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
