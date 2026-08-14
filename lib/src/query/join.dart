import '../database/database.dart';
import '../internal/sql.dart';
import '../model/codec.dart';
import '../model/column.dart';
import '../model/expression.dart';
import '../model/row.dart';
import '../model/table.dart';
import 'query.dart';

/// A qualified and optionally aliased column selected from a join.
abstract interface class AnyDbJoinColumn {
  String get resultName;
  String get selectionSql;
}

final class DbJoinColumn<T> implements AnyDbJoinColumn {
  DbJoinColumn(this.tableAlias, this.column, {String? as})
    : resultName = as ?? '${tableAlias}_${column.name}',
      resultColumn = DbColumn<T>(
        as ?? '${tableAlias}_${column.name}',
        codec: DbCodec<T>(encode: column.encode, decode: column.decode),
        affinity: column.affinity,
      );

  final String tableAlias;
  final DbColumn<T> column;
  @override
  final String resultName;
  final DbColumn<T> resultColumn;

  @override
  String get selectionSql =>
      '${quoteIdentifier(tableAlias)}.${column.sql} AS ${quoteIdentifier(resultName)}';

  String get qualifiedSql => '${quoteIdentifier(tableAlias)}.${column.sql}';

  DbPredicate equalsColumn(DbJoinColumn<T> other) {
    return DbPredicate('$qualifiedSql = ${other.qualifiedSql}');
  }

  DbPredicate equalsValue(T value) {
    return DbPredicate('$qualifiedSql = ?', [column.encode(value)]);
  }

  DbOrdering ascending({String? collation, bool? nullsFirst}) => DbOrdering(
    '$qualifiedSql${_joinCollation(collation)} ASC${_joinNulls(nullsFirst)}',
  );

  DbOrdering descending({String? collation, bool? nullsFirst}) => DbOrdering(
    '$qualifiedSql${_joinCollation(collation)} DESC${_joinNulls(nullsFirst)}',
  );
}

String _joinCollation(String? collation) {
  if (collation == null) return '';
  final normalized = collation.trim().toUpperCase();
  if (!const {'BINARY', 'NOCASE', 'RTRIM'}.contains(normalized)) {
    throw ArgumentError.value(collation, 'collation', 'Unsupported collation');
  }
  return ' COLLATE $normalized';
}

String _joinNulls(bool? nullsFirst) => switch (nullsFirst) {
  true => ' NULLS FIRST',
  false => ' NULLS LAST',
  null => '',
};

final class _DbJoinClause {
  const _DbJoinClause(this.kind, this.table, this.alias, this.on);
  final String kind;
  final DbTable<Object?, Object?> table;
  final String alias;
  final DbPredicate on;
}

/// Immutable raw-row join builder with explicit dependencies and aliases.
final class DbJoinQuery {
  const DbJoinQuery._(
    this._db,
    this._from,
    this._alias, {
    List<_DbJoinClause> joins = const [],
    List<DbPredicate> predicates = const [],
    List<DbOrdering> orderings = const [],
    int? limit,
    int? offset,
    bool distinct = false,
  }) : _joins = joins,
       _predicates = predicates,
       _orderings = orderings,
       _limit = limit,
       _offset = offset,
       _distinct = distinct;

  final SqliteLoom _db;
  final DbTable<Object?, Object?> _from;
  final String _alias;
  final List<_DbJoinClause> _joins;
  final List<DbPredicate> _predicates;
  final List<DbOrdering> _orderings;
  final int? _limit;
  final int? _offset;
  final bool _distinct;

  DbJoinQuery innerJoin(
    DbTable<Object?, Object?> table, {
    required String as,
    required DbPredicate on,
  }) => _join('INNER', table, as, on);

  DbJoinQuery leftJoin(
    DbTable<Object?, Object?> table, {
    required String as,
    required DbPredicate on,
  }) => _join('LEFT', table, as, on);

  DbJoinQuery where(DbPredicate predicate) => DbJoinQuery._(
    _db,
    _from,
    _alias,
    joins: _joins,
    predicates: [..._predicates, predicate],
    orderings: _orderings,
    limit: _limit,
    offset: _offset,
    distinct: _distinct,
  );

  DbJoinQuery orderBy(DbOrdering ordering) =>
      _copyWith(orderings: [..._orderings, ordering]);

  DbJoinQuery limit(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'Limit must not be negative');
    }
    return _copyWith(limit: value);
  }

  DbJoinQuery offset(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'Offset must not be negative');
    }
    return _copyWith(offset: value);
  }

  DbJoinQuery distinct() => _copyWith(distinct: true);

  DbJoinSelection select(Iterable<AnyDbJoinColumn> columns) {
    return DbJoinSelection._(this, columns.toList(growable: false));
  }

  DbJoinQuery _join(
    String kind,
    DbTable<Object?, Object?> table,
    String alias,
    DbPredicate on,
  ) => DbJoinQuery._(
    _db,
    _from,
    _alias,
    joins: [..._joins, _DbJoinClause(kind, table, alias, on)],
    predicates: _predicates,
    orderings: _orderings,
    limit: _limit,
    offset: _offset,
    distinct: _distinct,
  );

  DbJoinQuery _copyWith({
    List<DbOrdering>? orderings,
    int? limit,
    int? offset,
    bool? distinct,
  }) => DbJoinQuery._(
    _db,
    _from,
    _alias,
    joins: _joins,
    predicates: _predicates,
    orderings: orderings ?? _orderings,
    limit: limit ?? _limit,
    offset: offset ?? _offset,
    distinct: distinct ?? _distinct,
  );
}

/// Executable selection from a [DbJoinQuery].
final class DbJoinSelection {
  DbJoinSelection._(this._query, this.columns) {
    if (columns.isEmpty) {
      throw ArgumentError.value(columns, 'columns', 'Cannot be empty');
    }
  }

  final DbJoinQuery _query;
  final List<AnyDbJoinColumn> columns;

  /// Compiles this joined selection without executing it.
  DbCompiledJoin compile() => _compile();

  /// Returns SQLite's query plan for this joined selection.
  Future<List<DbQueryPlanRow>> explain() async {
    final compiled = _compile();
    final rows = await _query._db.rawRead(
      'EXPLAIN QUERY PLAN ${compiled.sql}',
      arguments: compiled.arguments,
    );
    return rows.map(DbQueryPlanRow.fromMap).toList(growable: false);
  }

  Future<List<DbRow>> get() {
    final compiled = _compile();
    return _query._db
        .rawRead(compiled.sql, arguments: compiled.arguments)
        .then((rows) => rows.map(DbRow.new).toList(growable: false));
  }

  Future<DbRow> first() async {
    final row = await firstOrNull();
    if (row == null) throw StateError('No joined row found');
    return row;
  }

  Future<DbRow?> firstOrNull() async {
    final selection = DbJoinSelection._(_query.limit(1), columns);
    final rows = await selection.get();
    return rows.firstOrNull;
  }

  Future<int> count() async {
    final compiled = _compile(includeOrder: false, includePagination: false);
    final rows = await _query._db.rawRead(
      'SELECT COUNT(*) AS count FROM (${compiled.sql}) AS _loom_join',
      arguments: compiled.arguments,
    );
    return rows.single['count']! as int;
  }

  Future<bool> exists() async => await count() > 0;

  DbDecodedJoinSelection<Result> decodeWith<Result>(
    Result Function(DbRow row) decode,
  ) => DbDecodedJoinSelection._(this, decode);

  Stream<List<DbRow>> watch() {
    final compiled = _compile();
    return _query._db
        .watchRaw(
          compiled.sql,
          arguments: compiled.arguments,
          dependsOn: {
            _query._from.tableId,
            for (final join in _query._joins) join.table.tableId,
          },
        )
        .map((rows) => rows.map(DbRow.new).toList(growable: false));
  }

  Stream<DbRow?> watchFirstOrNull() {
    final selection = DbJoinSelection._(_query.limit(1), columns);
    return selection.watch().map((rows) => rows.firstOrNull);
  }

  DbCompiledJoin _compile({
    bool includeOrder = true,
    bool includePagination = true,
  }) {
    final sql = StringBuffer(
      'SELECT ${_query._distinct ? 'DISTINCT ' : ''}'
      '${columns.map((column) => column.selectionSql).join(', ')} '
      'FROM ${quoteIdentifier(_query._from.tableName)} '
      'AS ${quoteIdentifier(_query._alias)}',
    );
    final arguments = <Object?>[];
    for (final join in _query._joins) {
      sql.write(
        ' ${join.kind} JOIN ${quoteIdentifier(join.table.tableName)} '
        'AS ${quoteIdentifier(join.alias)} ON ${join.on.sql}',
      );
      arguments.addAll(join.on.arguments);
    }
    if (_query._predicates.isNotEmpty) {
      final where = _query._predicates.reduce((a, b) => a.and(b));
      sql.write(' WHERE ${where.sql}');
      arguments.addAll(where.arguments);
    }
    if (includeOrder && _query._orderings.isNotEmpty) {
      sql.write(
        ' ORDER BY ${_query._orderings.map((ordering) => ordering.sql).join(', ')}',
      );
    }
    if (includePagination) {
      if (_query._limit != null) {
        sql.write(' LIMIT ${_query._limit}');
      } else if (_query._offset != null) {
        sql.write(' LIMIT -1');
      }
      if (_query._offset != null) sql.write(' OFFSET ${_query._offset}');
    }
    return DbCompiledJoin(sql.toString(), List.unmodifiable(arguments));
  }
}

/// A joined projection decoded into application-specific result values.
final class DbDecodedJoinSelection<Result> {
  const DbDecodedJoinSelection._(this._selection, this._decode);

  final DbJoinSelection _selection;
  final Result Function(DbRow row) _decode;

  Future<List<Result>> get() async =>
      (await _selection.get()).map(_decode).toList(growable: false);

  Future<Result> first() async => _decode(await _selection.first());

  Future<Result?> firstOrNull() async {
    final row = await _selection.firstOrNull();
    return row == null ? null : _decode(row);
  }

  Stream<List<Result>> watch() => _selection.watch().map(
    (rows) => rows.map(_decode).toList(growable: false),
  );

  Stream<Result?> watchFirstOrNull() => _selection.watchFirstOrNull().map(
    (row) => row == null ? null : _decode(row),
  );
}

final class DbCompiledJoin {
  const DbCompiledJoin(this.sql, this.arguments);
  final String sql;
  final List<Object?> arguments;
}

extension SqliteLoomJoins on SqliteLoom {
  DbJoinQuery joinFrom(DbTable<Object?, Object?> table, {required String as}) =>
      DbJoinQuery._(this, table, as);
}
