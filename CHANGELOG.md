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
