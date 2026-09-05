part of 'database.dart';

/// Resolves an application database file path.
typedef DbPathResolver = FutureOr<String> Function();

/// Resolves the active platform database factory lazily.
typedef DbFactoryResolver = DatabaseFactory Function();

/// Connection policy applied before migrations run.
final class DbConnectionOptions {
  const DbConnectionOptions({
    this.foreignKeys = true,
    this.writeAheadLogging,
    this.busyTimeout,
    this.synchronous,
  });

  final bool foreignKeys;
  final bool? writeAheadLogging;
  final Duration? busyTimeout;
  final DbSynchronous? synchronous;
}

/// Applies SQLite Loom's common settings to an open connection.
///
/// Call this immediately after opening a database and before starting a
/// transaction or running migrations.
Future<void> configureSqliteLoomConnection(
  DatabaseExecutor database, {
  bool foreignKeys = true,
  bool? writeAheadLogging,
  Duration? busyTimeout,
  DbSynchronous? synchronous,
}) async {
  await database.rawQuery(
    'PRAGMA foreign_keys = ${foreignKeys ? 'ON' : 'OFF'}',
  );
  if (writeAheadLogging != null) {
    await database.rawQuery(
      'PRAGMA journal_mode = ${writeAheadLogging ? 'WAL' : 'DELETE'}',
    );
  }
  if (busyTimeout != null) {
    if (busyTimeout.isNegative) {
      throw ArgumentError.value(
        busyTimeout,
        'busyTimeout',
        'Cannot be negative',
      );
    }
    await database.rawQuery(
      'PRAGMA busy_timeout = ${busyTimeout.inMilliseconds}',
    );
  }
  if (synchronous != null) {
    await database.rawQuery('PRAGMA synchronous = ${synchronous.sql}');
  }
}
