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

`DbSchema` also supports indexes, foreign keys, adding columns, renaming tables,
and explicit SQL literals for defaults.

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

Bind all user-controlled values. Raw SQL fragments are trusted developer input.

## Migration CLI

Reuse the application migration list from a development tool:

```dart
final exitCode = await runSqliteLoomCli(
  args,
  openDatabase: () => databaseFactoryFfi.openDatabase('dev.sqlite'),
  migrations: migrations,
  allowDestructive: true,
);
```

Supported commands are `migrate`, `status`, `rollback`, `reset`, `refresh`, and
`fresh`. Keep destructive commands out of production tooling.

## Documentation

- [Complete runnable example](example/sqlite_loom_example.dart)
- [Best practices](doc/BEST_PRACTICES.md)
- [Compact AI coding context](doc/AI_CONTEXT.md)
- [Contributing](CONTRIBUTING.md)
- API reference is generated on pub.dev for every release.

## License

SQLite Loom is available under the MIT License.
