/// Lightweight helpers for SQLite Loom integration tests.
library;

import 'package:sqflite_common/sqlite_api.dart';

import 'sqlite_loom.dart';

final class SqliteLoomTestHarness {
  SqliteLoomTestHarness._(this.database, this.loom);

  static Future<SqliteLoomTestHarness> open({
    required Future<Database> Function() openDatabase,
    Iterable<DbMigration> migrations = const [],
  }) async {
    final database = await openDatabase();
    try {
      if (migrations.isNotEmpty) {
        await SqliteLoomMigrator(database, migrations: migrations).migrate();
      }
      return SqliteLoomTestHarness._(database, SqliteLoom(database));
    } catch (_) {
      await database.close();
      rethrow;
    }
  }

  final Database database;
  final SqliteLoom loom;

  Future<void> close() => loom.close();
}
