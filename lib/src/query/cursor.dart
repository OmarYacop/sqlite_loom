import '../model/column.dart';
import '../model/expression.dart';
import '../model/row.dart';

/// One non-null component of a lexicographic cursor order.
abstract interface class AnyDbCursorColumn {
  String get name;
  DbOrdering get ordering;
  AnyDbCursorValue read(DbRow row);
}

/// A typed cursor column. The final column in an order must break every tie.
final class DbCursorColumn<T> implements AnyDbCursorColumn {
  DbCursorColumn(this.column, {this.descending = false}) {
    if (column.acceptsNull) {
      throw ArgumentError('Cursor columns must be non-nullable');
    }
  }

  final DbColumn<T> column;
  final bool descending;

  @override
  String get name => column.name;

  @override
  DbOrdering get ordering =>
      descending ? column.descending() : column.ascending();

  /// Binds a value with this column's codec and ordering.
  DbCursorValue<T> at(T value) => DbCursorValue._(this, value);

  @override
  DbCursorValue<T> read(DbRow row) => at(row.get(column));
}

/// A bound component of a composite cursor.
abstract interface class AnyDbCursorValue {
  AnyDbCursorColumn get column;
  DbPredicate get equal;
  DbPredicate get following;
}

/// A typed, parameter-bound cursor value.
final class DbCursorValue<T> implements AnyDbCursorValue {
  DbCursorValue._(this.column, T value)
    : _encoded = column.column.encode(value) {
    if (_encoded == null) {
      throw ArgumentError('Cursor values must not encode null');
    }
  }

  @override
  final DbCursorColumn<T> column;
  final Object? _encoded;

  @override
  DbPredicate get equal => DbPredicate('${column.column.sql} = ?', [_encoded]);

  @override
  DbPredicate get following => DbPredicate(
    '${column.column.sql} ${column.descending ? '<' : '>'} ?',
    [_encoded],
  );
}

void validateCursor(List<AnyDbCursorColumn> columns) {
  if (columns.isEmpty ||
      columns.map((column) => column.name).toSet().length != columns.length) {
    throw ArgumentError('Cursor columns must be non-empty and distinct');
  }
}

DbPredicate cursorPredicate(List<AnyDbCursorValue> values) {
  validateCursor(values.map((value) => value.column).toList());
  DbPredicate? result;
  DbPredicate? prefix;
  for (final value in values) {
    final term = prefix == null ? value.following : prefix.and(value.following);
    result = result == null ? term : result.or(term);
    prefix = prefix == null ? value.equal : prefix.and(value.equal);
  }
  return result!;
}
