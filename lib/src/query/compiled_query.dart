part of 'query.dart';

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
