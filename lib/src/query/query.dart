import 'dart:async';

import 'package:sqflite_common/sqlite_api.dart';

import '../database/capabilities.dart';
import '../internal/executor.dart';
import '../internal/equality.dart';
import '../internal/sql.dart';
import 'cursor.dart';
import 'live_query.dart';

import '../model/column.dart';
import '../model/codec.dart';
import '../model/expression.dart';
import '../model/row.dart';
import '../model/table.dart';
import '../model/values.dart';
import 'change.dart';

export 'live_query.dart';
part 'compiled_query.dart';
part 'selection.dart';
part 'grouped_query.dart';

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
    sql.write(paginationSql(_limit, _offset));
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
    _assertSafeMutation();
    (await _executor.capabilities()).require(DbFeature.returning);
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
    final rows = await limit(firstLimit(_limit)).get();
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

  /// Reads bounded pages, honoring the source limit and initial offset.
  /// Supply deterministic ordering when traversing a changing database.
  Stream<List<Row>> pages({int size = 500}) async* {
    if (size < 1) throw ArgumentError.value(size, 'size', 'Must be positive');
    var pageOffset = _offset ?? 0;
    var remaining = _limit;
    while (remaining == null || remaining > 0) {
      final take = remaining == null || remaining > size ? size : remaining;
      final page = await _copyWith(limit: take, offset: pageOffset).get();
      if (page.isEmpty) return;
      yield page;
      if (remaining != null) remaining -= page.length;
      if (page.length < take) return;
      pageOffset += page.length;
    }
  }

  /// Reads bounded pages using a unique non-null cursor column.
  /// Existing ordering must match the cursor order exactly.
  Stream<List<Row>> keysetPages<T>(
    ComparableDbColumn<T> cursor, {
    int size = 500,
    bool descending = false,
  }) => keysetPagesBy([
    DbCursorColumn(cursor, descending: descending),
  ], size: size);

  /// Reads lexicographic cursor pages. The final component must break all ties.
  /// Honors the source limit and applies its offset only to the first page.
  Stream<List<Row>> keysetPagesBy(
    Iterable<AnyDbCursorColumn> columns, {
    int size = 500,
  }) async* {
    if (size < 1) throw ArgumentError.value(size, 'size', 'Must be positive');
    final cursor = columns.toList(growable: false);
    final ordered = _withCursorOrder(cursor);
    DbPredicate? bound;
    var remaining = _limit;
    var firstPage = true;
    while (remaining == null || remaining > 0) {
      final take = remaining == null || remaining > size ? size : remaining;
      final query = (bound == null ? ordered : ordered.where(bound))._copyWith(
        limit: take,
        offset: firstPage ? (_offset ?? 0) : 0,
      );
      final compiled = query.compile();
      final maps = await _executor.rawQuery(compiled.sql, compiled.arguments);
      if (maps.isEmpty) return;
      yield maps
          .map((map) => _table.decode(DbRow(map)))
          .toList(growable: false);
      if (remaining != null) remaining -= maps.length;
      if (maps.length < take) return;
      bound = cursorPredicate([
        for (final column in cursor) column.read(DbRow(maps.last)),
      ]);
      firstPage = false;
    }
  }

  /// Selects rows after a typed composite cursor in its declared sort order.
  DbTableQuery<Row, Key> afterCursor(Iterable<AnyDbCursorValue> values) {
    final cursor = values.toList(growable: false);
    if ((_offset ?? 0) != 0) {
      throw StateError('afterCursor cannot be combined with offset');
    }
    return _withCursorOrder([
      for (final value in cursor) value.column,
    ]).where(cursorPredicate(cursor));
  }

  DbTableQuery<Row, Key> _withCursorOrder(List<AnyDbCursorColumn> columns) {
    validateCursor(columns);
    final orderings = columns.map((column) => column.ordering).toList();
    if (_orderings.isNotEmpty &&
        (_orderings.length != orderings.length ||
            Iterable<int>.generate(
              orderings.length,
            ).any((index) => _orderings[index].sql != orderings[index].sql))) {
      throw StateError('Existing orderBy must match every cursor component');
    }
    return _copyWith(orderings: orderings);
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

  /// Starts a typed grouped query using one or more grouping [columns].
  DbGroupedQuery<Row, Key> groupBy(Iterable<AnyDbColumn> columns) {
    return DbGroupedQuery<Row, Key>._(this, columns.toList(growable: false));
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
    final stored = result.single;
    _executor.record(
      _table.tableId,
      DbChangeKind.insert,
      keys: stored[_table.primaryKey.name] == null
          ? null
          : [stored[_table.primaryKey.name]],
    );
    return _table.decode(DbRow(stored));
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
    final explicitKey = values.asMap[_table.primaryKey.name];
    // Zero is a valid explicit rowid. IGNORE can also return zero; in that
    // ambiguous case conservatively refresh rather than miss a stored row.
    if (insertedId != 0 ||
        conflictAlgorithm != ConflictAlgorithm.ignore ||
        explicitKey == null ||
        explicitKey == 0) {
      _executor.record(
        _table.tableId,
        DbChangeKind.insert,
        keys: conflictAlgorithm == ConflictAlgorithm.replace
            ? null
            : [explicitKey ?? insertedId],
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
    for (final rowsChunk in _chunks(rows, batchSize)) {
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
        if (insertedId is int &&
            (insertedId != 0 ||
                conflictAlgorithm != ConflictAlgorithm.ignore ||
                encodedRows[index].asMap[_table.primaryKey.name] == null ||
                encodedRows[index].asMap[_table.primaryKey.name] == 0)) {
          keys.add(
            encodedRows[index].asMap[_table.primaryKey.name] ?? insertedId,
          );
        }
      }
      if (keys.isNotEmpty) {
        _executor.record(
          _table.tableId,
          DbChangeKind.insert,
          keys: conflictAlgorithm == ConflictAlgorithm.replace ? null : keys,
        );
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
      keys:
          primaryKey == null ||
              conflictTarget != null ||
              (update?.asMap.containsKey(_table.primaryKey.name) ?? false)
          ? null
          : [primaryKey],
    );
    return row;
  }

  /// Inserts or updates every row using native SQLite UPSERT in one batch.
  Future<void> upsertAll(
    Iterable<Row> rows, {
    Iterable<AnyDbColumn>? conflictTarget,
    int? batchSize,
  }) async {
    for (final rowsChunk in _chunks(rows, batchSize)) {
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
        keys: hasUnknownKey || conflictTarget != null ? null : keys,
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
      _executor.record(
        _table.tableId,
        DbChangeKind.update,
        keys:
            values.asMap.containsKey(_table.primaryKey.name) ||
                conflictAlgorithm == ConflictAlgorithm.replace
            ? null
            : _keyScope,
      );
    }
    return affected;
  }

  /// Updates and returns affected rows using SQLite `RETURNING`.
  Future<List<Row>> updateReturning(DbValues values) async {
    _assertSafeMutation();
    (await _executor.capabilities()).require(DbFeature.returning);
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
      _executor.record(
        _table.tableId,
        DbChangeKind.update,
        keys: values.asMap.containsKey(_table.primaryKey.name)
            ? null
            : _keyScope,
      );
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
    if (_limit != null || _offset != null || _orderings.isNotEmpty) {
      throw StateError(
        'Mutations do not support orderBy, limit, or offset. '
        'Select keys first, then mutate those keys inside a transaction.',
      );
    }
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

Iterable<List<T>> _chunks<T>(Iterable<T> values, int? size) sync* {
  if (size != null && size < 1) {
    throw ArgumentError.value(size, 'batchSize', 'Must be positive');
  }
  var chunk = <T>[];
  for (final value in values) {
    chunk.add(value);
    if (size != null && chunk.length == size) {
      yield chunk;
      chunk = <T>[];
    }
  }
  if (chunk.isNotEmpty) yield chunk;
}
