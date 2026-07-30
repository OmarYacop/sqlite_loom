import 'column.dart';

/// A typed view over one SQLite result row.
final class DbRow {
  /// Wraps raw SQLite column values.
  const DbRow(this._values);

  final Map<String, Object?> _values;

  /// Decodes the value for [column].
  T get<T>(DbColumn<T> column) => column.decode(_values[column.name]);

  /// Returns null for a SQL `NULL`, otherwise decodes [column].
  T? getOrNull<T>(DbColumn<T> column) {
    final value = _values[column.name];
    if (value == null) {
      return null;
    }
    return column.decode(value);
  }

  /// Returns an undecoded value by column name.
  Object? raw(String column) => _values[column];

  /// Returns an unmodifiable raw-value map.
  Map<String, Object?> get asMap => Map.unmodifiable(_values);
}
