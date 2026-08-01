import 'dart:async';
import 'dart:typed_data';

import 'package:sqflite_common/sqlite_api.dart';

import 'change.dart';
import 'capabilities.dart';
import 'internal/executor.dart';
import 'internal/sql.dart';
import 'query.dart';
import 'table.dart';

/// Adds typed queries, transactions, and reactive invalidation to a database.
///
/// The caller retains responsibility for opening the database and configuring
/// platform-specific SQLite behavior.
/// A completed database operation reported to [DbObserver].
final class DbObservation {
  const DbObservation({
    required this.operation,
    required this.duration,
    this.table,
    this.sql,
    this.resultCount,
    this.error,
  });

  final String operation;
  final Duration duration;
  final String? table;
  final String? sql;
  final int? resultCount;

  /// The operation error, when it failed. Bound values remain excluded.
  final Object? error;

  /// Whether the database operation completed successfully.
  bool get succeeded => error == null;
}

/// Receives timing metadata. Bound values are deliberately never included.
typedef DbObserver = void Function(DbObservation observation);

/// Receives errors thrown by [DbObserver] callbacks.
typedef DbObserverErrorHandler =
    void Function(Object error, StackTrace stackTrace);

final class SqliteLoom {
  /// Wraps an open [Database].
  SqliteLoom(
    Database database, {
    DbObserver? observer,
    DbObserverErrorHandler? onObserverError,
  }) : _root = _RootDbExecutor(
         database,
         observer: observer,
         onObserverError: onObserverError,
       );

  final _RootDbExecutor _root;
  Future<void>? _closeFuture;

  /// The underlying database.
  Database get database => _root.database;

  /// Emits committed change sets recorded through this instance.
  Stream<DbChangeSet> get changes => _root.changes;

  /// Detects features provided by the active SQLite runtime.
  Future<DbCapabilities> capabilities() => _root.capabilities();

  /// Applies common SQLite connection settings.
  Future<void> configure({
    bool? foreignKeys,
    bool? writeAheadLogging,
    Duration? busyTimeout,
    DbSynchronous? synchronous,
  }) async {
    if (foreignKeys != null) {
      await _root.execute(
        'PRAGMA foreign_keys = ${foreignKeys ? 'ON' : 'OFF'}',
      );
    }
    if (writeAheadLogging != null) {
      await _root.rawQuery(
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
      await _root.execute(
        'PRAGMA busy_timeout = ${busyTimeout.inMilliseconds}',
      );
    }
    if (synchronous != null) {
      await _root.execute('PRAGMA synchronous = ${synchronous.sql}');
    }
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
  Future<List<Map<String, Object?>>> rawRead(
    String sql, {
    List<Object?> arguments = const [],
  }) {
    return _root.rawQuery(sql, arguments);
  }

  /// Watches a raw read and reloads it when one of [dependsOn] changes.
  Stream<List<Map<String, Object?>>> watchRaw(
    String sql, {
    List<Object?> arguments = const [],
    required Set<DbTableId> dependsOn,
  }) {
    if (dependsOn.isEmpty) {
      throw ArgumentError.value(dependsOn, 'dependsOn', 'Cannot be empty');
    }
    return DbLiveQuery<List<Map<String, Object?>>>(
      changes: changes,
      dependencies: dependsOn,
      load: () => rawRead(sql, arguments: arguments),
      equals: _rawRowsEqual,
    ).stream;
  }

  /// Creates an immutable query for [table].
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
final class SqliteLoomTransaction {
  SqliteLoomTransaction._(this._executor);

  final _TxDbExecutor _executor;
  static int _nextSavepoint = 0;

  /// Creates a typed query that executes within this transaction.
  DbTableQuery<Row, Key> table<Row, Key>(DbTable<Row, Key> table) {
    return DbTableQuery<Row, Key>.internal(_executor, table);
  }

  /// Executes a parameterized raw read within this transaction.
  Future<List<Map<String, Object?>>> rawRead(
    String sql, {
    List<Object?> arguments = const [],
  }) {
    return _executor.rawQuery(sql, arguments);
  }

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

bool _rawRowsEqual(
  List<Map<String, Object?>> left,
  List<Map<String, Object?>> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    final leftRow = left[index];
    final rightRow = right[index];
    if (leftRow.length != rightRow.length) return false;
    for (final entry in leftRow.entries) {
      if (!rightRow.containsKey(entry.key) ||
          !_rawValueEqual(rightRow[entry.key], entry.value)) {
        return false;
      }
    }
  }
  return true;
}

bool _rawValueEqual(Object? left, Object? right) {
  if (left is Uint8List && right is Uint8List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
  return left == right;
}

final class _RootDbExecutor implements DbExecutorAdapter {
  _RootDbExecutor(
    this.database, {
    DbObserver? observer,
    DbObserverErrorHandler? onObserverError,
  }) : _observer = observer,
       _onObserverError = onObserverError;

  final Database database;
  final DbObserver? _observer;
  final DbObserverErrorHandler? _onObserverError;
  Future<DbCapabilities>? _capabilities;
  final StreamController<DbChangeSet> _changes =
      StreamController<DbChangeSet>.broadcast(sync: true);

  @override
  DatabaseExecutor get executor => database;

  @override
  bool get canWatch => true;

  @override
  Stream<DbChangeSet> get changes => _changes.stream;

  @override
  Future<DbCapabilities> capabilities() =>
      _capabilities ??= loadDbCapabilities(database);

  @override
  Future<List<Object?>> commitBatch(
    void Function(Batch batch) build, {
    required bool noResult,
  }) {
    return _observe('batch', () {
      final batch = database.batch();
      build(batch);
      return batch.commit(noResult: noResult);
    }, count: (results) => results.length);
  }

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) {
    return _observe(
      'delete',
      () => database.delete(table, where: where, whereArgs: whereArgs),
      table: table,
      count: (value) => value,
    );
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) {
    return _observe(
      'execute',
      () => database.execute(sql, arguments),
      sql: sql,
    );
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    return _observe(
      'insert',
      () => database.insert(
        table,
        values,
        nullColumnHack: nullColumnHack,
        conflictAlgorithm: conflictAlgorithm,
      ),
      table: table,
      count: (_) => 1,
    );
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    return _observe(
      'query',
      () => database.query(
        table,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      ),
      table: table,
      count: (rows) => rows.length,
    );
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) {
    return _observe(
      'query',
      () => database.rawQuery(sql, arguments),
      sql: sql,
      count: (rows) => rows.length,
    );
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) {
    return _observe(
      'insert',
      () => database.rawInsert(sql, arguments),
      sql: sql,
      count: (_) => 1,
    );
  }

  Future<T> transaction<T>(
    Future<T> Function(SqliteLoomTransaction tx) action, {
    bool? exclusive,
  }) async {
    final accumulator = DbChangeAccumulator();
    final result = await _observe(
      'transaction',
      () => database.transaction<T>((txn) async {
        final executor = _TxDbExecutor(
          transaction: txn,
          changes: changes,
          accumulator: accumulator,
        );
        return action(SqliteLoomTransaction._(executor));
      }, exclusive: exclusive),
    );

    if (accumulator.isNotEmpty) {
      _publish(accumulator.toChangeSet());
    }
    return result;
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    return _observe(
      'update',
      () => database.update(
        table,
        values,
        where: where,
        whereArgs: whereArgs,
        conflictAlgorithm: conflictAlgorithm,
      ),
      table: table,
      count: (value) => value,
    );
  }

  @override
  void record(DbTableId table, DbChangeKind kind, {Iterable<Object?>? keys}) {
    final accumulator = DbChangeAccumulator()..add(table, kind, keys: keys);
    _publish(accumulator.toChangeSet());
  }

  void publishRaw(Set<DbTableId> affects) {
    final accumulator = DbChangeAccumulator();
    for (final table in affects) {
      accumulator.add(table, DbChangeKind.raw);
    }
    if (accumulator.isNotEmpty) {
      _publish(accumulator.toChangeSet());
    }
  }

  Future<void> dispose() => _changes.close();

  void _publish(DbChangeSet changeSet) {
    if (!_changes.isClosed && changeSet.isNotEmpty) {
      _changes.add(changeSet);
    }
  }

  Future<T> _observe<T>(
    String operation,
    Future<T> Function() action, {
    String? table,
    String? sql,
    int Function(T value)? count,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final value = await action();
      stopwatch.stop();
      _notifyObserver(
        DbObservation(
          operation: operation,
          duration: stopwatch.elapsed,
          table: table,
          sql: sql,
          resultCount: count?.call(value),
        ),
      );
      return value;
    } catch (error) {
      stopwatch.stop();
      _notifyObserver(
        DbObservation(
          operation: operation,
          duration: stopwatch.elapsed,
          table: table,
          sql: sql,
          error: error,
        ),
      );
      rethrow;
    }
  }

  void _notifyObserver(DbObservation observation) {
    final observer = _observer;
    if (observer == null) return;
    try {
      observer(observation);
    } catch (error, stackTrace) {
      try {
        _onObserverError?.call(error, stackTrace);
      } catch (_) {
        // Diagnostics must never change database operation semantics.
      }
    }
  }
}

final class _TxDbExecutor implements DbExecutorAdapter {
  _TxDbExecutor({
    required this.transaction,
    required Stream<DbChangeSet> changes,
    required DbChangeAccumulator accumulator,
  }) : _changes = changes,
       _accumulator = accumulator;

  final Transaction transaction;
  final Stream<DbChangeSet> _changes;
  final DbChangeAccumulator _accumulator;
  Future<DbCapabilities>? _capabilities;

  @override
  DatabaseExecutor get executor => transaction;

  @override
  bool get canWatch => false;

  @override
  Stream<DbChangeSet> get changes => _changes;

  @override
  Future<DbCapabilities> capabilities() =>
      _capabilities ??= loadDbCapabilities(transaction);

  @override
  Future<List<Object?>> commitBatch(
    void Function(Batch batch) build, {
    required bool noResult,
  }) {
    final batch = transaction.batch();
    build(batch);
    return batch.commit(noResult: noResult);
  }

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) {
    return transaction.delete(table, where: where, whereArgs: whereArgs);
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) {
    return transaction.execute(sql, arguments);
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    return transaction.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    return transaction.query(
      table,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) {
    return transaction.rawQuery(sql, arguments);
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) {
    return transaction.rawInsert(sql, arguments);
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    return transaction.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  void record(DbTableId table, DbChangeKind kind, {Iterable<Object?>? keys}) {
    _accumulator.add(table, kind, keys: keys);
  }

  void recordRaw(Set<DbTableId> affects) {
    for (final table in affects) {
      _accumulator.add(table, DbChangeKind.raw);
    }
  }

  void merge(DbChangeAccumulator changes) => _accumulator.addAll(changes);
}
