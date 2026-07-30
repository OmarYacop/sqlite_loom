import 'dart:async';

import 'package:sqflite_common/sqlite_api.dart';

import 'change.dart';
import 'internal/executor.dart';
import 'query.dart';
import 'table.dart';

/// Adds typed queries, transactions, and reactive invalidation to a database.
///
/// The caller retains responsibility for opening the database and configuring
/// platform-specific SQLite behavior.
final class SqliteLoom {
  /// Wraps an open [Database].
  SqliteLoom(Database database) : _root = _RootDbExecutor(database);

  final _RootDbExecutor _root;

  /// The underlying database.
  Database get database => _root.database;

  /// Emits committed change sets recorded through this instance.
  Stream<DbChangeSet> get changes => _root.changes;

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
  Future<void> close() {
    _root.dispose();
    return _root.database.close();
  }
}

/// The database view passed to a [SqliteLoom.transaction] callback.
///
/// Live queries cannot be created from this view.
final class SqliteLoomTransaction {
  SqliteLoomTransaction._(this._executor);

  final _TxDbExecutor _executor;

  /// Creates a typed query that executes within this transaction.
  DbTableQuery<Row, Key> table<Row, Key>(DbTable<Row, Key> table) {
    return DbTableQuery<Row, Key>.internal(_executor, table);
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
}

final class _RootDbExecutor implements DbExecutorAdapter {
  _RootDbExecutor(this.database);

  final Database database;
  final StreamController<DbChangeSet> _changes =
      StreamController<DbChangeSet>.broadcast(sync: true);

  @override
  DatabaseExecutor get executor => database;

  @override
  bool get canWatch => true;

  @override
  Stream<DbChangeSet> get changes => _changes.stream;

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) {
    return database.delete(table, where: where, whereArgs: whereArgs);
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) {
    return database.execute(sql, arguments);
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    return database.insert(
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
    return database.query(
      table,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }

  Future<T> transaction<T>(
    Future<T> Function(SqliteLoomTransaction tx) action, {
    bool? exclusive,
  }) async {
    final accumulator = DbChangeAccumulator();
    final result = await database.transaction<T>((txn) async {
      final executor = _TxDbExecutor(
        transaction: txn,
        changes: changes,
        accumulator: accumulator,
      );
      return action(SqliteLoomTransaction._(executor));
    }, exclusive: exclusive);

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
    return database.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
      conflictAlgorithm: conflictAlgorithm,
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

  void dispose() {
    unawaited(_changes.close());
  }

  void _publish(DbChangeSet changeSet) {
    if (!_changes.isClosed && changeSet.isNotEmpty) {
      _changes.add(changeSet);
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

  @override
  DatabaseExecutor get executor => transaction;

  @override
  bool get canWatch => false;

  @override
  Stream<DbChangeSet> get changes => _changes;

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
}
