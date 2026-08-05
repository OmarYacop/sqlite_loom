# SQLite Loom

A generator-free reactive SQLite layer for Dart and Flutter with typed tables,
immutable queries, explicit migrations, safe writes, transactions, and live
streams.

SQLite Loom sits on top of `sqflite_common`. Your application owns database
opening and platform configuration; SQLite Loom adds a small, predictable data
layer without build runner, annotations, or generated files.

> SQLite Loom is an early `0.1.0` release. The core behavior is tested, but the
> public API may evolve before `1.0.0`.

## Why SQLite Loom?

- **No code generation:** schema and row mapping stay in readable Dart.
- **Typed values:** columns encode, decode, filter, and sort using their Dart
  types.
- **Immutable queries:** safely compose filters, ordering, pagination, and
  terminal operations.
- **Guarded writes:** unfiltered updates and deletes fail unless `allRows()` is
  explicit.
- **Reactive reads:** watch lists, counts, existence, or the first matching row.
- **Transaction-aware changes:** invalidations emit once after commit and never
  after rollback.
- **Explicit migrations:** use the same migration list at startup and from an
  application-owned CLI.

## When to choose it

Choose SQLite Loom when you already use a `sqflite_common` database and want a
compact typed layer without generated code. Consider a code-generating ORM such
as Drift when compile-time SQL verification, joins mapped to generated result
types, or a larger ecosystem is more important than keeping the layer small.

SQLite Loom does not open databases, synchronize across devices, encrypt files,
or observe writes made outside its own API automatically.

## Install

```bash
dart pub add sqlite_loom
```

Flutter applications normally also use a compatible backend such as `sqflite`:

```bash
flutter pub add sqflite
```

```dart
import 'package:sqflite/sqflite.dart';
import 'package:sqlite_loom/sqlite_loom.dart';

final rawDatabase = await openDatabase('app.db');
final db = SqliteLoom(rawDatabase);
```

## Define a model and table

```dart
final class Todo {
  const Todo({
    required this.id,
    required this.title,
    required this.done,
  });

  final int? id;
  final String title;
  final bool done;
}

final class TodosTable extends DbTable<Todo, int> {
  const TodosTable();

  static final id = integer('id');
  static final title = text('title');
  static final done = boolean('done');

  @override
  String get tableName => 'todos';

  @override
  DbColumn<int> get primaryKey => id;

  @override
  Todo decode(DbRow row) => Todo(
        id: row.get(id),
        title: row.get(title),
        done: row.get(done),
      );

  @override
  DbValues encode(Todo row) => DbValues({
        if (row.id != null) id: row.id,
        title: row.title,
        done: row.done,
      });

  @override
  int keyOf(Todo row) => row.id!;
}

extension AppDatabase on SqliteLoom {
  DbTableQuery<Todo, int> get todos => table(const TodosTable());
}
```

Column helpers include `integer`, `real`, `text`, `boolean`, `dateTime`,
`jsonValue`, and their nullable variants. A custom `DbColumn` can use any
`DbCodec`.

## Create and migrate the schema

```dart
final migrations = [
  CallbackDbMigration(
    version: 1,
    name: 'create_todos',
    up: (database) => DbSchema(database).createTable('todos', (table) {
      table.integer('id').primaryKey(autoIncrement: true);
      table.text('title').notNull();
      table.boolean('done').notNull().defaultValue(false);
    }),
    down: (database) => DbSchema(database).dropTable('todos'),
  ),
];

await SqliteLoomMigrator(rawDatabase, migrations: migrations).migrate();
```

`DbSchema` also supports indexes, foreign keys, checks, adding/renaming/dropping
columns, views, strict and without-rowid tables, and explicit SQL literals for
defaults.

## Query

```dart
final pending = await db.todos
    .where(TodosTable.done.equals(false))
    .orderBy(TodosTable.title.ascending())
    .limit(20)
    .get();

final todo = await db.todos.find(42);
final exists = await db.todos.where(TodosTable.done.equals(false)).exists();
final count = await db.todos.where(TodosTable.done.equals(false)).count();
```

Read a single column without fetching or decoding the complete model:

```dart
final titles = await db.todos
    .orderBy(TodosTable.title.ascending())
    .pluck(TodosTable.title)
    .get();

final summaries = await db.todos
    .select([TodosTable.id, TodosTable.title])
    .get();
final firstTitle = summaries.first.get(TodosTable.title);
```

Queries also provide `sum`, `average`, `minimum`, `maximum`, and `after`/`before`
keyset cursor helpers. Text columns provide `like`, `contains`, `startsWith`,
and `endsWith` predicates.

Use `compile()` to inspect generated SQL and bound arguments without executing
it, or `explain()` to inspect SQLite's query plan and index usage.
For bounded-memory processing, use `pages()` or `keysetPages()` with a unique
cursor column.

Selections support `distinct()` and `decodeWith(...)`. Cross-table reads use
`joinFrom(...)` with explicitly qualified `DbJoinColumn` values so duplicate
column names remain unambiguous.

Predicates compose without mutating the source query:

```dart
final predicate = TodosTable.title
    .inValues(['Read docs', 'Ship release'])
    .and(TodosTable.done.equals(false));

final rows = await db.todos.where(predicate).get();
```

Comparable columns add `greaterThan`, `lessThan`, inclusive variants, and
`between`. Predicates also compose with `and`, `or`, `not`, `&`, `|`, and `~`.

## Insert, update, and delete

```dart
final id = await db.todos.insert(
  const Todo(id: null, title: 'Read docs', done: false),
);

await db.todos
    .whereKey(id)
    .update(DbValues({TodosTable.done: true}));

await db.todos.whereKey(id).delete();
```

Bulk inserts and upserts use SQLite batches:

```dart
await db.todos.insertAll(newTodos);
await db.todos.upsertAll(synchronizedTodos);
```

`upsert` and `upsertAll` use SQLite `ON CONFLICT ... DO UPDATE`, defaulting to
the table primary key. Pass `conflictTarget` for another unique key. `save`
retains explicit `INSERT OR REPLACE` behavior for compatibility.
Bulk methods accept `batchSize` for bounded synchronization workloads. SQLite
`RETURNING` variants avoid follow-up reads, while `updateIfVersion` supports
optimistic concurrency and `softDelete` updates deletion timestamps.

An unfiltered mutation throws:

```dart
await db.todos.update(DbValues({TodosTable.done: true})); // StateError
```

For a deliberate whole-table write, opt in:

```dart
await db.todos.allRows().update(DbValues({TodosTable.done: false}));
```

## Watch live results

```dart
final subscription = db.todos
    .where(TodosTable.done.equals(false))
    .orderBy(TodosTable.title.ascending())
    .watch()
    .listen(renderTodos);
```

You can also use `watchCount`, `watchExists`, and `watchFirstOrNull`. Watches
emit an initial value, then rerun after relevant writes. Override
`DbTable.equals` for value-based duplicate suppression.

Queries created with `whereKey` avoid rerunning for writes whose known primary
keys do not match. Writes with unknown affected keys still invalidate them.

## Transactions

```dart
await db.transaction((tx) async {
  final todos = tx.table(const TodosTable());
  await todos.whereKey(1).update(DbValues({TodosTable.done: true}));
  await todos.whereKey(2).update(DbValues({TodosTable.done: true}));
});
```

Do not create a live query inside a transaction. Changes are collected and
published only after a successful commit.
Nested `savepoint` callbacks isolate rollback and reactive changes.

## Operations and diagnostics

Pass a `DbObserver` to `SqliteLoom` for query/write durations and result counts;
bound values are never exposed. `configure` applies foreign keys, WAL, busy
timeouts, and synchronous durability. Maintenance helpers include
`integrityCheck`, `optimize`, `vacuum`, and `backupTo`.

Migration callbacks may declare stable checksums. `DbSchema.validate` compares
the columns declared by `DbTable.columns` with the live SQLite schema.

Import `package:sqlite_loom/testing.dart` for `SqliteLoomTestHarness`. Run
`dart run benchmark/bulk_writes.dart` to measure batched writes locally.

## Raw writes

When typed utilities do not cover a statement, declare which tables it affects
so their watches refresh:

```dart
await db.rawWrite(
  'UPDATE todos SET done = ? WHERE title LIKE ?',
  arguments: [1, '%docs%'],
  affects: {const DbTableId('todos')},
);
```

Raw reads and multi-table reactive reads remain available without expanding the
typed table DSL:

```dart
final rows = await db.rawRead('SELECT title FROM todos WHERE done = ?',
    arguments: [0]);

final stream = db.watchRaw(
  'SELECT COUNT(*) AS count FROM todos',
  dependsOn: {const DbTableId('todos')},
);
```

Bind all user-controlled values. Raw SQL fragments are trusted developer input.

Runtime-dependent features such as `RETURNING`, strict tables, FTS5, column
drops, and `VACUUM INTO` are guarded. Inspect the active engine when adapting
behavior across platforms:

```dart
final capabilities = await db.capabilities();
if (capabilities.supports(DbFeature.fts5)) {
  // Install or use the FTS-backed search schema.
}
```

## Migration CLI

Initialize developer tooling in an application package:

```shell
dart pub add --dev sqflite_common_ffi
dart run sqlite_loom init
dart run sqlite_loom make:migration create_users --create users
dart run sqlite_loom make:flavor qa
dart run sqlite_loom migrate --env development
```

Generated migrations remain plain, reviewable Dart:

```dart
final class CreateUsersMigration extends DbMigration {
  const CreateUsersMigration();

  @override
  int get version => 20260801123456;

  @override
  String get name => 'create_users';

  @override
  Future<void> up(DbMigrationContext migration) async {
    await migration.schema.createTable('users', (table) {
      table.id();
      table.text('email').notNull().unique();
      table.timestamps();
    });
  }

  @override
  Future<void> down(DbMigrationContext migration) =>
      migration.schema.dropTable('users');
}
```

`DbMigrationContext` is bound to the migration transaction and provides
`schema`, `execute`, `query`, `insert`, `update`, and `delete`. Connection setup
can use `configureSqliteLoomConnection(database)`, which enables foreign keys by
default before migrations run.

For application lifecycle ownership, configure a reusable handle once:

```dart
final appDatabase = sqliteLoomProject.database(
  factoryResolver: () => databaseFactory,
  name: 'app.sqlite',
  connection: const DbConnectionOptions(
    foreignKeys: true,
    writeAheadLogging: true,
    busyTimeout: Duration(seconds: 5),
  ),
);

final db = await appDatabase.ready;
```

`ready` resolves the platform path, opens and configures the connection, runs
migrations, and returns one concurrency-safe `SqliteLoom` instance. Use
`appDatabase.loom` for typed access, `appDatabase.raw` for advanced integrations,
and `appDatabase.close()` for lifecycle shutdown. Schema version is derived from
migrations through `sqliteLoomProject.latestMigrationVersion`; do not maintain a
competing sqflite `version`/`onUpgrade` flow.

There is no migration-plan abstraction. Authored migration folders contain only
ordinary migration classes. Explicit SQLite Loom commands maintain the readable
`lib/database/migrations.dart` index and its `sqliteLoomProject` object; there
are no `.g.dart` files, checksum wrappers, file watchers, or build-runner hooks.
New migrations remain editable drafts until
`migrate:finalize` locks them for release. CI can run `migrate:validate` to
detect edits or removals from finalized history.
Consolidated development-only history is managed with
`migrate:retire <version> --into <replacement-version>` and
`migrate:unretire <version>`; retirement metadata lives in the lock rather than
application YAML or authored migrations.

Applications can also own a custom runner directly:

```dart
final exitCode = await runSqliteLoomCli(
  args,
  openDatabase: () => databaseFactoryFfi.openDatabase('dev.sqlite'),
  migrations: migrations,
  allowDestructive: true,
);
```

Commands include migration status/control, isolated rehearsals, schema dumps and
drift checks, table/schema browsing, read-only SQL and query-plan inspection,
guarded inserts/updates/deletes/truncation, transactional CSV/JSON import,
table copy, controlled write SQL, export, database integrity/optimization, and
backups. Structured
`--json` output is available for automation. `reset`, `refresh`, and `fresh`
require explicit application permission plus `--force` or interactive
confirmation, and are refused in production by default.
Scoped mutation shortcuts require JSON equality predicates or an explicit
whole-table `--all`; `--dry-run` previews affected rows before authorization.

## Documentation

Contributors can use the [internal architecture guide](doc/ARCHITECTURE.md) for
folder responsibilities and dependency direction.

- [1.0 readiness roadmap](doc/ROADMAP_1_0.md)
- [Public API and compatibility contract](doc/PUBLIC_API.md)
- [Foundation hardening audit](doc/FOUNDATION_AUDIT.md)
- [Security policy](SECURITY.md)
- [Developer CLI and migrations](doc/CLI.md)
- [Complete runnable example](example/sqlite_loom_example.dart)
- [Best practices](doc/BEST_PRACTICES.md)
- [Compact AI coding context](doc/AI_CONTEXT.md)
- [Contributing](CONTRIBUTING.md)
- API reference is generated on pub.dev for every release.

## License

SQLite Loom is available under the MIT License.
