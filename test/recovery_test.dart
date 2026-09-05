import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_loom/sqlite_loom.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

void main() {
  sqfliteFfiInit();
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('loom_recovery_'),
  );
  tearDown(() async => directory.delete(recursive: true));

  test(
    'disk capacity failure rolls back writes and invalidation, then recovers',
    () async {
      final raw = await databaseFactoryFfi.openDatabase(
        '${directory.path}/limited.sqlite',
      );
      final db = SqliteLoom(raw);
      addTearDown(db.close);
      await raw.execute(
        'CREATE TABLE payloads(id INTEGER PRIMARY KEY, data BLOB)',
      );
      final pages = (await raw.rawQuery(
        'PRAGMA page_count',
      )).single.values.single;
      await raw.rawQuery('PRAGMA max_page_count = $pages');
      final changes = <DbChangeSet>[];
      final subscription = db.changes.listen(changes.add);
      await expectLater(
        db.transaction(
          (tx) => tx.rawWrite(
            'INSERT INTO payloads VALUES (?, ?)',
            arguments: [1, Uint8List(1024 * 1024)],
            affects: {const DbTableId('payloads')},
          ),
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(
        (await db.rawRead('SELECT COUNT(*) AS n FROM payloads')).single['n'],
        0,
      );
      expect(await db.integrityCheck(), ['ok']);
      expect(changes, isEmpty);
      await raw.rawQuery('PRAGMA max_page_count = 1024');
      await db.rawWrite(
        'INSERT INTO payloads VALUES (?, ?)',
        arguments: [2, Uint8List(8192)],
        affects: {const DbTableId('payloads')},
      );
      expect(
        (await db.rawRead('SELECT COUNT(*) AS n FROM payloads')).single['n'],
        1,
      );
      await subscription.cancel();
    },
  );

  test(
    'backup opens independently with committed rows and migration history',
    () async {
      final raw = await databaseFactoryFfi.openDatabase(
        '${directory.path}/source.sqlite',
      );
      final project = SqliteLoomProject([
        CallbackDbMigration(
          version: 1,
          name: 'records',
          up: (migration) => migration.execute(
            'CREATE TABLE records(id INTEGER PRIMARY KEY, value TEXT)',
          ),
        ),
      ]);
      final db = await project.initialize(raw);
      addTearDown(db.close);
      await db.rawWrite(
        'INSERT INTO records VALUES (?, ?)',
        arguments: [1, 'backed up'],
        affects: {const DbTableId('records')},
      );
      final path = '${directory.path}/backup.sqlite';
      await db.backupTo(path);
      await db.rawWrite(
        'UPDATE records SET value = ?',
        arguments: ['later'],
        affects: {const DbTableId('records')},
      );
      final restoredRaw = await databaseFactoryFfi.openDatabase(path);
      final restored = await project.initialize(restoredRaw);
      addTearDown(restored.close);
      expect(
        (await restored.rawRead('SELECT value FROM records')).single['value'],
        'backed up',
      );
      expect(await restored.integrityCheck(), ['ok']);
      expect(
        (await SqliteLoomMigrator(
          restoredRaw,
          migrations: project.migrations,
        ).migrate()).applied,
        isEmpty,
      );
    },
  );

  test(
    'invalid database files fail without being replaced or erased',
    () async {
      final file = File('${directory.path}/corrupt.sqlite');
      final original = List<int>.generate(4096, (i) => i % 251);
      await file.writeAsBytes(original);
      final handle = const SqliteLoomProject(
        [],
      ).database(factory: databaseFactoryFfi, path: file.path);
      await expectLater(handle.ready, throwsA(isA<DatabaseException>()));
      await handle.close();
      expect(await file.readAsBytes(), original);
    },
  );
}
