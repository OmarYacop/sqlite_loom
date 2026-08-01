import 'dart:async';

import 'package:sqflite_common/sqlite_api.dart';

import 'change.dart';
import 'capabilities.dart';
import 'column.dart';
import 'expression.dart';
import 'internal/executor.dart';
import 'internal/sql.dart';
import 'row.dart';
import 'table.dart';
import 'values.dart';

/// Compares two live-query result lists for semantic equality.
typedef DbListEquals<Row> = bool Function(List<Row> left, List<Row> right);

/// An immutable query targeting one [DbTable].
final class DbTableQuery<Row, Key> {
  DbTableQuery.internal(
    this._executor,
    this._table, {
    List<DbPredicate> predicates = const [],
    List<DbOrdering> orderings = const [],
    int? limit,
    int? offset,
    bool allowAllRowsMutation = false,
    Set<Object?>? keyScope,
  }) : _predicates = List.unmodifiable(predicates),
       _orderings = List.unmodifiable(orderings),
       _limit = limit,
       _offset = offset,
       _allowAllRowsMutation = allowAllRowsMutation,
       _keyScope = keyScope == null ? null : Set.unmodifiable(keyScope);

  final DbExecutorAdapter _executor;
  final DbTable<Row, Key> _table;
  final List<DbPredicate> _predicates;
  final List<DbOrdering> _orderings;
  final int? _limit;
  final int? _offset;
  final bool _allowAllRowsMutation;
  final Set<Object?>? _keyScope;

  /// The table mapped by this query.
  DbTable<Row, Key> get table => _table;

  /// Compiles this query without executing it.
  DbCompiledQuery compile({Iterable<AnyDbColumn>? columns}) {
    final where = _compileWhere();
    final selected = columns?.toList(growable: false);
    final selection = selected == null
        ? '*'
        : selected.map((column) => quoteIdentifier(column.name)).join(', ');
    if (selected != null && selected.isEmpty) {
      throw ArgumentError.value(columns, 'columns', 'Cannot be empty');
    }
    final sql = StringBuffer(
      'SELECT $selection FROM ${quoteIdentifier(_table.tableName)}',
    );
    if (where != null) sql.write(' WHERE ${where.sql}');
    final orderBy = _compileOrderBy();
    if (orderBy != null) sql.write(' ORDER BY $orderBy');
    if (_limit != null) sql.write(' LIMIT $_limit');
    if (_offset != null) sql.write(' OFFSET $_offset');
    return DbCompiledQuery(sql.toString(), where?.arguments ?? const []);
  }

  /// Returns SQLite's query plan for this read.
  Future<List<DbQueryPlanRow>> explain() async {
    final compiled = compile();
    final rows = await _executor.rawQuery(
      'EXPLAIN QUERY PLAN ${compiled.sql}',
      compiled.arguments,
    );
    return rows.map(DbQueryPlanRow.fromMap).toList(growable: false);
  }

  /// Explicitly permits this query to update or delete every table row.
  DbTableQuery<Row, Key> allRows() {
    return _copyWith(allowAllRowsMutation: true);
  }

  /// Counts rows matching the current predicates.
  Future<int> count() async {
    final where = _compileWhere();
    final rows = await _executor.rawQuery(
      'SELECT COUNT(*) AS count FROM ${quoteIdentifier(_table.tableName)}'
      '${where == null ? '' : ' WHERE ${where.sql}'}',
      where?.arguments,
    );
    return rows.first['count'] as int;
  }

  /// Deletes matching rows and returns the number affected.
  Future<int> delete() async {
    _assertSafeMutation();
    final where = _compileWhere();
    final affected = await _executor.delete(
      _table.tableName,
      where: where?.sql,
      whereArgs: where?.arguments,
    );
    if (affected > 0) {
      _executor.record(_table.tableId, DbChangeKind.delete, keys: _keyScope);
    }
    return affected;
  }

  /// Deletes and returns affected rows using SQLite `RETURNING`.
  Future<List<Row>> deleteReturning() async {
    (await _executor.capabilities()).require(DbFeature.returning);
    _assertSafeMutation();
    final where = _compileWhere();
    final rows = await _executor.rawQuery(
      'DELETE FROM ${quoteIdentifier(_table.tableName)}'
      '${where == null ? '' : ' WHERE ${where.sql}'} RETURNING *',
      where?.arguments,
    );
    if (rows.isNotEmpty) {
      _executor.record(_table.tableId, DbChangeKind.delete, keys: _keyScope);
    }
    return rows.map((row) => _table.decode(DbRow(row))).toList(growable: false);
  }

  /// Whether at least one row matches.
  Future<bool> exists() async {
    final where = _compileWhere();
    final rows = await _executor.query(
      _table.tableName,
      columns: [_table.primaryKey.name],
      where: where?.sql,
      whereArgs: where?.arguments,
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Finds the row with [key], or returns null.
  Future<Row?> find(Key key) {
    return where(_table.primaryKey.equals(key)).firstOrNull();
  }

  /// Returns the first matching row or throws when there is none.
  Future<Row> first() async {
    final row = await firstOrNull();
    if (row == null) {
      throw StateError('No row found in ${_table.tableName}');
    }
    return row;
  }

  /// Returns the first matching row, or null.
  Future<Row?> firstOrNull() async {
    final rows = await limit(1).get();
    if (rows.isEmpty) {
      return null;
    }
    return rows.first;
  }

  /// Loads all rows selected by this query.
  Future<List<Row>> get() async {
    final where = _compileWhere();
    final maps = await _executor.query(
      _table.tableName,
      where: where?.sql,
      whereArgs: where?.arguments,
      orderBy: _compileOrderBy(),
      limit: _limit,
      offset: _offset,
    );
    return maps.map((map) => _table.decode(DbRow(map))).toList(growable: false);
  }

  /// Reads this query in bounded offset pages.
  Stream<List<Row>> pages({int size = 500}) async* {
    if (size < 1) throw ArgumentError.value(size, 'size', 'Must be positive');
    var pageOffset = _offset ?? 0;
    while (true) {
      final page = await _copyWith(limit: size, offset: pageOffset).get();
      if (page.isEmpty) return;
      yield page;
      if (page.length < size) return;
      pageOffset += page.length;
    }
  }

  /// Reads bounded pages using a unique [cursor] rather than large offsets.
  Stream<List<Row>> keysetPages<T>(
    ComparableDbColumn<T> cursor, {
    int size = 500,
    bool descending = false,
  }) async* {
    if (size < 1) throw ArgumentError.value(size, 'size', 'Must be positive');
    T? lastValue;
    var hasCursor = false;
    while (true) {
      var query = _copyWith(
        limit: size,
        orderings: [
          ..._orderings,
          descending ? cursor.descending() : cursor.ascending(),
        ],
      );
      if (hasCursor) {
        query = query.where(
          descending
              ? cursor.lessThan(lastValue as T)
              : cursor.greaterThan(lastValue as T),
        );
      }
      final where = query._compileWhere();
      final maps = await _executor.query(
        _table.tableName,
        where: where?.sql,
        whereArgs: where?.arguments,
        orderBy: query._compileOrderBy(),
        limit: size,
      );
      if (maps.isEmpty) return;
      final page = maps
          .map((map) => _table.decode(DbRow(map)))
          .toList(growable: false);
      yield page;
      if (page.length < size) return;
      lastValue = cursor.decode(maps.last[cursor.name]);
      hasCursor = true;
    }
  }

  /// Selects one typed value while retaining this query's filters and order.
  DbColumnSelection<Row, Key, T> pluck<T>(DbColumn<T> column) {
    return DbColumnSelection<Row, Key, T>._(this, column);
  }

  /// Selects [columns] without decoding the complete table model.
  ///
  /// Values remain typed when read from each returned [DbRow] with `row.get`.
  DbRowSelection<Row, Key> select(Iterable<AnyDbColumn> columns) {
    return DbRowSelection<Row, Key>._(this, columns.toList(growable: false));
  }

  /// Returns the sum of a numeric [column], or null when no value is present.
  Future<num?> sum<T extends num>(DbColumn<T> column) =>
      _numericAggregate('SUM', column);

  /// Returns the average of a numeric [column], or null when no value exists.
  Future<double?> average<T extends num>(DbColumn<T> column) async {
    final value = await _numericAggregate('AVG', column);
    return value?.toDouble();
  }

  /// Returns the smallest non-null value in [column].
  Future<T?> minimum<T>(DbColumn<T> column) => _aggregate('MIN', column);

  /// Returns the largest non-null value in [column].
  Future<T?> maximum<T>(DbColumn<T> column) => _aggregate('MAX', column);

  /// Inserts [row] and returns its primary key.
  Future<Key> insert(Row row, {ConflictAlgorithm? conflictAlgorithm}) async {
    final values = _table.encode(row);
    final insertedId = await insertValues(
      values,
      conflictAlgorithm: conflictAlgorithm,
    );
    final explicitKey = values.asMap[_table.primaryKey.name];
    if (explicitKey != null) {
      return _table.primaryKey.decode(explicitKey);
    }
    return _table.primaryKey.decode(insertedId);
  }

  /// Inserts and returns SQLite's stored row using `RETURNING`.
  Future<Row> insertReturning(Row row) async {
    (await _executor.capabilities()).require(DbFeature.returning);
    final values = _table.encode(row);
    _assertNotEmpty(values);
    final columns = values.asMap.keys.toList(growable: false);
    final result = await _executor.rawQuery(
      'INSERT INTO ${quoteIdentifier(_table.tableName)} '
      '(${columns.map(quoteIdentifier).join(', ')}) VALUES '
      '(${List.filled(columns.length, '?').join(', ')}) RETURNING *',
      values.asMap.values.toList(growable: false),
    );
    final stored = _table.decode(DbRow(result.single));
    _executor.record(
      _table.tableId,
      DbChangeKind.insert,
      keys: [_table.primaryKey.encode(_table.keyOf(stored))],
    );
    return stored;
  }

  /// Inserts pre-encoded [values] and returns SQLite's inserted row ID.
  Future<int> insertValues(
    DbValues values, {
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    _assertNotEmpty(values);
    final insertedId = await _executor.insert(
      _table.tableName,
      values.asMap,
      conflictAlgorithm: conflictAlgorithm,
    );
    if (insertedId != 0) {
      final explicitKey = values.asMap[_table.primaryKey.name];
      _executor.record(
        _table.tableId,
        DbChangeKind.insert,
        keys: [explicitKey ?? insertedId],
      );
    }
    return insertedId;
  }

  /// Inserts every row in [rows].
  Future<void> insertAll(
    Iterable<Row> rows, {
    ConflictAlgorithm? conflictAlgorithm,
    int? batchSize,
  }) async {
    final materialized = rows.toList(growable: false);
    if (materialized.isEmpty) return;
    for (final rowsChunk in _chunks(materialized, batchSize)) {
      final encodedRows = <DbValues>[];
      final results = await _executor.commitBatch((batch) {
        for (final row in rowsChunk) {
          final values = _table.encode(row);
          _assertNotEmpty(values);
          encodedRows.add(values);
          batch.insert(
            _table.tableName,
            values.asMap,
            conflictAlgorithm: conflictAlgorithm,
          );
        }
      }, noResult: false);
      final keys = <Object?>[];
      for (var index = 0; index < results.length; index += 1) {
        final insertedId = results[index];
        if (insertedId is int && insertedId != 0) {
          keys.add(
            encodedRows[index].asMap[_table.primaryKey.name] ?? insertedId,
          );
        }
      }
      if (keys.isNotEmpty) {
        _executor.record(_table.tableId, DbChangeKind.insert, keys: keys);
      }
    }
  }

  /// Returns a query limited to at most [value] rows.
  DbTableQuery<Row, Key> limit(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'Limit must not be negative');
    }
    return _copyWith(limit: value);
  }

  /// Returns a query that skips [value] rows.
  DbTableQuery<Row, Key> offset(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'Offset must not be negative');
    }
    return _copyWith(offset: value);
  }

  /// Adds an efficient ascending keyset cursor predicate.
  DbTableQuery<Row, Key> after<T>(
    ComparableDbColumn<T> column,
    T value, {
    bool inclusive = false,
  }) {
    return where(
      inclusive ? column.greaterThanOrEquals(value) : column.greaterThan(value),
    );
  }

  /// Adds an efficient descending keyset cursor predicate.
  DbTableQuery<Row, Key> before<T>(
    ComparableDbColumn<T> column,
    T value, {
    bool inclusive = false,
  }) {
    return where(
      inclusive ? column.lessThanOrEquals(value) : column.lessThan(value),
    );
  }

  /// Appends [ordering] to this query's ordering list.
  DbTableQuery<Row, Key> orderBy(DbOrdering ordering) {
    return _copyWith(orderings: [..._orderings, ordering]);
  }

  /// Inserts or replaces [row] and returns it.
  Future<Row> save(
    Row row, {
    ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.replace,
  }) {
    return upsert(row, conflictAlgorithm: conflictAlgorithm);
  }

  /// Inserts [row] using the selected conflict algorithm.
  Future<Row> upsert(
    Row row, {
    ConflictAlgorithm? conflictAlgorithm,
    Iterable<AnyDbColumn>? conflictTarget,
    DbValues? update,
  }) async {
    if (conflictAlgorithm != null) {
      await insert(row, conflictAlgorithm: conflictAlgorithm);
      return row;
    }
    final values = _table.encode(row);
    final statement = _compileUpsert(
      values,
      conflictTarget: conflictTarget,
      update: update,
    );
    await _executor.rawInsert(statement.sql, statement.arguments);
    final primaryKey = values.asMap[_table.primaryKey.name];
    _executor.record(
      _table.tableId,
      DbChangeKind.insert,
      keys: primaryKey == null ? null : [primaryKey],
    );
    return row;
  }

  /// Inserts or updates every row using native SQLite UPSERT in one batch.
  Future<void> upsertAll(
    Iterable<Row> rows, {
    Iterable<AnyDbColumn>? conflictTarget,
    int? batchSize,
  }) async {
    final materialized = rows.toList(growable: false);
    if (materialized.isEmpty) return;
    for (final rowsChunk in _chunks(materialized, batchSize)) {
      final keys = <Object?>[];
      var hasUnknownKey = false;
      await _executor.commitBatch((batch) {
        for (final row in rowsChunk) {
          final values = _table.encode(row);
          final statement = _compileUpsert(
            values,
            conflictTarget: conflictTarget,
          );
          batch.rawInsert(statement.sql, statement.arguments);
          final key = values.asMap[_table.primaryKey.name];
          if (key == null) {
            hasUnknownKey = true;
          } else {
            keys.add(key);
          }
        }
      }, noResult: true);
      _executor.record(
        _table.tableId,
        DbChangeKind.insert,
        keys: hasUnknownKey ? null : keys,
      );
    }
  }

  /// Updates matching rows with [values] and returns the number affected.
  Future<int> update(
    DbValues values, {
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    _assertSafeMutation();
    _assertNotEmpty(values);
    final where = _compileWhere();
    final affected = await _executor.update(
      _table.tableName,
      values.asMap,
      where: where?.sql,
      whereArgs: where?.arguments,
      conflictAlgorithm: conflictAlgorithm,
    );
    if (affected > 0) {
      _executor.record(_table.tableId, DbChangeKind.update, keys: _keyScope);
    }
    return affected;
  }

  /// Updates and returns affected rows using SQLite `RETURNING`.
  Future<List<Row>> updateReturning(DbValues values) async {
    (await _executor.capabilities()).require(DbFeature.returning);
    _assertSafeMutation();
    _assertNotEmpty(values);
    final where = _compileWhere();
    final assignments = values.asMap.keys
        .map((name) => '${quoteIdentifier(name)} = ?')
        .join(', ');
    final rows = await _executor.rawQuery(
      'UPDATE ${quoteIdentifier(_table.tableName)} SET $assignments'
      '${where == null ? '' : ' WHERE ${where.sql}'} RETURNING *',
      [...values.asMap.values, ...?where?.arguments],
    );
    if (rows.isNotEmpty) {
      _executor.record(_table.tableId, DbChangeKind.update, keys: _keyScope);
    }
    return rows.map((row) => _table.decode(DbRow(row))).toList(growable: false);
  }

  /// Performs an optimistic update and increments [version] on success.
  Future<bool> updateIfVersion(
    DbColumn<int> version,
    int expected,
    DbValues values,
  ) async {
    if (_keyScope == null || _keyScope.length != 1) {
      throw StateError(
        'updateIfVersion requires a query scoped by exactly one whereKey',
      );
    }
    final merged = DbValues.raw({
      ...values.asMap,
      version.name: version.encode(expected + 1),
    });
    return await where(version.equals(expected)).update(merged) == 1;
  }

  /// Marks matching rows as deleted using a nullable timestamp [column].
  Future<int> softDelete(DbColumn<DateTime?> column, {DateTime? at}) {
    return update(DbValues({column: at ?? DateTime.now()}));
  }

  /// Watches the number of matching rows.
  Stream<int> watchCount() {
    return _watch<int>(load: count, equals: (left, right) => left == right);
  }

  /// Watches whether any matching row exists.
  Stream<bool> watchExists() {
    return _watch<bool>(load: exists, equals: (left, right) => left == right);
  }

  /// Watches matching rows, optionally using a custom list [equals] function.
  Stream<List<Row>> watch({DbListEquals<Row>? equals}) {
    return _watch<List<Row>>(load: get, equals: equals ?? _listEquals);
  }

  /// Watches the first matching row or null.
  Stream<Row?> watchFirstOrNull() {
    return _watch<Row?>(load: firstOrNull, equals: _nullableRowEquals);
  }

  /// Returns a query with [predicate] appended using `AND`.
  DbTableQuery<Row, Key> where(DbPredicate predicate) {
    return _copyWith(predicates: [..._predicates, predicate]);
  }

  /// Returns a query filtered by its primary [key].
  DbTableQuery<Row, Key> whereKey(Key key) {
    final encoded = _table.primaryKey.encode(key);
    final nextScope = _keyScope == null
        ? <Object?>{encoded}
        : _keyScope.intersection(<Object?>{encoded});
    return _copyWith(
      predicates: [..._predicates, _table.primaryKey.equals(key)],
      keyScope: nextScope,
    );
  }

  /// Filters by all components of a [key].
  DbTableQuery<Row, Key> whereCompositeKey(DbCompositeKey key) {
    return where(key.predicate);
  }

  Future<T?> _aggregate<T>(String function, DbColumn<T> column) async {
    final where = _compileWhere();
    final rows = await _executor.rawQuery(
      'SELECT $function(${column.sql}) AS value FROM '
      '${quoteIdentifier(_table.tableName)}'
      '${where == null ? '' : ' WHERE ${where.sql}'}',
      where?.arguments,
    );
    final value = rows.first['value'];
    return value == null ? null : column.decode(value);
  }

  Future<num?> _numericAggregate<T extends num>(
    String function,
    DbColumn<T> column,
  ) async {
    final where = _compileWhere();
    final rows = await _executor.rawQuery(
      'SELECT $function(${column.sql}) AS value FROM '
      '${quoteIdentifier(_table.tableName)}'
      '${where == null ? '' : ' WHERE ${where.sql}'}',
      where?.arguments,
    );
    return rows.first['value'] as num?;
  }

  _DbUpsertStatement _compileUpsert(
    DbValues values, {
    Iterable<AnyDbColumn>? conflictTarget,
    DbValues? update,
  }) {
    _assertNotEmpty(values);
    final targets =
        conflictTarget?.toList(growable: false) ??
        <AnyDbColumn>[_table.primaryKey];
    if (targets.isEmpty) {
      throw ArgumentError.value(conflictTarget, 'conflictTarget', 'Empty');
    }
    final updateValues =
        update?.asMap ??
        {
          for (final entry in values.asMap.entries)
            if (!targets.any((column) => column.name == entry.key))
              entry.key: entry.value,
        };
    final columns = values.asMap.keys.toList(growable: false);
    final insertSql = columns.map(quoteIdentifier).join(', ');
    final placeholders = List.filled(columns.length, '?').join(', ');
    final targetSql = targets
        .map((column) => quoteIdentifier(column.name))
        .join(', ');
    final updateSql = updateValues.isEmpty
        ? 'DO NOTHING'
        : 'DO UPDATE SET ${updateValues.keys.map((name) => '${quoteIdentifier(name)} = ?').join(', ')}';
    return _DbUpsertStatement(
      'INSERT INTO ${quoteIdentifier(_table.tableName)} ($insertSql) '
      'VALUES ($placeholders) ON CONFLICT ($targetSql) $updateSql',
      [...values.asMap.values, ...updateValues.values],
    );
  }

  String? _compileOrderBy() {
    return joinSql(_orderings.map((ordering) => ordering.sql), ', ');
  }

  DbPredicate? _compileWhere() {
    if (_predicates.isEmpty) {
      return null;
    }
    return _predicates.reduce((left, right) => left.and(right));
  }

  DbTableQuery<Row, Key> _copyWith({
    List<DbPredicate>? predicates,
    List<DbOrdering>? orderings,
    int? limit,
    int? offset,
    bool? allowAllRowsMutation,
    Set<Object?>? keyScope,
  }) {
    return DbTableQuery<Row, Key>.internal(
      _executor,
      _table,
      predicates: predicates ?? _predicates,
      orderings: orderings ?? _orderings,
      limit: limit ?? _limit,
      offset: offset ?? _offset,
      allowAllRowsMutation: allowAllRowsMutation ?? _allowAllRowsMutation,
      keyScope: keyScope ?? _keyScope,
    );
  }

  bool _listEquals(List<Row> left, List<Row> right) {
    if (identical(left, right)) {
      return true;
    }
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (!_table.equals(left[index], right[index])) {
        return false;
      }
    }
    return true;
  }

  bool _nullableRowEquals(Row? left, Row? right) {
    if (left == null || right == null) {
      return left == right;
    }
    return _table.equals(left, right);
  }

  void _assertNotEmpty(DbValues values) {
    if (values.isEmpty) {
      throw ArgumentError.value(
        values,
        'values',
        'Mutation values must not be empty',
      );
    }
  }

  void _assertSafeMutation() {
    if (_predicates.isEmpty && !_allowAllRowsMutation) {
      throw StateError(
        'Refusing to mutate every row in ${_table.tableName}. '
        'Add a predicate or call allRows() explicitly.',
      );
    }
  }

  Stream<T> _watch<T>({
    required Future<T> Function() load,
    required bool Function(T left, T right) equals,
  }) {
    if (!_executor.canWatch) {
      throw StateError(
        'Live queries cannot be created from an active transaction',
      );
    }
    return DbLiveQuery<T>(
      changes: _executor.changes,
      dependencies: {_table.tableId},
      keys: _keyScope,
      load: load,
      equals: equals,
    ).stream;
  }
}

/// Coalesces dependency invalidations while asynchronously reloading a value.
final class DbLiveQuery<T> {
  DbLiveQuery({
    required Stream<DbChangeSet> changes,
    required Set<DbTableId> dependencies,
    Set<Object?>? keys,
    required Future<T> Function() load,
    required bool Function(T left, T right) equals,
  }) : _changes = changes,
       _dependencies = dependencies,
       _keys = keys,
       _load = load,
       _equals = equals;

  final Stream<DbChangeSet> _changes;
  final Set<DbTableId> _dependencies;
  final Set<Object?>? _keys;
  final Future<T> Function() _load;
  final bool Function(T left, T right) _equals;

  Stream<T> get stream {
    late StreamController<T> controller;
    StreamSubscription<DbChangeSet>? subscription;
    var active = true;
    var dirty = false;
    var running = false;
    var hasValue = false;
    T? lastValue;

    Future<void> pump() async {
      if (running || !active) {
        dirty = true;
        return;
      }
      running = true;
      dirty = true;
      try {
        while (dirty && active) {
          dirty = false;
          final next = await _load();
          if (!active) {
            return;
          }
          final shouldEmit = !hasValue || !_equals(lastValue as T, next);
          if (shouldEmit) {
            hasValue = true;
            lastValue = next;
            controller.add(next);
          }
        }
      } catch (error, stackTrace) {
        if (active) {
          controller.addError(error, stackTrace);
        }
      } finally {
        running = false;
        if (dirty && active) {
          unawaited(pump());
        }
      }
    }

    controller = StreamController<T>(
      onListen: () {
        subscription = _changes.listen((changeSet) {
          if (_isAffected(changeSet)) {
            dirty = true;
            unawaited(pump());
          }
        }, onError: controller.addError);
        unawaited(pump());
      },
      onCancel: () async {
        active = false;
        await subscription?.cancel();
      },
    );

    return controller.stream;
  }

  bool _isAffected(DbChangeSet changeSet) {
    if (!changeSet.affects(_dependencies)) return false;
    final keys = _keys;
    if (keys == null) return true;
    for (final table in _dependencies) {
      final change = changeSet[table];
      if (change == null) continue;
      if (change.keys == null || change.keys!.any(keys.contains)) return true;
    }
    return false;
  }
}

Iterable<List<T>> _chunks<T>(List<T> values, int? size) sync* {
  final chunkSize = size ?? values.length;
  if (chunkSize < 1) {
    throw ArgumentError.value(size, 'batchSize', 'Must be positive');
  }
  for (var start = 0; start < values.length; start += chunkSize) {
    final end = (start + chunkSize).clamp(0, values.length);
    yield values.sublist(start, end);
  }
}

/// SQL and bound arguments produced from an immutable query.
final class DbCompiledQuery {
  DbCompiledQuery(this.sql, Iterable<Object?> arguments)
    : arguments = List.unmodifiable(arguments);

  final String sql;
  final List<Object?> arguments;
}

/// One row returned by SQLite's `EXPLAIN QUERY PLAN` command.
final class DbQueryPlanRow {
  const DbQueryPlanRow({
    required this.id,
    required this.parent,
    required this.detail,
  });

  factory DbQueryPlanRow.fromMap(Map<String, Object?> map) {
    return DbQueryPlanRow(
      id: map['id']! as int,
      parent: map['parent']! as int,
      detail: map['detail']! as String,
    );
  }

  final int id;
  final int parent;
  final String detail;

  bool usesIndex(String name) => detail.contains(name);
}

final class _DbUpsertStatement {
  const _DbUpsertStatement(this.sql, this.arguments);

  final String sql;
  final List<Object?> arguments;
}

/// A typed single-column projection derived from a table query.
final class DbColumnSelection<Row, Key, T> {
  DbColumnSelection._(this._source, this.column);

  final DbTableQuery<Row, Key> _source;
  final DbColumn<T> column;

  Future<List<T>> get() async {
    final where = _source._compileWhere();
    final maps = await _source._executor.query(
      _source._table.tableName,
      columns: [column.name],
      where: where?.sql,
      whereArgs: where?.arguments,
      orderBy: _source._compileOrderBy(),
      limit: _source._limit,
      offset: _source._offset,
    );
    return maps
        .map((map) => column.decode(map[column.name]))
        .toList(growable: false);
  }

  /// Returns the first projected value or throws when there is none.
  Future<T> first() async {
    final values = await _source.limit(1).pluck(column).get();
    if (values.isEmpty) throw StateError('No projected value found');
    return values.first;
  }

  /// Returns the first projected value, or null.
  Future<T?> firstOrNull() async {
    final values = await _source.limit(1).pluck(column).get();
    return values.isEmpty ? null : values.first;
  }

  Stream<List<T>> watch() =>
      _source._watch<List<T>>(load: get, equals: _valueListEquals);

  /// Watches the first projected value or null.
  Stream<T?> watchFirstOrNull() => _source._watch<T?>(
    load: firstOrNull,
    equals: (left, right) => left == right,
  );

  bool _valueListEquals(List<T> left, List<T> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

/// A selected set of columns decoded lazily through [DbRow.get].
final class DbRowSelection<Row, Key> {
  DbRowSelection._(
    this._source,
    List<AnyDbColumn> columns, {
    bool distinct = false,
  }) : columns = List.unmodifiable(columns),
       _distinct = distinct {
    if (columns.isEmpty) {
      throw ArgumentError.value(columns, 'columns', 'Cannot be empty');
    }
    final names = columns.map((column) => column.name).toSet();
    if (names.length != columns.length) {
      throw ArgumentError.value(columns, 'columns', 'Duplicate column names');
    }
  }

  final DbTableQuery<Row, Key> _source;
  final List<AnyDbColumn> columns;
  final bool _distinct;

  /// Removes duplicate projected rows.
  DbRowSelection<Row, Key> distinct() =>
      DbRowSelection._(_source, columns, distinct: true);

  /// Decodes each projected row into an application-specific result.
  DbDecodedSelection<Row, Key, Result> decodeWith<Result>(
    Result Function(DbRow row) decode,
  ) {
    return DbDecodedSelection._(this, decode);
  }

  Future<List<DbRow>> get() async {
    final compiled = _source.compile(columns: columns);
    final sql = _distinct
        ? compiled.sql.replaceFirst('SELECT ', 'SELECT DISTINCT ')
        : compiled.sql;
    final maps = await _source._executor.rawQuery(sql, compiled.arguments);
    return maps.map(DbRow.new).toList(growable: false);
  }

  Stream<List<DbRow>> watch() =>
      _source._watch<List<DbRow>>(load: get, equals: _rowsEqual);

  bool _rowsEqual(List<DbRow> left, List<DbRow> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      final leftMap = left[index].asMap;
      final rightMap = right[index].asMap;
      if (leftMap.length != rightMap.length) return false;
      for (final entry in leftMap.entries) {
        if (!rightMap.containsKey(entry.key) ||
            rightMap[entry.key] != entry.value) {
          return false;
        }
      }
    }
    return true;
  }
}

/// A projection decoded directly into [Result] values.
final class DbDecodedSelection<Row, Key, Result> {
  const DbDecodedSelection._(this._selection, this._decode);
  final DbRowSelection<Row, Key> _selection;
  final Result Function(DbRow row) _decode;

  Future<List<Result>> get() async =>
      (await _selection.get()).map(_decode).toList(growable: false);

  Stream<List<Result>> watch() => _selection.watch().map(
    (rows) => rows.map(_decode).toList(growable: false),
  );
}
