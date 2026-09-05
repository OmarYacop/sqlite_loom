part of 'query.dart';

/// A typed aggregate expression selected by a [DbGroupedQuery].
final class DbAggregate<T> {
  DbAggregate._(this.sql, this.resultColumn);

  /// Counts rows in each group.
  static DbAggregate<int> count({String as = 'count'}) =>
      DbAggregate<int>._('COUNT(*)', integer(as));

  /// Sums non-null numeric values in each group.
  static DbAggregate<num?> sum<T extends num>(
    DbColumn<T> column, {
    String as = 'sum',
  }) => DbAggregate<num?>._(
    'SUM(${column.sql})',
    DbColumn<num?>(
      as,
      codec: DbCodec<num?>(
        encode: (value) => value,
        decode: (value) => value as num?,
      ),
      affinity: 'NUMERIC',
    ),
  );

  /// Averages non-null numeric values in each group.
  static DbAggregate<double?> average<T extends num>(
    DbColumn<T> column, {
    String as = 'average',
  }) => DbAggregate<double?>._(
    'AVG(${column.sql})',
    DbColumn<double?>(
      as,
      codec: DbCodec<double?>(
        encode: (value) => value,
        decode: (value) => value == null ? null : (value as num).toDouble(),
      ),
      affinity: 'REAL',
    ),
  );

  /// Selects the smallest non-null value in each group.
  static DbAggregate<T?> minimum<T>(
    DbColumn<T> column, {
    String as = 'minimum',
  }) => _fromColumn('MIN', column, as);

  /// Selects the largest non-null value in each group.
  static DbAggregate<T?> maximum<T>(
    DbColumn<T> column, {
    String as = 'maximum',
  }) => _fromColumn('MAX', column, as);

  static DbAggregate<T?> _fromColumn<T>(
    String function,
    DbColumn<T> column,
    String as,
  ) => DbAggregate<T?>._(
    '$function(${column.sql})',
    DbColumn<T?>(
      as,
      codec: DbCodec<T?>(
        encode: (value) => value == null ? null : column.encode(value),
        decode: (value) => value == null ? null : column.decode(value),
      ),
      affinity: column.affinity,
    ),
  );

  final String sql;

  /// The aliased result column used to decode this aggregate from [DbRow].
  final DbColumn<T> resultColumn;
}

/// An immutable grouped query with typed grouping columns and aggregates.
final class DbGroupedQuery<Row, Key> {
  DbGroupedQuery._(
    this._source,
    List<AnyDbColumn> groupColumns, {
    List<DbPredicate> having = const [],
    List<DbOrdering>? orderings,
    int? limit,
    int? offset,
  }) : groupColumns = List.unmodifiable(groupColumns),
       _having = List.unmodifiable(having),
       _orderings = List.unmodifiable(orderings ?? _source._orderings),
       _limit = limit ?? _source._limit,
       _offset = offset ?? _source._offset {
    if (groupColumns.isEmpty) {
      throw ArgumentError.value(groupColumns, 'columns', 'Cannot be empty');
    }
  }

  final DbTableQuery<Row, Key> _source;
  final List<AnyDbColumn> groupColumns;
  final List<DbPredicate> _having;
  final List<DbOrdering> _orderings;
  final int? _limit;
  final int? _offset;

  DbGroupedQuery<Row, Key> having(DbPredicate predicate) =>
      _copyWith(having: [..._having, predicate]);

  DbGroupedQuery<Row, Key> orderBy(DbOrdering ordering) =>
      _copyWith(orderings: [..._orderings, ordering]);

  DbGroupedQuery<Row, Key> limit(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'Limit must not be negative');
    }
    return _copyWith(limit: value);
  }

  DbGroupedQuery<Row, Key> offset(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'Offset must not be negative');
    }
    return _copyWith(offset: value);
  }

  /// Selects grouping columns and [DbAggregate] expressions.
  DbGroupedSelection<Row, Key> select(Iterable<Object> expressions) =>
      DbGroupedSelection<Row, Key>._(this, expressions.toList(growable: false));

  DbGroupedQuery<Row, Key> _copyWith({
    List<DbPredicate>? having,
    List<DbOrdering>? orderings,
    int? limit,
    int? offset,
  }) => DbGroupedQuery<Row, Key>._(
    _source,
    groupColumns,
    having: having ?? _having,
    orderings: orderings ?? _orderings,
    limit: limit ?? _limit,
    offset: offset ?? _offset,
  );
}

/// Executable grouped selection returning typed [DbRow] values.
final class DbGroupedSelection<Row, Key> {
  DbGroupedSelection._(this._query, List<Object> expressions)
    : expressions = List.unmodifiable(expressions) {
    if (expressions.isEmpty) {
      throw ArgumentError.value(expressions, 'expressions', 'Cannot be empty');
    }
    if (expressions.any(
      (expression) => expression is! AnyDbColumn && expression is! DbAggregate,
    )) {
      throw ArgumentError.value(
        expressions,
        'expressions',
        'Only DbColumn and DbAggregate values are supported',
      );
    }
    final names = expressions.map(_resultName).toList(growable: false);
    if (names.toSet().length != names.length) {
      throw ArgumentError.value(
        expressions,
        'expressions',
        'Duplicate aliases',
      );
    }
  }

  final DbGroupedQuery<Row, Key> _query;
  final List<Object> expressions;

  DbCompiledQuery compile() => _compile();

  DbCompiledQuery _compile({
    bool includeOrder = true,
    bool includePagination = true,
  }) {
    final source = _query._source;
    final where = source._compileWhere();
    final sql = StringBuffer(
      'SELECT ${expressions.map(_selectionSql).join(', ')} FROM '
      '${quoteIdentifier(source._table.tableName)}',
    );
    final arguments = <Object?>[...?where?.arguments];
    if (where != null) sql.write(' WHERE ${where.sql}');
    sql.write(
      ' GROUP BY ${_query.groupColumns.map((column) => quoteIdentifier(column.name)).join(', ')}',
    );
    if (_query._having.isNotEmpty) {
      final having = _query._having.reduce((left, right) => left.and(right));
      sql.write(' HAVING ${having.sql}');
      arguments.addAll(having.arguments);
    }
    if (includeOrder && _query._orderings.isNotEmpty) {
      sql.write(
        ' ORDER BY ${_query._orderings.map((ordering) => ordering.sql).join(', ')}',
      );
    }
    if (includePagination) {
      sql.write(paginationSql(_query._limit, _query._offset));
    }
    return DbCompiledQuery(sql.toString(), List.unmodifiable(arguments));
  }

  Future<List<DbRow>> get() async {
    final compiled = compile();
    final rows = await _query._source._executor.rawQuery(
      compiled.sql,
      compiled.arguments,
    );
    return rows.map(DbRow.new).toList(growable: false);
  }

  Future<DbRow> first() async {
    final row = await firstOrNull();
    if (row == null) throw StateError('No grouped row found');
    return row;
  }

  Future<DbRow?> firstOrNull() async {
    final rows = await DbGroupedSelection<Row, Key>._(
      _query.limit(firstLimit(_query._limit)),
      expressions,
    ).get();
    return rows.firstOrNull;
  }

  Future<int> count() async {
    final compiled = _compile(includeOrder: false, includePagination: false);
    final rows = await _query._source._executor.rawQuery(
      'SELECT COUNT(*) AS count FROM (${compiled.sql}) AS _loom_groups',
      compiled.arguments,
    );
    return rows.single['count']! as int;
  }

  Future<List<DbQueryPlanRow>> explain() async {
    final compiled = compile();
    final rows = await _query._source._executor.rawQuery(
      'EXPLAIN QUERY PLAN ${compiled.sql}',
      compiled.arguments,
    );
    return rows.map(DbQueryPlanRow.fromMap).toList(growable: false);
  }

  Stream<List<DbRow>> watch() => _query._source._watch<List<DbRow>>(
    load: get,
    equals: (left, right) => dbValueEquals(
      left.map((row) => row.asMap).toList(),
      right.map((row) => row.asMap).toList(),
    ),
  );

  DbDecodedGroupedSelection<Row, Key, Result> decodeWith<Result>(
    Result Function(DbRow row) decode,
  ) => DbDecodedGroupedSelection._(this, decode);

  static String _selectionSql(Object expression) => switch (expression) {
    AnyDbColumn(:final name) => quoteIdentifier(name),
    DbAggregate(:final sql, :final resultColumn) =>
      '$sql AS ${quoteIdentifier(resultColumn.name)}',
    _ => throw StateError('Unsupported grouped expression'),
  };

  static String _resultName(Object expression) => switch (expression) {
    AnyDbColumn(:final name) => name,
    DbAggregate(:final resultColumn) => resultColumn.name,
    _ => throw StateError('Unsupported grouped expression'),
  };
}

/// A grouped projection decoded into application-specific values.
final class DbDecodedGroupedSelection<Row, Key, Result> {
  const DbDecodedGroupedSelection._(this._selection, this._decode);

  final DbGroupedSelection<Row, Key> _selection;
  final Result Function(DbRow row) _decode;

  Future<List<Result>> get() async =>
      (await _selection.get()).map(_decode).toList(growable: false);

  Stream<List<Result>> watch() => _selection.watch().map(
    (rows) => rows.map(_decode).toList(growable: false),
  );
}
