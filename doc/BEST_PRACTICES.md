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

## Tables and values

- Keep models immutable and implement value equality, or override
  `DbTable.equals`. Live queries use it to suppress duplicate emissions.
- Match nullable Dart columns to nullable SQL definitions.
- Omit an auto-increment key from `DbValues` until SQLite assigns it.
- Centralize each table instance behind a database extension or repository.
- Prefer typed column predicates to hand-written SQL.

## Queries and writes

- Add deterministic ordering before using `limit` or `offset`.
- Keep pagination queries short-lived; use keyset pagination for large tables.
- Use a transaction for multi-step invariants.
- Remember that `allRows()` is an explicit safety escape hatch, not a default.
- Include all affected tables when using `rawWrite`, including tables changed by
  triggers when their live queries must refresh.

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
