import 'dart:async';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite_loom/sqlite_loom.dart';

final class Todo {
  const Todo({
    required this.id,
    required this.title,
    required this.done,
    required this.createdAt,
  });

  final int? id;
  final String title;
  final bool done;
  final DateTime createdAt;

  @override
  bool operator ==(Object other) {
    return other is Todo &&
        other.id == id &&
        other.title == title &&
        other.done == done &&
        other.createdAt == createdAt;
  }

  @override
  int get hashCode => Object.hash(id, title, done, createdAt);
}

final class TodosTable extends DbTable<Todo, int> {
  const TodosTable();

  static final id = integer('id');
  static final title = text('title');
  static final done = boolean('done');
  static final createdAt = dateTime('created_at');

  @override
  String get tableName => 'todos';

  @override
  DbColumn<int> get primaryKey => id;

  @override
  Todo decode(DbRow row) {
    return Todo(
      id: row.get(id),
      title: row.get(title),
      done: row.get(done),
      createdAt: row.get(createdAt),
    );
  }

  @override
  DbValues encode(Todo row) {
    return DbValues({
      if (row.id != null) id: row.id,
      title: row.title,
      done: row.done,
      createdAt: row.createdAt,
    });
  }

  @override
  int keyOf(Todo row) => row.id!;

  @override
  bool equals(Todo left, Todo right) => left == right;
}

extension TodoQueries on SqliteLoom {
  DbTableQuery<Todo, int> get todos => table(const TodosTable());
}

Future<void> main() async {
  sqfliteFfiInit();
  final database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);

  await SqliteLoomMigrator(
    database,
    migrations: [
      CallbackDbMigration(
        version: 1,
        name: 'create_todos',
        up: (db) => DbSchema(db).createTable('todos', (table) {
          table.integer('id').primaryKey(autoIncrement: true);
          table.text('title').notNull();
          table.boolean('done').notNull().defaultValue(false);
          table.dateTime('created_at').notNull();
        }),
        down: (db) => DbSchema(db).dropTable('todos'),
      ),
    ],
  ).migrate();

  final loom = SqliteLoom(database);
  final firstEmission = Completer<List<Todo>>();
  final subscription = loom.todos
      .orderBy(TodosTable.createdAt.descending())
      .watch()
      .listen((rows) {
        if (!firstEmission.isCompleted) firstEmission.complete(rows);
        print('Todos: ${rows.map((todo) => todo.title).join(', ')}');
      });

  await firstEmission.future;
  final id = await loom.todos.insert(
    Todo(
      id: null,
      title: 'Read the SQLite Loom guide',
      done: false,
      createdAt: DateTime.now(),
    ),
  );
  await loom.todos.whereKey(id).update(DbValues({TodosTable.done: true}));

  await subscription.cancel();
  await loom.close();
}
