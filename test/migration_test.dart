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

  test(
    'project database owns concurrent readiness and connection lifecycle',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sqlite_loom_database_',
      );
      final path = '${directory.path}/app.sqlite';
      final project = SqliteLoomProject(testMigrations());
      final appDatabase = project.database(
        factory: databaseFactoryFfi,
        path: path,
        connection: const DbConnectionOptions(
          busyTimeout: Duration(seconds: 1),
        ),
      );
      addTearDown(() async {
        if (appDatabase.isOpen) await appDatabase.close();
        await databaseFactoryFfi.deleteDatabase(path);
        await directory.delete(recursive: true);
      });

      final first = appDatabase.ready;
      final second = appDatabase.ready;
      final instances = await Future.wait([first, second]);

      expect(identical(instances.first, instances.last), isTrue);
      expect(identical(appDatabase.loom, instances.first), isTrue);
      expect(identical(appDatabase.raw, instances.first.database), isTrue);
      expect(project.latestMigrationVersion, 2);
      expect(await _tableExists(appDatabase.raw, 'users'), isTrue);
      final foreignKeys = await appDatabase.raw.rawQuery('PRAGMA foreign_keys');
      expect(foreignKeys.single.values.single, 1);

      await appDatabase.close();
      expect(appDatabase.isOpen, isFalse);
      expect(() => appDatabase.loom, throwsStateError);
      expect(() => appDatabase.ready, throwsStateError);
    },
  );

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
    'retired migrations accept history but never run on fresh databases',
    () async {
      final historical = CallbackDbMigration(
        version: 5,
        name: 'historical_feature',
        up: (migration) => migration.execute(
          'CREATE TABLE historical_feature (id INTEGER PRIMARY KEY)',
        ),
      );
      await SqliteLoomMigrator(database, migrations: [historical]).migrate();

      final migrator = SqliteLoomMigrator(
        database,
        migrations: const [],
        retiredVersions: const {5},
      );
      expect((await migrator.migrate()).applied, isEmpty);
      final existing = (await migrator.status()).single;
      expect(existing.isRetired, isTrue);
      expect(existing.isMissing, isFalse);
      expect(existing.isApplied, isTrue);

      final rebuilt = await migrator.fresh(allowDestructive: true);
      expect(rebuilt.migration.applied, isEmpty);
      final fresh = (await migrator.status()).single;
      expect(fresh.isRetired, isTrue);
      expect(fresh.isApplied, isFalse);
    },
  );

  test('migration checksums detect edited released migrations', () async {
    final original = CallbackDbMigration(
      version: 1,
      name: 'create_checked',
      checksum: 'v1-original',
      up: (db) => db.execute('CREATE TABLE checked (id INTEGER)'),
    );
    await SqliteLoomMigrator(database, migrations: [original]).migrate();
    final changed = CallbackDbMigration(
      version: 1,
      name: 'create_checked',
      checksum: 'v1-edited',
      up: (_) {},
    );

    await expectLater(
      SqliteLoomMigrator(database, migrations: [changed]).migrate(),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'unchecked migrations accept history from checksum-enabled releases',
    () async {
      final original = CallbackDbMigration(
        version: 1,
        name: 'create_checked',
        checksum: 'v1-original',
        up: (db) => db.execute('CREATE TABLE checked (id INTEGER)'),
      );
      await SqliteLoomMigrator(database, migrations: [original]).migrate();
      final checksumRemoved = CallbackDbMigration(
        version: 1,
        name: 'create_checked',
        up: (_) {},
      );

      final result = await SqliteLoomMigrator(
        database,
        migrations: [checksumRemoved],
      ).migrate();
      expect(result.applied, isEmpty);
    },
  );

  test('failed migration rolls back schema and migration history', () async {
    final migration = CallbackDbMigration(
      version: 1,
      name: 'fail_after_schema_change',
      checksum: 'failure-fixture-v1',
      up: (db) async {
        await db.execute('CREATE TABLE should_rollback (id INTEGER)');
        throw StateError('injected migration failure');
      },
    );

    await expectLater(
      SqliteLoomMigrator(database, migrations: [migration]).migrate(),
      throwsA(isA<StateError>()),
    );

    expect(await _tableExists(database, 'should_rollback'), isFalse);
    expect(await _tableExists(database, 'sqlite_loom_migrations'), isFalse);
  });

  test('concurrent migrators serialize and apply each version once', () async {
    final first = SqliteLoomMigrator(database, migrations: testMigrations());
    final second = SqliteLoomMigrator(database, migrations: testMigrations());

    final results = await Future.wait([first.migrate(), second.migrate()]);
    final appliedCounts =
        results.map((result) => result.applied.length).toList()..sort();

    expect(appliedCounts, [0, 2]);
    final history = await database.query('_sqlite_loom_migrations');
    expect(history, hasLength(2));
  });

  test('separate connections cannot apply a migration twice', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sqlite_loom_migration_race_',
    );
    final path = '${directory.path}/race.sqlite';
    final firstDatabase = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    final secondDatabase = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await firstDatabase.execute('PRAGMA busy_timeout = 100');
    await secondDatabase.execute('PRAGMA busy_timeout = 100');
    final migrations = [
      CallbackDbMigration(
        version: 1,
        name: 'create_race_table',
        checksum: 'race-v1',
        up: (db) => db.execute('CREATE TABLE race_table (id INTEGER)'),
      ),
    ];

    try {
      final results = await Future.wait([
        SqliteLoomMigrator(firstDatabase, migrations: migrations).migrate(),
        SqliteLoomMigrator(secondDatabase, migrations: migrations).migrate(),
      ]);
      final counts = results.map((result) => result.applied.length).toList()
        ..sort();
      expect(counts, [0, 1]);
      expect(
        await firstDatabase.query('_sqlite_loom_migrations'),
        hasLength(1),
      );
    } finally {
      await firstDatabase.close();
      await secondDatabase.close();
      await databaseFactoryFfi.deleteDatabase(path);
      await directory.delete(recursive: true);
    }
  });

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
          ['fresh', '--force'],
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
          contains('Error: fresh is disabled by the application runner.'),
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
      up: (migration) {
        return migration.schema.createTable('users', (table) {
          table.integer('id').primaryKey(autoIncrement: true);
          table.text('name').notNull();
          table.text('email').notNull().unique();
          table.boolean('active').notNull().defaultValue(true);
          table.dateTime('created_at').notNull();
        });
      },
      down: (migration) => migration.schema.dropTable('users'),
    ),
    CallbackDbMigration(
      version: 2,
      name: 'create_posts',
      up: (migration) async {
        final schema = migration.schema;
        await schema.createTable('posts', (table) {
          table.integer('id').primaryKey(autoIncrement: true);
          table
              .integer('user_id')
              .notNull()
              .references('users', column: 'id', onDelete: 'cascade');
          table.text('title').notNull();
          table.text('body').nullable();
          table.dateTime('created_at').notNull();
        });
        await schema.createIndex('posts_user_id_index', 'posts', ['user_id']);
      },
      down: (migration) async {
        final schema = migration.schema;
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
