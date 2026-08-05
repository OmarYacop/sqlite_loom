# SQLite Loom best practices

## Schema and migrations

1. Treat applied migration versions as immutable. Add a new migration instead of
   editing one already shipped.
2. Give every migration a stable integer version and descriptive snake-case
   name.
3. Provide `down` callbacks when rollback is genuinely safe. The default throws
   rather than pretending a migration is reversible.
4. Keep `fresh` disabled in production. It requires an explicit destructive
   opt-in, but application code should still restrict where it is exposed.
5. Back up important databases before destructive migrations and test migrations
   against production-shaped data.
6. Use `dart run sqlite_loom make:migration <name>` for sortable migration
   versions, commit the readable migration index and source lock, and run
   `migrate:validate` in CI.
7. Edit draft migrations freely, then run `migrate:finalize` before releasing.
   Never edit finalized, applied, or distributed history.
8. Rehearse with `sandbox` and check `schema:diff` before deploying migrations.
9. Use `DbMigrationContext` rather than constructing `DbSchema` or retaining an
   executor. Configure each open connection once with
   `configureSqliteLoomConnection` before migrations.
10. Let `SqliteLoomDatabase.ready` own open/configure/migrate sequencing and
    share concurrent startup callers. Inject the ready `SqliteLoom` into
    repositories instead of creating an application singleton wrapper.

## Tables and values

- Keep models immutable and implement value equality, or override
  `DbTable.equals`. Live queries use it to suppress duplicate emissions.
- Match nullable Dart columns to nullable SQL definitions.
- Omit an auto-increment key from `DbValues` until SQLite assigns it.
- Centralize each table instance behind a database extension or repository.
- Prefer typed column predicates to hand-written SQL.
- Keep `DbSqlLiteral`, `DbPredicate.trusted`, `DbOrdering.trusted`, and
  `DbColumnDefinition.trusted` SQL arguments entirely developer-authored. Never
  build them from user, server, or configuration values.

## Queries and writes

- Add deterministic ordering before using `limit` or `offset`.
- Keep pagination queries short-lived; use keyset pagination for large tables.
- Use `after`/`before` keyset cursors instead of large offsets.
- Use `pluck(column)` or `select([column1, column2, ...])` when a read does not
  need a complete model.
- Use `insertAll` and `upsertAll` so bulk writes execute as SQLite batches.
- Set `batchSize` for very large inputs and wrap chunks in a transaction when
  the entire operation must be atomic.
- Keep `.sqlite_loom/migrations.lock.json` under version control after
  finalizing migrations; checksum metadata stays out of application Dart.
- Override `DbTable.columns` and validate the live schema in integration tests.
- Use a transaction for multi-step invariants.
- Remember that `allRows()` is an explicit safety escape hatch, not a default.
- Include all affected tables when using `rawWrite`, including tables changed by
  triggers when their live queries must refresh.
- Inspect `await db.capabilities()` when an application needs optional SQLite
  behavior across different platform builds.

## Reactive queries

- Create watches outside transactions.
- Store and cancel subscriptions according to the UI or service lifecycle.
- Override row equality for domain models to avoid redundant emissions.
- A watch reruns its query when the table changes; it is invalidation-based, not
  a row-level change feed.

## Testing

- Use `sqflite_common_ffi` with an in-memory database for fast unit tests.
- Test every migration both upward and downward when rollback is supported.
- Test mutation guards and transaction rollback for repository methods.
- Run `dart format --output=none --set-exit-if-changed .`, `dart analyze`,
  `dart test`, `dart doc`, and `dart pub publish --dry-run` before release.

## Production checklist

- Enable SQLite foreign keys for every opened connection if the selected
  database factory does not do so automatically.
- Configure busy timeouts or WAL mode based on the application's concurrency
  model.
- Keep database opening, platform setup, and lifecycle ownership outside SQLite
  Loom.
- Log migration failures with version context, but never log secrets or
  sensitive row data.
- Pin a compatible package range and review changelogs before upgrades.
