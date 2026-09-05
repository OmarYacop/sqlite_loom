part of 'database.dart';

final class _RootDbExecutor
    with _ObservedDbOperations
    implements DbExecutorAdapter {
  _RootDbExecutor(
    this.database, {
    DbObserver? observer,
    DbObserverErrorHandler? onObserverError,
    Duration? slowQueryThreshold,
    Map<String, String> observerContext = const {},
  }) : _observer = observer,
       _onObserverError = onObserverError,
       _slowQueryThreshold = slowQueryThreshold,
       _observerContext = Map.unmodifiable(observerContext) {
    if (slowQueryThreshold != null && slowQueryThreshold.isNegative) {
      throw ArgumentError.value(
        slowQueryThreshold,
        'slowQueryThreshold',
        'Cannot be negative',
      );
    }
  }

  final Database database;
  final DbObserver? _observer;
  final DbObserverErrorHandler? _onObserverError;
  final Duration? _slowQueryThreshold;
  final Map<String, String> _observerContext;
  int _observationSequence = 0;
  int _transactionSequence = 0;
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

  Future<T> transaction<T>(
    Future<T> Function(SqliteLoomTransaction tx) action, {
    bool? exclusive,
  }) async {
    final accumulator = DbChangeAccumulator();
    final transactionId = _transactionSequence++;
    final result = await _observe(
      'transaction',
      () => database.transaction<T>((txn) async {
        final executor = _TxDbExecutor(
          transaction: txn,
          owner: this,
          transactionId: transactionId,
          changes: changes,
          accumulator: accumulator,
        );
        return action(SqliteLoomTransaction._(executor));
      }, exclusive: exclusive),
      transactionId: transactionId,
    );

    if (accumulator.isNotEmpty) {
      _publish(accumulator.toChangeSet());
    }
    return result;
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

  @override
  Future<T> _observe<T>(
    String operation,
    Future<T> Function() action, {
    String? table,
    String? sql,
    int Function(T value)? count,
    int? transactionId,
  }) async {
    if (_observer == null) return action();
    final sequence = _observationSequence++;
    final startedAt = DateTime.now().toUtc();
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
          sequence: sequence,
          transactionId: transactionId,
          startedAt: startedAt,
          isSlow:
              _slowQueryThreshold != null &&
              stopwatch.elapsed >= _slowQueryThreshold,
          context: _observerContext,
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
          sequence: sequence,
          transactionId: transactionId,
          startedAt: startedAt,
          isSlow:
              _slowQueryThreshold != null &&
              stopwatch.elapsed >= _slowQueryThreshold,
          context: _observerContext,
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

final class _TxDbExecutor
    with _ObservedDbOperations
    implements DbExecutorAdapter {
  _TxDbExecutor({
    required this.transaction,
    required this.owner,
    required this.transactionId,
    required Stream<DbChangeSet> changes,
    required DbChangeAccumulator accumulator,
  }) : _changes = changes,
       _accumulator = accumulator;

  final Transaction transaction;
  final _RootDbExecutor owner;
  final int transactionId;

  @override
  Future<T> _observe<T>(
    String operation,
    Future<T> Function() action, {
    String? table,
    String? sql,
    int Function(T value)? count,
  }) => owner._observe(
    operation,
    action,
    table: table,
    sql: sql,
    count: count,
    transactionId: transactionId,
  );
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

/// Both sessions use exactly the same operation metadata and forwarding paths.
mixin _ObservedDbOperations implements DbExecutorAdapter {
  Future<T> _observe<T>(
    String operation,
    Future<T> Function() action, {
    String? table,
    String? sql,
    int Function(T value)? count,
  });

  @override
  Future<List<Object?>> commitBatch(
    void Function(Batch batch) build, {
    required bool noResult,
  }) {
    return _observe('batch', () {
      final batch = executor.batch();
      build(batch);
      return batch.commit(noResult: noResult);
    }, count: (results) => results.length);
  }

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) {
    return _observe(
      'delete',
      () => executor.delete(table, where: where, whereArgs: whereArgs),
      table: table,
      count: (value) => value,
    );
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) {
    return _observe(
      'execute',
      () => executor.execute(sql, arguments),
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
      () => executor.insert(
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
      () => executor.query(
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
      () => executor.rawQuery(sql, arguments),
      sql: sql,
      count: (rows) => rows.length,
    );
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) {
    return _observe(
      'insert',
      () => executor.rawInsert(sql, arguments),
      sql: sql,
      count: (_) => 1,
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
    return _observe(
      'update',
      () => executor.update(
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
}
