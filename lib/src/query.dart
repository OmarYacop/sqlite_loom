import 'dart:async';

import 'package:sqflite_common/sqlite_api.dart';

import 'change.dart';
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
  }) : _predicates = List.unmodifiable(predicates),
       _orderings = List.unmodifiable(orderings),
       _limit = limit,
       _offset = offset,
       _allowAllRowsMutation = allowAllRowsMutation;

  final DbExecutorAdapter _executor;
  final DbTable<Row, Key> _table;
  final List<DbPredicate> _predicates;
  final List<DbOrdering> _orderings;
  final int? _limit;
  final int? _offset;
  final bool _allowAllRowsMutation;

  /// The table mapped by this query.
  DbTable<Row, Key> get table => _table;

  /// Explicitly permits this query to update or delete every table row.
  DbTableQuery<Row, Key> allRows() {
    return _copyWith(allowAllRowsMutation: true);
  }

  /// Counts rows matching the current predicates.
  Future<int> count() async {
    final where = _compileWhere();
    final rows = await _executor.executor.rawQuery(
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
      _executor.record(_table.tableId, DbChangeKind.delete);
    }
    return affected;
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
  }) async {
    final materialized = rows.toList(growable: false);
    if (materialized.isEmpty) {
      return;
    }
    final keys = <Object?>[];
    for (final row in materialized) {
      final values = _table.encode(row);
      _assertNotEmpty(values);
      final insertedId = await _executor.insert(
        _table.tableName,
        values.asMap,
        conflictAlgorithm: conflictAlgorithm,
      );
      if (insertedId != 0) {
        keys.add(values.asMap[_table.primaryKey.name] ?? insertedId);
      }
    }
    if (keys.isNotEmpty) {
      _executor.record(_table.tableId, DbChangeKind.insert, keys: keys);
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
    ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.replace,
  }) async {
    await insert(row, conflictAlgorithm: conflictAlgorithm);
    return row;
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
      _executor.record(_table.tableId, DbChangeKind.update);
    }
    return affected;
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
    return where(_table.primaryKey.equals(key));
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
  }) {
    return DbTableQuery<Row, Key>.internal(
      _executor,
      _table,
      predicates: predicates ?? _predicates,
      orderings: orderings ?? _orderings,
      limit: limit ?? _limit,
      offset: offset ?? _offset,
      allowAllRowsMutation: allowAllRowsMutation ?? _allowAllRowsMutation,
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
    return _LiveQuery<T>(
      changes: _executor.changes,
      dependencies: {_table.tableId},
      load: load,
      equals: equals,
    ).stream;
  }
}

final class _LiveQuery<T> {
  _LiveQuery({
    required Stream<DbChangeSet> changes,
    required Set<DbTableId> dependencies,
    required Future<T> Function() load,
    required bool Function(T left, T right) equals,
  }) : _changes = changes,
       _dependencies = dependencies,
       _load = load,
       _equals = equals;

  final Stream<DbChangeSet> _changes;
  final Set<DbTableId> _dependencies;
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
          if (changeSet.affects(_dependencies)) {
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
}
