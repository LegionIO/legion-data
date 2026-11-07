Always run a full `bundle exec rspec` and `bundle exec rubocop -A` and fix all errors before committing.

# AGENTS.md - legion-data

## Repo Role

`legion-data` owns persistent storage for LegionIO. Keep this repo focused on database connectivity, Sequel migrations, Sequel models, local SQLite state, extraction persistence, audit/governance storage, identity/RBAC storage, Apollo storage, and the LLM lifecycle ledger.

HTTP APIs, runtime orchestration, extension behavior, and UI concerns belong in their owning repos. This repo should expose clean model contracts that those layers can call.

## Implementation Rules

- Follow the existing Legion framework patterns. Reuse the established implementation instead of inventing a replacement, generic abstraction, or convenience layer.
- Keep method-returned settings defaults directly in the existing methods. Do not extract the default/connection settings tree into a constant such as `CONNECTION_DEFAULTS`, a class variable, or a memoized snapshot. Register defaults at boot and read live values through `Legion::Settings`.
- Application-table reads and writes must use real, named Sequel models. Do not substitute a raw-database facade or move `connection[table]` behind a differently named helper.
- When a Data-owned table lacks a required model, add a normal `class Name < Sequel::Model(:table_name)` in the existing model namespace and register it in `Legion::Data::Models.models`.
- Do not introduce `Class.new`, anonymous/dynamic models, fake models, or model-loading workarounds. Use the named model classes in tests too; bind them to the isolated test database and restore their original datasets afterward.
- Verify table ownership from its migration before adding a model. An existing reference is not proof that legion-data owns or creates the table. Check adapter restrictions as well as the owning repository.
- Respect startup order: connect, migrate, load models, mark Data connected, then cache and local setup. Do not require model declarations before the database and schema are ready or hide a load-order problem with fallback classes or guards.
- Use fully qualified model names across module boundaries. Return plain Hashes rather than leaking Sequel model instances across those boundaries.
- Preserve existing behavior and public contracts unless the authorized change requires updating them. When an API changes, migrate its callers and documentation; do not add compatibility shims.
- The async persistence contract assumes prefetch 1: one persistence message performs one model insert or update. Do not reintroduce batching, attempt ownership, leases, or transactional outbox coordination for that path.
- Raw database access is appropriate for migrations and database infrastructure, not a substitute for models in application-table CRUD. Do not expand a model conversion into excluded migration or connection-management work.

## Scope and Interaction

- Work only in the repository and files the user authorizes. Do not sweep adjacent files, convert additional helpers, or redesign unrelated behavior.
- For per-file conversion work, finish the selected file before moving on: implement with the required models and caller/spec updates, verify, apply the requested patch-version and changelog bump, commit, and push to the existing branch. Then stop and wait for the next file.
- Necessary supporting changes are not permission for unrelated conversions. If the requested change needs work outside the authorized scope, identify the concrete dependency and obtain direction rather than improvising around it.
- When the user asks a question during work, answer that question first. Do not treat the question as permission for more edits or replace the answer with an action.
- Use direct Ruby, Bundler, and shell commands. Do not wrap ordinary project commands in Python or add orchestration scripts for simple edits, tests, commits, or pushes.
- Work in the existing development checkout and branch. Do not create another branch, worktree, clone, or PR without explicit direction. Never force-push.
- Preserve unrelated user changes. Stage explicit filenames only; never use `git add .` or `git add -A`.
- Do not claim completion before the scoped behavior is verified and the requested commit/push is finished. Report only checks actually run.

## Required Commands

Run from the repo root:

Use an isolated temporary `HOME` for Data tests: `spec/spec_helper.rb` deletes its test database under `~/.legionio/data/`. Never run it against the developer's real HOME. Set `LEGION_DNS_BOOTSTRAP=false` and preserve the real `RBENV_ROOT` when using rbenv. Apply those variables to the test command, not the parent environment.

```bash
mkdir -p tmp
test_home="$(mktemp -d)"
bundle exec rubocop -A
env HOME="$test_home" RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}" LEGION_DNS_BOOTSTRAP=false \
  bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt \
  > tmp/rspec_console.log 2>&1
```

If RSpec fails, extract failures with:

```bash
jq '[.examples[] | select(.status != "passed") | {file_path, line_number, full_description, status, exception: .exception}]' tmp/rspec_results.json > tmp/rspec_failures.json
```

Do not run partial RSpec or partial RuboCop for release validation.

For behavior changes, run the changed path against real models and an isolated database as a smoke check; a green suite alone is not proof of the changed path. Do not create mock-echo or default-pinning tests merely to restate the implementation.

## Migration Rules

- Never edit published migrations. Add a new migration instead.
- Do not guard migrations with `create_table?`, `drop_table?`, `table_exists?`, `if_exists`, `if_not_exists`, `next if`, or `next unless`.
- Keep migrations split by domain and dependency. Do not hide a whole schema rewrite in one large migration.
- Use portable Sequel DSL by default. Adapter-specific code is acceptable only for adapter-specific features, such as PostgreSQL vector columns.
- Prefer `id` integer primary keys for joins and `uuid` public identifiers for APIs, logs, and external references.
- Avoid JSON columns unless the data is genuinely dynamic provider evidence or cannot be normalized without losing meaning.

## Sequel Association Rules

Use the official Sequel association APIs as the model contract:

- Association API reference: https://sequel.jeremyevans.net/rdoc/classes/Sequel/Model/Associations/ClassMethods.html
- Association basics: https://github.com/jeremyevans/sequel/blob/master/doc/association_basics.rdoc

Required mapping:

| Schema shape | Sequel association |
|--------------|--------------------|
| This table has the foreign key | `many_to_one` |
| Other table has the foreign key | `one_to_many` or `one_to_one` |
| Join table connects both sides | `many_to_many` |
| One associated row through a join table | `one_through_one` |

Rules:

- Define associations for real foreign-key relationships when adding or changing models.
- Prefer association methods and association datasets over ad hoc `where(foreign_key: ...)` lookups in model helpers.
- When names are not inferable, explicitly set `:class`, `:key`, `:primary_key`, `:join_table`, `:left_key`, and `:right_key`.
- Do not create association names that collide with actual column names; Sequel creates methods using the association name.
- Keep namespace models aligned with API/domain shape, for example `Legion::Data::Model::Identity::*`, `LLM::*`, `Apollo::*`, and `RBAC::*`.

## Current Schema Notes

- Use `lib/legion/data/migrations/` as the authoritative migration inventory.
- `074`-`076` are mainline Apollo/task/extract migrations.
- `077`-`090` define the LLM lifecycle ledger.
- `091`-`096` define portable identity companion tables.
- Published PostgreSQL identity migrations remain in place; portable identity tables are additive.

## Release Hygiene

For behavior, model, migration, or Ruby code changes:

- Update `lib/legion/data/version.rb`.
- Update `CHANGELOG.md`.
- Update `README.md` when public behavior, schema, configuration, or model surface changes.
- Keep `.gitignore` ignoring `/Gemfile.lock` and `*.gem`.
- Do not include generated DBs, logs, coverage output, built gems, or repo-external `/docs` workspace files in commits.
