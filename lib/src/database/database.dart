import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';

import 'capabilities.dart';
import 'session.dart';
import '../internal/executor.dart';
import '../internal/equality.dart';
import '../internal/sql.dart';
import '../migration/migration.dart';
import '../model/table.dart';
import '../query/change.dart';
import '../query/query.dart';

part 'observation.dart';
part 'connection.dart';
part 'lifecycle.dart';
part 'external_changes.dart';
part 'executors.dart';

final class SqliteLoom implements DbSession {
  /// Wraps an open [Database].
  SqliteLoom(
    Database database, {
    DbObserver? observer,
    DbObserverErrorHandler? onObserverError,
    Duration? slowQueryThreshold,
    Map<String, String> observerContext = const {},
  }) : _root = _RootDbExecutor(
         database,
         observer: observer,
         onObserverError: onObserverError,
         slowQueryThreshold: slowQueryThreshold,
         observerContext: observerContext,
       );

  final _RootDbExecutor _root;
  Future<void>? _closeFuture;

  /// The underlying database.
  Database get database => _root.database;

  /// Emits committed change sets recorded through this instance.
  Stream<DbChangeSet> get changes => _root.changes;

  /// Invalidates live queries depending on any of [tables].
  ///
  /// Use this after an integration writes through the raw database handle or
  /// another abstraction that SQLite Loom cannot observe directly.
  void invalidate(Iterable<DbTableId> tables) {
    _root.publishRaw(tables.toSet());
  }

  /// Polls SQLite's `data_version` and invalidates [tables] after writes made
  /// by other connections.
  ///
  /// Writes made through this instance already invalidate synchronously. Close
  /// the returned monitor with the owning application lifecycle.
  Future<DbExternalChangeMonitor> monitorExternalChanges({
    required Iterable<DbTableId> tables,
    Duration interval = const Duration(seconds: 1),
    DbExternalChangeErrorHandler? onError,
  }) async {
    final dependencies = tables.toSet();
    if (dependencies.isEmpty) {
      throw ArgumentError.value(tables, 'tables', 'Cannot be empty');
    }
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'Must be positive');
    }
    final monitor = DbExternalChangeMonitor._(
      this,
      Set.unmodifiable(dependencies),
      interval,
      onError,
    );
    await monitor._initialize();
    return monitor;
  }

  /// Detects features provided by the active SQLite runtime.
  Future<DbCapabilities> capabilities() => _root.capabilities();

  /// Applies common SQLite connection settings.
  Future<void> configure({
    bool? foreignKeys,
    bool? writeAheadLogging,
    Duration? busyTimeout,
    DbSynchronous? synchronous,
  }) async {
    await configureSqliteLoomConnection(
      _root.database,
      foreignKeys: foreignKeys ?? true,
      writeAheadLogging: writeAheadLogging,
      busyTimeout: busyTimeout,
      synchronous: synchronous,
    );
  }

  /// Runs SQLite's integrity checker and returns every diagnostic line.
  Future<List<String>> integrityCheck({bool quick = false}) async {
    final rows = await _root.rawQuery(
      'PRAGMA ${quick ? 'quick_check' : 'integrity_check'}',
    );
    return rows
        .expand((row) => row.values)
        .cast<String>()
        .toList(growable: false);
  }

  /// Rebuilds the database file to reclaim unused pages.
  Future<void> vacuum() => _root.execute('VACUUM');

  /// Lets SQLite update planner statistics opportunistically.
  Future<void> optimize() => _root.execute('PRAGMA optimize');

  /// Creates a consistent SQLite backup using `VACUUM INTO`.
  Future<void> backupTo(String path) async {
    if (path.isEmpty) {
      throw ArgumentError.value(path, 'path', 'Cannot be empty');
    }
    (await capabilities()).require(DbFeature.vacuumInto);
    await _root.execute('VACUUM INTO ?', [path]);
  }

  /// Executes a parameterized raw read.
  @override
  Future<List<Map<String, Object?>>> rawRead(
    String sql, {
    List<Object?> arguments = const [],
  }) {
    return _root.rawQuery(sql, arguments);
  }

  /// Watches a raw read and reloads it when one of [dependsOn] changes.
  @override
  Stream<List<Map<String, Object?>>> watchRaw(
    String sql, {
    List<Object?> arguments = const [],
    required Set<DbTableId> dependsOn,
  }) {
    if (dependsOn.isEmpty) {
      throw ArgumentError.value(dependsOn, 'dependsOn', 'Cannot be empty');
    }
    final boundArguments = List<Object?>.unmodifiable(arguments);
    return DbLiveQuery<List<Map<String, Object?>>>(
      changes: changes,
      dependencies: dependsOn,
      load: () => rawRead(sql, arguments: boundArguments),
      equals: dbValueEquals,
    ).stream;
  }

  /// Creates an immutable query for [table].
  @override
  DbTableQuery<Row, Key> table<Row, Key>(DbTable<Row, Key> table) {
    return DbTableQuery<Row, Key>.internal(_root, table);
  }

  /// Runs [action] atomically and publishes its changes after commit.
  Future<T> transaction<T>(
    Future<T> Function(SqliteLoomTransaction tx) action, {
    bool? exclusive,
  }) {
    return _root.transaction<T>(action, exclusive: exclusive);
  }

  /// Executes a raw write and invalidates every table in [affects].
  ///
  /// Values should be passed through [arguments], not interpolated into [sql].
  Future<void> rawWrite(
    String sql, {
    List<Object?> arguments = const [],
    required Set<DbTableId> affects,
  }) async {
    await _root.execute(sql, arguments);
    _root.publishRaw(affects);
  }

  /// Disposes change streams and closes the underlying database.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    await _root.dispose();
    await _root.database.close();
  }
}

/// The database view passed to a [SqliteLoom.transaction] callback.
///
/// Live queries cannot be created from this view.
final class SqliteLoomTransaction implements DbSession {
  SqliteLoomTransaction._(this._executor);

  final _TxDbExecutor _executor;
  static int _nextSavepoint = 0;

  /// Creates a typed query that executes within this transaction.
  @override
  DbTableQuery<Row, Key> table<Row, Key>(DbTable<Row, Key> table) {
    return DbTableQuery<Row, Key>.internal(_executor, table);
  }

  /// Executes a parameterized raw read within this transaction.
  @override
  Future<List<Map<String, Object?>>> rawRead(
    String sql, {
    List<Object?> arguments = const [],
  }) {
    return _executor.rawQuery(sql, arguments);
  }

  @override
  Stream<List<Map<String, Object?>>> watchRaw(
    String sql, {
    List<Object?> arguments = const [],
    required Set<DbTableId> dependsOn,
  }) => throw StateError(
    'Live queries cannot be created from an active transaction',
  );

  /// Executes a raw transaction write and records affected tables.
  Future<void> rawWrite(
    String sql, {
    List<Object?> arguments = const [],
    required Set<DbTableId> affects,
  }) async {
    await _executor.execute(sql, arguments);
    _executor.recordRaw(affects);
  }

  /// Runs [action] in a nested savepoint and discards its changes on rollback.
  Future<T> savepoint<T>(
    Future<T> Function(SqliteLoomTransaction tx) action,
  ) async {
    final name = 'loom_${_nextSavepoint++}';
    final sqlName = quoteIdentifier(name);
    final accumulator = DbChangeAccumulator();
    final child = _TxDbExecutor(
      owner: _executor.owner,
      transactionId: _executor.transactionId,
      transaction: _executor.transaction,
      changes: _executor.changes,
      accumulator: accumulator,
    );
    await _executor.execute('SAVEPOINT $sqlName');
    try {
      final result = await action(SqliteLoomTransaction._(child));
      await _executor.execute('RELEASE SAVEPOINT $sqlName');
      _executor.merge(accumulator);
      return result;
    } catch (_) {
      await _executor.execute('ROLLBACK TO SAVEPOINT $sqlName');
      await _executor.execute('RELEASE SAVEPOINT $sqlName');
      rethrow;
    }
  }
}

/// SQLite durability levels accepted by [SqliteLoom.configure].
enum DbSynchronous {
  off('OFF'),
  normal('NORMAL'),
  full('FULL'),
  extra('EXTRA');

  const DbSynchronous(this.sql);
  final String sql;
}
