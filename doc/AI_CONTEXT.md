# SQLite Loom context for AI coding assistants

SQLite Loom is a generator-free reactive SQLite layer for Dart and Flutter. It
wraps a caller-owned `sqflite_common` `Database`; it does not open database
files, generate models, or infer schema.

## Canonical decisions

- Import only `package:sqlite_loom/sqlite_loom.dart`.
- Define one immutable model and one `DbTable<Model, Key>` per SQL table.
- Declare columns as `static final` fields so queries and row mapping reuse the
  same typed column objects.
- Run `SqliteLoomMigrator` before constructing repositories that query tables.
- Keep query objects immutable. Chain `where`, `orderBy`, `limit`, and `offset`.
- Use `DbValues` for encoded writes. Use `DbValues.raw` only at a deliberate
  raw-SQL boundary.
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
- `save`/`upsert` use SQLite `INSERT OR REPLACE` semantics by default. SQLite
  replacement can delete and recreate a row; choose another conflict algorithm
  if foreign keys or triggers make that inappropriate.
- Live query invalidation is process-local. Writes performed directly on the
  underlying database must go through `rawWrite` or otherwise arrange refresh.
- `DateTime` columns encode UTC milliseconds and decode to local time.
- The package currently targets Dart SDK 3.12 or newer.

For a runnable end-to-end program, read
`example/sqlite_loom_example.dart`. For operational recommendations, read
`doc/BEST_PRACTICES.md`.
