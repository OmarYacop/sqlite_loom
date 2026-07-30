import 'dart:io';

import 'package:sqlite_loom/sqlite_loom.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

void main() {
  sqfliteFfiInit();

  late Database database;

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  });

  tearDown(() async {
    await database.close();
  });

  test('migrate applies pending migrations once and reports status', () async {
    final migrator = SqliteLoomMigrator(database, migrations: testMigrations());

    final result = await migrator.migrate();
    final secondRun = await migrator.migrate();
    final status = await migrator.status();

    expect(result.applied.map((migration) => migration.version), [1, 2]);
    expect(secondRun.applied, isEmpty);
    expect(status, hasLength(2));
    expect(status.every((entry) => entry.isApplied), isTrue);
    expect(await _tableExists(database, 'users'), isTrue);
    expect(await _tableExists(database, 'posts'), isTrue);
  });

  test('rollback reverses the latest batch only', () async {
    final migrator = SqliteLoomMigrator(database, migrations: testMigrations());
    await migrator.migrate(through: 1);
    await migrator.migrate();

    final rollback = await migrator.rollback();
    final status = await migrator.status();

    expect(rollback.rolledBack.map((migration) => migration.version), [2]);
    expect(await _tableExists(database, 'users'), isTrue);
    expect(await _tableExists(database, 'posts'), isFalse);
    expect(status.singleWhere((entry) => entry.version == 1).isApplied, isTrue);
    expect(
      status.singleWhere((entry) => entry.version == 2).isApplied,
      isFalse,
    );
  });

  test('fresh is guarded and rebuilds from migrations when allowed', () async {
    final migrator = SqliteLoomMigrator(database, migrations: testMigrations());
    await migrator.migrate();
    await database.execute('CREATE TABLE "temporary_data" ("id" INTEGER)');

    expect(() => migrator.fresh(), throwsA(isA<StateError>()));

    final result = await migrator.fresh(allowDestructive: true);

    expect(
      result.droppedTables,
      containsAll(['users', 'posts', 'temporary_data']),
    );
    expect(result.migration.applied.map((migration) => migration.version), [
      1,
      2,
    ]);
    expect(await _tableExists(database, 'users'), isTrue);
    expect(await _tableExists(database, 'posts'), isTrue);
    expect(await _tableExists(database, 'temporary_data'), isFalse);
  });

  test(
    'applied migrations missing from code are reported and block migrate',
    () async {
      await SqliteLoomMigrator(
        database,
        migrations: testMigrations(),
      ).migrate();
      final migrator = SqliteLoomMigrator(
        database,
        migrations: [testMigrations().last],
      );

      final status = await migrator.status();

      expect(
        status.singleWhere((entry) => entry.version == 1).isMissing,
        isTrue,
      );
      await expectLater(migrator.migrate(), throwsA(isA<StateError>()));
    },
  );

  test(
    'runSqliteLoomCli executes app-owned commands against a database path',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sqlite_loom_cli_test_',
      );
      final path = '${directory.path}/cli.sqlite';
      final lines = <String>[];

      Future<Database> openDatabase() {
        return databaseFactoryFfi.openDatabase(path);
      }

      try {
        final migrateCode = await runSqliteLoomCli(
          ['migrate'],
          openDatabase: openDatabase,
          migrations: testMigrations(),
          printLine: lines.add,
        );
        final statusCode = await runSqliteLoomCli(
          ['status'],
          openDatabase: openDatabase,
          migrations: testMigrations(),
          printLine: lines.add,
        );
        final deniedFreshCode = await runSqliteLoomCli(
          ['fresh'],
          openDatabase: openDatabase,
          migrations: testMigrations(),
          printLine: lines.add,
        );
        final freshCode = await runSqliteLoomCli(
          ['fresh'],
          openDatabase: openDatabase,
          migrations: testMigrations(),
          allowDestructive: true,
          printLine: lines.add,
        );

        expect(migrateCode, 0);
        expect(statusCode, 0);
        expect(deniedFreshCode, 73);
        expect(freshCode, 0);
        expect(lines, contains('Migrated 1 create_users'));
        expect(lines, contains('Migrated 2 create_posts'));
        expect(
          lines.any((line) => line.startsWith('Y batch=1 version=1')),
          isTrue,
        );
        expect(
          lines,
          contains('fresh is destructive. Enable allowDestructive to run it.'),
        );
        expect(lines, contains('Dropped 3 tables.'));
        expect(lines, contains('Migrated 2 migrations.'));
      } finally {
        await databaseFactoryFfi.deleteDatabase(path);
        await directory.delete(recursive: true);
      }
    },
  );
}

List<DbMigration> testMigrations() {
  return [
    CallbackDbMigration(
      version: 1,
      name: 'create_users',
      up: (db) {
        return DbSchema(db).createTable('users', (table) {
          table.integer('id').primaryKey(autoIncrement: true);
          table.text('name').notNull();
          table.text('email').notNull().unique();
          table.boolean('active').notNull().defaultValue(true);
          table.dateTime('created_at').notNull();
        });
      },
      down: (db) => DbSchema(db).dropTable('users'),
    ),
    CallbackDbMigration(
      version: 2,
      name: 'create_posts',
      up: (db) async {
        final schema = DbSchema(db);
        await schema.createTable('posts', (table) {
          table.integer('id').primaryKey(autoIncrement: true);
          table
              .integer('user_id')
              .notNull()
              .references('users', 'id', onDelete: 'cascade');
          table.text('title').notNull();
          table.text('body').nullable();
          table.dateTime('created_at').notNull();
        });
        await schema.createIndex('posts_user_id_index', 'posts', ['user_id']);
      },
      down: (db) async {
        final schema = DbSchema(db);
        await schema.dropIndex('posts_user_id_index');
        await schema.dropTable('posts');
      },
    ),
  ];
}

Future<bool> _tableExists(Database database, String tableName) async {
  final rows = await database.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
    [tableName],
  );
  return rows.isNotEmpty;
}
