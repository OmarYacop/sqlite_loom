/// A parameterized SQL boolean expression.
final class DbPredicate {
  /// Creates a trusted SQL fragment with bound [arguments].
  DbPredicate(this.sql, [List<Object?> arguments = const []])
    : arguments = List.unmodifiable(arguments);

  /// A predicate that matches every row.
  static final always = DbPredicate('1 = 1');

  /// A predicate that matches no rows.
  static final never = DbPredicate('1 = 0');

  /// The trusted SQL fragment containing placeholders.
  final String sql;

  /// Values bound to placeholders in [sql].
  final List<Object?> arguments;

  /// Combines this predicate and [other] with `AND`.
  DbPredicate and(DbPredicate other) => _combine('AND', other);

  /// Combines this predicate and [other] with `OR`.
  DbPredicate or(DbPredicate other) => _combine('OR', other);

  /// Negates this predicate.
  DbPredicate not() => DbPredicate('NOT ($sql)', arguments);

  DbPredicate operator &(DbPredicate other) => and(other);

  DbPredicate operator |(DbPredicate other) => or(other);

  DbPredicate operator ~() => not();

  DbPredicate _combine(String operator, DbPredicate other) {
    return DbPredicate('($sql) $operator (${other.sql})', [
      ...arguments,
      ...other.arguments,
    ]);
  }

  @override
  String toString() => sql;
}

/// A trusted SQL ordering expression.
final class DbOrdering {
  /// Creates an ordering from [sql].
  const DbOrdering(this.sql);

  /// The SQL used in an `ORDER BY` clause.
  final String sql;

  @override
  String toString() => sql;
}
