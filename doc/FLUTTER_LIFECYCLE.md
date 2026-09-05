# Flutter bootstrap and shutdown

Run `dart run sqlite_loom init` and create/finalize the application's migrations
with the CLI. Import its `lib/database/migrations.dart` index. Use the `Todo` and
`TodosTable` mappings (without the example main or FFI imports) from `example/sqlite_loom_example.dart` as a starting point
for `lib/database/todos.dart`; its migration creates all four mapped columns.

This root widget owns one subscription and closes it before closing the handle.
Repositories receive the ready database instead of opening their own connections.
Do not add a second sqflite `version`/`onUpgrade` migration flow.

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqlite_loom/sqlite_loom.dart';
import 'database/migrations.dart';
import 'database/todos.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final handle = sqliteLoomProject.database(
    factoryResolver: () => databaseFactory,
    name: 'todos.sqlite',
    connection: const DbConnectionOptions(
      foreignKeys: true,
      busyTimeout: Duration(seconds: 5),
    ),
  );
  try {
    final db = await handle.ready;
    runApp(TodoApp(db: db, closeDatabase: handle.close));
  } catch (_) {
    await handle.close();
    runApp(const MaterialApp(home: Scaffold(
      body: Center(child: Text('Unable to open the local database.')),
    )));
  }
}

class TodoApp extends StatefulWidget {
  const TodoApp({super.key, required this.db, required this.closeDatabase});
  final SqliteLoom db;
  final Future<void> Function() closeDatabase;
  @override
  State<TodoApp> createState() => _TodoAppState();
}

class _TodoAppState extends State<TodoApp> {
  late final StreamSubscription<List<Todo>> _subscription;
  List<Todo> _todos = const [];
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.db.table(const TodosTable())
        .orderBy(TodosTable.id.ascending()).watch().listen((rows) {
      if (mounted) setState(() { _todos = rows; _failed = false; });
    }, onError: (Object error, StackTrace stack) {
      if (mounted) setState(() => _failed = true);
    });
  }

  Future<void> _shutdown(Future<void> Function() closeDatabase) async {
    try {
      await _subscription.cancel();
      await closeDatabase();
    } catch (error, stack) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: error, stack: stack, context: ErrorDescription('closing local storage'),
      ));
    }
  }

  @override
  void dispose() {
    unawaited(_shutdown(widget.closeDatabase));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(home: Scaffold(
    body: _failed
        ? const Center(child: Text('Unable to load todos.'))
        : ListView(children: [for (final todo in _todos) ListTile(title: Text(todo.title))]),
  ));
}
```

Widget disposal cannot be awaited. An application with an explicit shutdown or
account-switch coordinator should await subscription cancellation and handle
closure there. Mobile process termination may bypass disposal entirely; committed
transaction durability must not depend on a shutdown callback. Do not close the
shared database on every background/lifecycle pause.
