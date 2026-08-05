import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite_loom/sqlite_loom.dart';
import 'package:test/test.dart';

void main() {
  sqfliteFfiInit();

  test('sandbox migrates and cleans an isolated database', () async {
    final directory = Directory.systemTemp.createTempSync('loom_sandbox_');
    final mainPath = '${directory.path}/main.sqlite';
    var cleaned = false;
    final lines = <String>[];
    try {
      final code = await runSqliteLoomCli(
        ['sandbox', '--json'],
        openDatabase: () => databaseFactoryFfi.openDatabase(
          mainPath,
          options: OpenDatabaseOptions(singleInstance: false),
        ),
        migrations: const [_CreateWidgets()],
        openSandbox: () async {
          final database = await databaseFactoryFfi.openDatabase(
            '${directory.path}/sandbox.sqlite',
            options: OpenDatabaseOptions(singleInstance: false),
          );
          return SqliteLoomSandbox(
            database: database,
            cleanup: () => cleaned = true,
          );
        },
        printLine: lines.add,
      );
      expect(code, 0);
      expect(cleaned, isTrue);
      final result = jsonDecode(lines.single) as Map<String, Object?>;
      expect(result['success'], isTrue);
      expect(File(mainPath).existsSync(), isFalse);
    } finally {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  });

  test('schema:diff reports drift against a clean migration run', () async {
    final directory = Directory.systemTemp.createTempSync('loom_diff_');
    final mainPath = '${directory.path}/main.sqlite';
    final sandboxPath = '${directory.path}/sandbox.sqlite';
    var prepared = false;
    final lines = <String>[];
    try {
      final code = await runSqliteLoomCli(
        ['schema:diff', '--json'],
        openDatabase: () async {
          final database = await databaseFactoryFfi.openDatabase(
            mainPath,
            options: OpenDatabaseOptions(singleInstance: false),
          );
          if (!prepared) {
            await database.execute(
              'CREATE TABLE unexpected (id INTEGER PRIMARY KEY)',
            );
            prepared = true;
          }
          return database;
        },
        migrations: const [_CreateWidgets()],
        openSandbox: () async => SqliteLoomSandbox(
          database: await databaseFactoryFfi.openDatabase(
            sandboxPath,
            options: OpenDatabaseOptions(singleInstance: false),
          ),
          cleanup: () async {},
        ),
        printLine: lines.add,
      );
      expect(code, 1, reason: lines.join('\n'));
      final result = jsonDecode(lines.single) as Map<String, dynamic>;
      expect(result['matches'], isFalse);
      expect(result['added'], contains('table:widgets'));
      expect(result['removed'], contains('table:unexpected'));
    } finally {
      await databaseFactoryFfi.deleteDatabase(mainPath);
      await databaseFactoryFfi.deleteDatabase(sandboxPath);
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  });

  test(
    'production destructive commands stay refused even with force',
    () async {
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      final lines = <String>[];
      final code = await runSqliteLoomCli(
        ['fresh', '--force', '--json'],
        openDatabase: () async => database,
        migrations: const [_CreateWidgets()],
        environment: 'production',
        allowDestructive: true,
        printLine: lines.add,
      );
      expect(code, 73);
      final result = jsonDecode(lines.single) as Map<String, Object?>;
      expect(result['success'], isFalse);
    },
  );

  test('restore is application-owned and does not open the database', () async {
    var opened = false;
    String? restoredFrom;
    final lines = <String>[];
    final code = await runSqliteLoomCli(
      ['db:restore', '--input', 'backup.sqlite', '--force', '--json'],
      openDatabase: () async {
        opened = true;
        return databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      },
      migrations: const <DbMigration>[],
      allowDestructive: true,
      restoreDatabase: (input) => restoredFrom = input,
      printLine: lines.add,
    );
    expect(code, 0);
    expect(opened, isFalse);
    expect(restoredFrom, 'backup.sqlite');
    final result = jsonDecode(lines.single) as Map<String, Object?>;
    expect(result['success'], isTrue);
  });

  test('database overlook commands inspect and browse schema safely', () async {
    final directory = Directory.systemTemp.createTempSync('loom_overlook_');
    final path = '${directory.path}/database.sqlite';
    final database = await databaseFactoryFfi.openDatabase(path);
    await database.execute('''
      CREATE TABLE widgets (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        payload BLOB
      ) STRICT
    ''');
    await database.execute('CREATE UNIQUE INDEX widgets_name ON widgets(name)');
    await database.insert('widgets', {
      'id': 1,
      'name': 'alpha',
      'payload': Uint8List.fromList([0, 1, 2]),
    });
    await database.close();

    Future<Map<String, dynamic>> run(List<String> arguments) async {
      final lines = <String>[];
      final code = await runSqliteLoomCli(
        [...arguments, '--json'],
        openDatabase: () => databaseFactoryFfi.openDatabase(path),
        migrations: const [],
        printLine: lines.add,
      );
      expect(code, 0, reason: lines.join('\n'));
      return jsonDecode(lines.single) as Map<String, dynamic>;
    }

    try {
      final tables = await run(['db:tables']);
      expect(tables['rowCount'], 1);
      expect((tables['rows'] as List).single, containsPair('name', 'widgets'));

      final description = await run(['db:describe', 'widgets']);
      expect(description['strict'], isTrue);
      expect(description['columns'], hasLength(3));
      expect(description['indexes'], hasLength(1));

      final browse = await run([
        'db:browse',
        'widgets',
        '--order',
        'name',
        '--desc',
      ]);
      expect(browse['rowCount'], 1);
      final row = (browse['rows'] as List).single as Map<String, dynamic>;
      expect(row['payload'], {'base64': 'AAEC'});
    } finally {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  });

  test('read-only query and explain reject mutation attempts', () async {
    final directory = Directory.systemTemp.createTempSync('loom_query_');
    final path = '${directory.path}/database.sqlite';
    final database = await databaseFactoryFfi.openDatabase(path);
    await database.execute('CREATE TABLE widgets (id INTEGER PRIMARY KEY)');
    await database.close();

    final queryLines = <String>[];
    expect(
      await runSqliteLoomCli(
        [
          'db:query',
          '--sql',
          'WITH value(id) AS (VALUES (7)) SELECT id FROM value',
          '--json',
        ],
        openDatabase: () => databaseFactoryFfi.openDatabase(path),
        migrations: const [],
        printLine: queryLines.add,
      ),
      0,
    );
    final query = jsonDecode(queryLines.single) as Map<String, dynamic>;
    expect(query['rows'], [
      {'id': 7},
    ]);

    final explainLines = <String>[];
    expect(
      await runSqliteLoomCli(
        ['db:explain', '--sql', 'SELECT * FROM widgets', '--json'],
        openDatabase: () => databaseFactoryFfi.openDatabase(path),
        migrations: const [],
        printLine: explainLines.add,
      ),
      0,
    );
    expect(
      (jsonDecode(explainLines.single) as Map<String, dynamic>)['rows'],
      isNotEmpty,
    );

    final mutationLines = <String>[];
    expect(
      await runSqliteLoomCli(
        ['db:query', '--sql', 'DELETE FROM widgets', '--json'],
        openDatabase: () => databaseFactoryFfi.openDatabase(path),
        migrations: const [],
        printLine: mutationLines.add,
      ),
      64,
    );
    expect(
      (jsonDecode(mutationLines.single) as Map<String, dynamic>)['success'],
      isFalse,
    );
    final cteMutationLines = <String>[];
    expect(
      await runSqliteLoomCli(
        [
          'db:query',
          '--sql',
          'WITH ids AS (SELECT id FROM widgets) DELETE FROM widgets WHERE id IN ids',
          '--json',
        ],
        openDatabase: () => databaseFactoryFfi.openDatabase(path),
        migrations: const [],
        printLine: cteMutationLines.add,
      ),
      64,
    );
    final verification = await databaseFactoryFfi.openDatabase(path);
    expect(
      await verification.rawQuery('SELECT COUNT(*) AS count FROM widgets'),
      [containsPair('count', 0)],
    );
    await verification.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('database export writes valid CSV and JSON', () async {
    final directory = Directory.systemTemp.createTempSync('loom_export_');
    final path = '${directory.path}/database.sqlite';
    final database = await databaseFactoryFfi.openDatabase(path);
    await database.execute(
      'CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT)',
    );
    await database.insert('widgets', {'id': 1, 'name': 'a,"b'});
    await database.close();
    try {
      final csv = File('${directory.path}/widgets.csv');
      expect(
        await runSqliteLoomCli(
          ['db:export', 'widgets', '--output', csv.path],
          openDatabase: () => databaseFactoryFfi.openDatabase(path),
          migrations: const [],
          printLine: (_) {},
        ),
        0,
      );
      expect(csv.readAsStringSync(), 'id,name\n1,"a,""b"\n');
      final refusalLines = <String>[];
      expect(
        await runSqliteLoomCli(
          ['db:export', 'widgets', '--output', csv.path, '--json'],
          openDatabase: () => databaseFactoryFfi.openDatabase(path),
          migrations: const [],
          printLine: refusalLines.add,
        ),
        64,
      );
      expect(csv.readAsStringSync(), 'id,name\n1,"a,""b"\n');

      final json = File('${directory.path}/widgets.json');
      expect(
        await runSqliteLoomCli(
          ['db:export', 'widgets', '--output', json.path],
          openDatabase: () => databaseFactoryFfi.openDatabase(path),
          migrations: const [],
          printLine: (_) {},
        ),
        0,
      );
      expect(jsonDecode(json.readAsStringSync()), [
        {'id': 1, 'name': 'a,"b'},
      ]);
    } finally {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  });

  test(
    'insert update and delete provide guarded manipulation shortcuts',
    () async {
      final directory = Directory.systemTemp.createTempSync('loom_mutations_');
      final path = '${directory.path}/database.sqlite';
      final setup = await databaseFactoryFfi.openDatabase(path);
      await setup.execute(
        'CREATE TABLE widgets (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, active INTEGER)',
      );
      await setup.close();

      Future<(int, Map<String, dynamic>)> run(
        List<String> arguments, {
        bool allowDestructive = false,
      }) async {
        final lines = <String>[];
        final code = await runSqliteLoomCli(
          [...arguments, '--json'],
          openDatabase: () => databaseFactoryFfi.openDatabase(path),
          migrations: const [],
          allowDestructive: allowDestructive,
          printLine: lines.add,
        );
        return (code, jsonDecode(lines.single) as Map<String, dynamic>);
      }

      try {
        final additiveDenied = await run([
          'db:insert',
          'widgets',
          '--value',
          'name=denied',
        ]);
        expect(additiveDenied.$1, 73);

        final inserted = await run([
          'db:insert',
          'widgets',
          '--value',
          'name=alpha',
          '--value',
          'active=true',
        ], allowDestructive: true);
        expect(inserted.$1, 0);
        expect(inserted.$2['inserted'], 1);

        final missingScope = await run([
          'db:update',
          'widgets',
          '--set-json',
          '{"active":false}',
          '--force',
        ], allowDestructive: true);
        expect(missingScope.$1, 64);

        final preview = await run([
          'db:update',
          'widgets',
          '--set',
          'active=false',
          '--where',
          'name=alpha',
          '--dry-run',
        ]);
        expect(preview.$1, 0);
        expect(preview.$2['matched'], 1);

        final denied = await run([
          'db:update',
          'widgets',
          '--set-json',
          '{"active":false}',
          '--where-json',
          '{"name":"alpha"}',
          '--force',
        ]);
        expect(denied.$1, 73);

        final updated = await run([
          'db:update',
          'widgets',
          '--set-json',
          '{"active":false}',
          '--where-json',
          '{"name":"alpha"}',
          '--force',
        ], allowDestructive: true);
        expect(updated.$1, 0);
        expect(updated.$2['affected'], 1);

        final deleted = await run([
          'db:delete',
          'widgets',
          '--where-json',
          '{"active":false}',
          '--force',
        ], allowDestructive: true);
        expect(deleted.$1, 0);
        expect(deleted.$2['affected'], 1);
      } finally {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'truncate and execute enforce destructive and SQL safety policy',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'loom_destructive_',
      );
      final path = '${directory.path}/database.sqlite';
      final setup = await databaseFactoryFfi.openDatabase(path);
      await setup.execute(
        'CREATE TABLE widgets (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)',
      );
      await setup.insert('widgets', {'name': 'alpha'});
      await setup.close();

      Future<(int, Map<String, dynamic>)> run(List<String> arguments) async {
        final lines = <String>[];
        final code = await runSqliteLoomCli(
          [...arguments, '--json'],
          openDatabase: () => databaseFactoryFfi.openDatabase(path),
          migrations: const [],
          allowDestructive: true,
          printLine: lines.add,
        );
        return (code, jsonDecode(lines.single) as Map<String, dynamic>);
      }

      try {
        final readOnly = await run([
          'db:execute',
          '--sql',
          'SELECT * FROM widgets',
          '--force',
        ]);
        expect(readOnly.$1, 64);

        final transaction = await run([
          'db:execute',
          '--sql',
          'BEGIN',
          '--force',
        ]);
        expect(transaction.$1, 64);

        final executed = await run([
          'db:execute',
          '--sql',
          'CREATE INDEX widgets_name ON widgets(name)',
          '--force',
        ]);
        expect(executed.$1, 0);

        final truncated = await run(['db:truncate', 'widgets', '--force']);
        expect(truncated.$1, 0);
        expect(truncated.$2['affected'], 1);

        final inserted = await run([
          'db:insert',
          'widgets',
          '--values-json',
          '{"name":"after"}',
        ]);
        expect(inserted.$2['insertedId'], 1);
      } finally {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'CSV and JSON imports are atomic and table copy reports inserted rows',
    () async {
      final directory = Directory.systemTemp.createTempSync('loom_import_');
      final path = '${directory.path}/database.sqlite';
      final setup = await databaseFactoryFfi.openDatabase(path);
      await setup.execute(
        'CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT UNIQUE)',
      );
      await setup.execute(
        'CREATE TABLE destination (id INTEGER PRIMARY KEY, name TEXT UNIQUE)',
      );
      await setup.close();
      final csv = File('${directory.path}/rows.csv')
        ..writeAsStringSync('id,name\n1,"alpha, one"\n2,beta\n');
      final invalidJson = File(
        '${directory.path}/invalid.json',
      )..writeAsStringSync('[{"id":3,"name":"gamma"},{"id":4,"unknown":true}]');
      final conflictingJson = File('${directory.path}/conflicting.json')
        ..writeAsStringSync(
          '[{"id":3,"name":"gamma"},{"id":4,"name":"alpha, one"}]',
        );

      Future<(int, Map<String, dynamic>)> run(List<String> arguments) async {
        final lines = <String>[];
        final code = await runSqliteLoomCli(
          [...arguments, '--json'],
          openDatabase: () => databaseFactoryFfi.openDatabase(path),
          migrations: const [],
          allowDestructive: true,
          printLine: lines.add,
        );
        return (code, jsonDecode(lines.single) as Map<String, dynamic>);
      }

      try {
        final preview = await run([
          'db:import',
          'source',
          '--input',
          csv.path,
          '--dry-run',
        ]);
        expect(preview.$2['parsed'], 2);
        expect(preview.$2['inserted'], 0);

        final imported = await run([
          'db:import',
          'source',
          '--input',
          csv.path,
        ]);
        expect(imported.$1, 0);
        expect(imported.$2['inserted'], 2);

        final invalid = await run([
          'db:import',
          'source',
          '--input',
          invalidJson.path,
        ]);
        expect(invalid.$1, 64);

        final conflict = await run([
          'db:import',
          'source',
          '--input',
          conflictingJson.path,
        ]);
        expect(conflict.$1, 70);

        final copied = await run(['db:copy', 'source', 'destination']);
        expect(copied.$1, 0);
        expect(copied.$2['inserted'], 2);
      } finally {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      }
    },
  );
}

final class _CreateWidgets extends DbMigration {
  const _CreateWidgets();

  @override
  int get version => 1;

  @override
  String get name => 'create_widgets';

  @override
  Future<void> up(DatabaseExecutor db) =>
      db.execute('CREATE TABLE widgets (id INTEGER PRIMARY KEY)');

  @override
  Future<void> down(DatabaseExecutor db) => db.execute('DROP TABLE widgets');
}
