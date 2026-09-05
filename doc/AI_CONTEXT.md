# SQLite Loom context for AI coding assistants

Before changing the repository, read the operational rules in `AGENTS.md` and the issue, label,
branch, CI, release, and stacked-PR process in `doc/DEVELOPMENT_WORKFLOW.md`.

SQLite Loom is a generator-free reactive SQLite layer for Dart and Flutter. It
wraps a caller-opened `sqflite_common` `Database`, or opens one through the
explicit `SqliteLoomDatabase` lifecycle. It never generates models or infers schema.

## Canonical decisions

- Import only `package:sqlite_loom/sqlite_loom.dart`.
- Define one immutable model and one `DbTable<Model, Key>` per SQL table.
- Declare columns as `static final` fields so queries and row mapping reuse the
  same typed column objects.
- Run `SqliteLoomMigrator` before constructing repositories that query tables.
- Prefer the project CLI for migrations: `init`, then `make:migration` with
  `--create` or `--table`. Migrations receive a transaction-bound
  `DbMigrationContext`; use `migration.schema` and its raw/data helpers. There
  is no migration-plan DSL or global database executor.
- Prefer `sqliteLoomProject.database(...)` for application lifecycle ownership.
  Await `.ready` once during bootstrap, inject the returned `SqliteLoom`, and use
  `.raw` only for integrations that require the underlying sqflite database.
  Migration history is the schema version; do not add sqflite `onUpgrade` logic.
- Consume the generated `sqliteLoomProject`; do not maintain migration lists or
  checksum wrappers in application code. Drafts are editable until
  `migrate:finalize`. Do not edit finalized history; create a new migration.
- Define application table extensions on `DbSession` to reuse them in transactions.
- Keep query objects immutable. Chain `where`, `orderBy`, `limit`, and `offset`.
- Prefer `DbValues.fromAssignments([column.set(value)])` for statically checked writes.
  The `DbValues` map constructor remains available for encoded writes. Use `DbValues.raw` only at a deliberate
  raw-SQL boundary.
- Read ordering/limit/offset are rejected on updates and deletes.
- Never call an unfiltered `update` or `delete`. SQLite Loom rejects it. Add a
  predicate or call `allRows()` to make whole-table intent explicit.
- Use `SqliteLoom.transaction` for related writes. Query watches are forbidden
  inside transactions; changes emit once after a successful commit.
- For `rawWrite`, list every affected `DbTableId` so live queries refresh.
- Close stream subscriptions before calling `SqliteLoom.close()`.

## Minimal table pattern

```dart
final class UsersTable extends DbTable<User, int> {
  const UsersTable();

  static final id = integer('id');
  static final name = text('name');

  @override
  String get tableName => 'users';

  @override
  DbColumn<int> get primaryKey => id;

  @override
  Iterable<AnyDbColumn> get columns => [id, name];

  @override
  User decode(DbRow row) => User(id: row.get(id), name: row.get(name));

  @override
  DbValues encode(User row) => DbValues({id: row.id, name: row.name});

  @override
  int keyOf(User row) => row.id;
}
```

## Common tasks

```dart
final users = db.table(const UsersTable());

final active = await users
    .where(UsersTable.active.equals(true))
    .orderBy(UsersTable.name.ascending())
    .get();

final user = await users.find(42);
final count = await users.where(UsersTable.active.equals(true)).count();

await users.whereKey(42).update(DbValues({UsersTable.name: 'Ada'}));
await users.whereKey(42).delete();

final stream = users
    .where(UsersTable.active.equals(true))
    .watch();
```

## Constraints to preserve

- Column and table names are quoted, but custom predicate SQL and raw SQL remain
  trusted developer input. Bind user values through typed predicates.
- `upsert`/`upsertAll` use native SQLite `ON CONFLICT ... DO UPDATE`, defaulting
  to the primary key. `save` retains `INSERT OR REPLACE` compatibility semantics.
- Prefer `pluck(column)` for one value or `select([column1, column2, ...])` for a
  partial row, and `upsertAll` or `insertAll` for bulk writes.
- Live query invalidation is process-local. Writes performed directly on the
  underlying database must go through `rawWrite` or otherwise arrange refresh.
- `DateTime` columns encode UTC milliseconds and decode to local time.
- The package currently targets Dart SDK 3.12 or newer.

For a runnable end-to-end program, read
`example/sqlite_loom_example.dart`. For operational recommendations, read
`doc/BEST_PRACTICES.md`; for tooling, read `doc/CLI.md`.
