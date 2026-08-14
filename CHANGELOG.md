## 0.4.0 - 2026-08-14

- Added explicit live-query invalidation and optional `PRAGMA data_version`
  monitoring for writes committed through other abstractions or connections.
- Added typed `DbHasMany`, `DbHasOne`, and `DbBelongsTo` relationships with
  single-row, batched, live, bind-limit-safe, and per-parent-limited loading to
  avoid N+1 reads without application-owned SQL.
- Added typed heterogeneous `DbMergedRelationships` feeds with cross-table
  cursor ordering, per-parent limits, stable tie-breakers, key loading, and
  exclusive before/after cursor bounds.
- Added typed grouped selections with `groupBy`, `having`, aggregate aliases,
  decoding, counts, query compilation, plans, and live results.
- Expanded joined selections with ordering, pagination, distinct results,
  decoding, first/count/existence operations, compilation, and query plans.
- Added generated columns, expression indexes, triggers, column checks and
  collations, plus declared foreign-key/index/STRICT/WITHOUT ROWID validation.
- Expanded observations with sequence IDs, UTC start times, slow-operation
  classification, sanitized SQL fingerprints, and application context.
- Fixed asynchronous developer-CLI error handling and Windows path assertions.
- Updated the LMS consumer to load typed message/event/membership timelines in
  one cross-table ULID order, use typed transactional cleanup, and validate
  declared production schema invariants.

## 0.3.0 - 2026-08-01

- Added a project-aware developer CLI with configuration discovery, migration
  scaffolding, generated registries, source locks, validation, and diagnostics.
- Kept migrations as conventional `DbMigration` classes with ordinary
  `up()`/`down()` methods and `DbSchema`; no secondary migration-plan DSL.
- Added deterministic timestamp migration versions and filename/source metadata
  validation.
- Added editable draft migrations and explicit `migrate:finalize`; SHA-256
  source locks refuse changes or removal only after history is finalized.
- Added the readable `lib/database/migrations.dart` project index, maintained
  only by explicit CLI commands. No `.g.dart`, watcher, or build-runner workflow
  is introduced, and checksum metadata remains outside normal application code.
- Kept databases from checksum-enabled releases compatible when applications
  adopt the new checksum-free readable migration index.
- Added transaction-bound `DbMigrationContext` schema, SQL, query, and data
  helpers, common table-definition shortcuts, and centralized connection
  configuration with foreign keys enabled by default.
- Added `SqliteLoomProject.initialize` to configure a connection, apply pending
  migrations, and return a ready `SqliteLoom` instance in one operation.
- Added `SqliteLoomDatabase`, a package-owned, concurrency-safe lifecycle with
  name/path resolution, lazy platform factories, test connection injection,
  ready typed/raw access, failure cleanup, and idempotent closing.
- Routed result-returning connection PRAGMAs through `rawQuery` for Android
  sqflite compatibility, including `busy_timeout` and `synchronous`.
- Added first-class retired migration versions so consolidated unreleased
  migrations remain accepted in existing development databases without running
  placeholder migrations on fresh databases.
- Added lock-backed `migrate:retire` and `migrate:unretire` commands, removing
  manual retired-version bookkeeping from project YAML.
- Added `make:migration --create <table>` and `--table <table>` scaffolding.
- Expanded the application-owned database runner with targeted migration,
  rollback/redo/reset/refresh/fresh, JSON output, sandbox rehearsals, schema
  dumps and drift detection, integrity/inspection/optimization, and backups.
- Added native table listing, schema description, bounded row browsing,
  guarded read-only SQL, query-plan inspection, and streaming CSV/JSON export.
- Added parameter-bound insert/update/delete shortcuts, explicit truncation,
  controlled single-statement write SQL, atomic CSV/JSON import, table copy,
  mutation previews, and database vacuuming.
- Added production and interactive safeguards for destructive commands.
- Added flavor-aware YAML configuration under `config/sqlite_loom`, `--env`
  selection, process-environment overrides, and `make:flavor` scaffolding.
- Re-exported migration executor types so applications do not need a direct
  `sqflite_common` dependency solely to author migrations.
- Made destructive rebuilds restore the connection's original foreign-key mode.

## 0.2.0 - 2026-08-01

- Added typed single-column projections with live-query support.
- Added multi-column `select`, compiled-query inspection, and query plans.
- Added batched `insertAll` and native SQLite `upsert`/`upsertAll` operations.
- Added key-aware watch invalidation and primary-key change tracking.
- Added keyset cursor helpers, numeric aggregates, and text predicates.
- Added JSON text and BLOB codecs plus typed JSON mapping.
- Added raw reads and explicitly dependency-tracked raw watches.
- Expanded schema helpers with strict/without-rowid tables, checks, column
  rename/drop operations, and views.
- Made database shutdown await change-stream disposal.
- Added operation observers, bounded batch chunks, savepoints, connection
  tuning, integrity checks, optimization, vacuum, and backup helpers.
- Added migration checksums and runtime table/column affinity validation.
- Added joined projections, projection decoders, distinct reads, composite-key
  predicates, JSON1/FTS predicates, and FTS5 schema creation.
- Added SQLite `RETURNING`, optimistic version updates, and soft deletes.
- Added a reusable integration-test harness and bulk-write benchmark.
- Added runtime SQLite capability detection and early guards for `RETURNING`,
  strict tables, FTS5, column drops, and `VACUUM INTO`.
- Hardened optimistic updates, migration checksum/concurrency behavior,
  observer isolation, diagnostic value redaction, and trusted schema SQL APIs.
- Added bounded `SQLITE_BUSY` migration retries, idempotent shutdown, batch and
  failed-operation observations, and live-query cancellation guarantees.
- Expanded runtime schema validation with primary-key and Dart/SQL nullability
  checks and made JSON/FTS capability detection probe the active runtime.
- Added randomized predicate, failure-injection, migration-concurrency, public
  API compatibility, cross-platform CI, and performance-regression gates.

## 0.1.1 - 2026-07-30

- Removed the premature `documentation` URL; pub.dev provides the generated API
  reference link automatically.

## 0.1.0 - 2026-07-30

- Initial release of the generator-free reactive SQLite core.
- Added typed tables, columns, row decoding, immutable queries, safe writes, transactions, and live query streams.
- Added migrations, schema builder helpers, and app-owned CLI command runner.
- Added a complete runnable example, API documentation, an AI context file,
  and production best-practices guidance.
