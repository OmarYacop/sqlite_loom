/// A parameterized SQL boolean expression.
final class DbPredicate {
  /// Creates a developer-authored SQL fragment with bound [arguments].
  ///
  /// Prefer [DbPredicate.trusted] at application trust boundaries. Never place
  /// user-controlled values in [sql]; pass them through [arguments].
  DbPredicate(this.sql, [List<Object?> arguments = const []])
    : arguments = List.unmodifiable(arguments);

  /// Explicitly creates a trusted SQL fragment with bound [arguments].
  factory DbPredicate.trusted(
    String sql, [
    List<Object?> arguments = const [],
  ]) => DbPredicate(sql, arguments);

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
  /// Creates a developer-authored ordering from [sql].
  ///
  /// Prefer [DbOrdering.trusted] at application trust boundaries. Never place
  /// user-controlled values in this SQL fragment.
  const DbOrdering(this.sql);

  /// Explicitly creates a trusted ordering SQL fragment.
  const DbOrdering.trusted(String sql) : this(sql);

  /// The SQL used in an `ORDER BY` clause.
  final String sql;

  @override
  String toString() => sql;
}
