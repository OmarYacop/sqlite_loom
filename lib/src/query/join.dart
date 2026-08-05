import '../database/database.dart';
import '../internal/sql.dart';
import '../model/codec.dart';
import '../model/column.dart';
import '../model/expression.dart';
import '../model/row.dart';
import '../model/table.dart';

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
}

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
  }) : _joins = joins,
       _predicates = predicates;

  final SqliteLoom _db;
  final DbTable<Object?, Object?> _from;
  final String _alias;
  final List<_DbJoinClause> _joins;
  final List<DbPredicate> _predicates;

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
  );

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

  Future<List<DbRow>> get() {
    final compiled = _compile();
    return _query._db
        .rawRead(compiled.sql, arguments: compiled.arguments)
        .then((rows) => rows.map(DbRow.new).toList(growable: false));
  }

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

  DbCompiledJoin _compile() {
    final sql = StringBuffer(
      'SELECT ${columns.map((column) => column.selectionSql).join(', ')} '
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
    return DbCompiledJoin(sql.toString(), List.unmodifiable(arguments));
  }
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
