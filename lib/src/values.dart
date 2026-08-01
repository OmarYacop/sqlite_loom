import 'column.dart';

/// An immutable map of encoded column values for inserts and updates.
final class DbValues {
  /// Encodes each value with its associated typed column.
  DbValues(Map<AnyDbColumn, Object?> values)
    : _values = Map.unmodifiable(
        values.map(
          (column, value) => MapEntry(column.name, column.encodeAny(value)),
        ),
      );

  /// Wraps already encoded values.
  ///
  /// Prefer the typed constructor at normal application boundaries.
  DbValues.raw(Map<String, Object?> values)
    : _values = Map.unmodifiable(values);

  final Map<String, Object?> _values;

  /// The encoded map accepted by `sqflite_common`.
  Map<String, Object?> get asMap => _values;

  /// Whether this value set contains no columns.
  bool get isEmpty => _values.isEmpty;

  /// Whether this value set contains at least one column.
  bool get isNotEmpty => _values.isNotEmpty;

  @override
  String toString() => 'DbValues(columns: ${_values.keys.toList()})';
}
