import 'dart:convert';
import 'dart:typed_data';

import '../internal/sql.dart';
import 'codec.dart';
import 'expression.dart';

/// Converts a Dart object into a JSON-compatible value.
typedef JsonEncoder<T> = Object? Function(T value);

/// Converts a decoded JSON value into a Dart object.
typedef JsonDecoder<T> = T Function(Object? value);

/// The non-generic column interface used by [DbValues].
abstract interface class AnyDbColumn {
  /// The SQL column name.
  String get name;

  /// Expected SQLite type affinity, when known.
  String? get affinity;

  /// Whether the mapped Dart type accepts a SQLite `NULL` value.
  bool get acceptsNull;

  /// Encodes a dynamically typed value.
  Object? encodeAny(Object? value);
}

/// A named SQLite column storing values of type [T].
final class DbColumn<T> implements AnyDbColumn {
  /// Creates a column backed by [codec].
  const DbColumn(this.name, {required DbCodec<T> codec, this.affinity})
    : _codec = codec;

  @override
  final String name;
  @override
  final String? affinity;

  @override
  bool get acceptsNull => null is T;
  final DbCodec<T> _codec;

  /// The safely quoted SQL identifier.
  String get sql => quoteIdentifier(name);

  /// Creates a statically checked assignment for DbValues.fromAssignments.
  DbAssignment<T> set(T value) => DbAssignment._(this, value);

  /// Encodes [value] for SQLite.
  Object? encode(T value) => _codec.encode(value);

  @override
  Object? encodeAny(Object? value) => encode(value as T);

  /// Decodes a stored [value].
  T decode(Object? value) => _codec.decode(value);

  /// Creates an equality predicate, including correct null semantics.
  DbPredicate equals(T value) {
    if (value == null) {
      return isNull();
    }
    return DbPredicate('$sql = ?', [encode(value)]);
  }

  /// Creates an inequality predicate, including correct null semantics.
  DbPredicate notEquals(T value) {
    if (value == null) {
      return isNotNull();
    }
    return DbPredicate('$sql <> ?', [encode(value)]);
  }

  /// Tests for SQL `NULL`.
  DbPredicate isNull() => DbPredicate('$sql IS NULL');

  /// Tests for a non-null SQL value.
  DbPredicate isNotNull() => DbPredicate('$sql IS NOT NULL');

  /// Tests membership in [values], including null-safe behavior.
  DbPredicate inValues(Iterable<T> values) {
    final materialized = values.toList(growable: false);
    final includesNull = materialized.any((value) => value == null);
    final encoded = materialized
        .where((value) => value != null)
        .map(encode)
        .toList(growable: false);
    if (encoded.isEmpty) {
      return includesNull ? isNull() : DbPredicate.never;
    }
    final predicate = DbPredicate(
      '$sql IN (${List.filled(encoded.length, '?').join(', ')})',
      encoded,
    );
    return includesNull ? predicate.or(isNull()) : predicate;
  }

  /// Tests exclusion from [values], including null-safe behavior.
  DbPredicate notInValues(Iterable<T> values) {
    final materialized = values.toList(growable: false);
    final includesNull = materialized.any((value) => value == null);
    final encoded = materialized
        .where((value) => value != null)
        .map(encode)
        .toList(growable: false);
    if (encoded.isEmpty) {
      return includesNull ? isNotNull() : DbPredicate.always;
    }
    final predicate = DbPredicate(
      '$sql NOT IN (${List.filled(encoded.length, '?').join(', ')})',
      encoded,
    );
    return includesNull ? predicate.and(isNotNull()) : predicate;
  }

  /// Orders this column from smallest to largest.
  DbOrdering ascending({String? collation, bool? nullsFirst}) =>
      DbOrdering('$sql${_collationSql(collation)} ASC${_nullsSql(nullsFirst)}');

  /// Orders this column from largest to smallest.
  DbOrdering descending({String? collation, bool? nullsFirst}) => DbOrdering(
    '$sql${_collationSql(collation)} DESC${_nullsSql(nullsFirst)}',
  );

  @override
  String toString() => 'DbColumn<$T>($name)';
}

/// A non-nullable column with range comparison predicates.
final class ComparableDbColumn<T> extends DbColumn<T> {
  const ComparableDbColumn(super.name, {required super.codec, super.affinity});

  DbPredicate greaterThan(T value) => DbPredicate('$sql > ?', [encode(value)]);

  DbPredicate greaterThanOrEquals(T value) =>
      DbPredicate('$sql >= ?', [encode(value)]);

  DbPredicate lessThan(T value) => DbPredicate('$sql < ?', [encode(value)]);

  DbPredicate lessThanOrEquals(T value) =>
      DbPredicate('$sql <= ?', [encode(value)]);

  DbPredicate between(T lower, T upper) {
    return DbPredicate('$sql BETWEEN ? AND ?', [encode(lower), encode(upper)]);
  }
}

/// A nullable column with range comparison predicates for non-null values.
final class NullableComparableDbColumn<T> extends DbColumn<T?> {
  const NullableComparableDbColumn(
    super.name, {
    required super.codec,
    super.affinity,
  });

  DbPredicate greaterThan(T value) => DbPredicate('$sql > ?', [encode(value)]);

  DbPredicate greaterThanOrEquals(T value) =>
      DbPredicate('$sql >= ?', [encode(value)]);

  DbPredicate lessThan(T value) => DbPredicate('$sql < ?', [encode(value)]);

  DbPredicate lessThanOrEquals(T value) =>
      DbPredicate('$sql <= ?', [encode(value)]);

  DbPredicate between(T lower, T upper) {
    return DbPredicate('$sql BETWEEN ? AND ?', [encode(lower), encode(upper)]);
  }
}

/// A text column with SQLite pattern-matching predicates.
final class TextDbColumn extends DbColumn<String> {
  const TextDbColumn(super.name, {required super.codec, super.affinity});

  /// Matches a SQL `LIKE` pattern. Wildcards in [pattern] are preserved.
  DbPredicate like(String pattern, {bool caseSensitive = false}) {
    if (caseSensitive) {
      return DbPredicate('$sql GLOB ?', [_toGlobPattern(pattern)]);
    }
    return DbPredicate("$sql LIKE ? ESCAPE '\\' COLLATE NOCASE", [pattern]);
  }

  DbPredicate contains(String value, {bool caseSensitive = false}) =>
      like('%${_escapeLike(value)}%', caseSensitive: caseSensitive);

  DbPredicate startsWith(String value, {bool caseSensitive = false}) =>
      like('${_escapeLike(value)}%', caseSensitive: caseSensitive);

  DbPredicate endsWith(String value, {bool caseSensitive = false}) =>
      like('%${_escapeLike(value)}', caseSensitive: caseSensitive);

  /// Uses SQLite FTS `MATCH` syntax for a virtual-table column.
  DbPredicate matches(String query) => DbPredicate('$sql MATCH ?', [query]);
}

String _collationSql(String? collation) {
  if (collation == null) return '';
  final normalized = collation.trim().toUpperCase();
  const supported = {'BINARY', 'NOCASE', 'RTRIM'};
  if (!supported.contains(normalized)) {
    throw ArgumentError.value(collation, 'collation', 'Unsupported collation');
  }
  return ' COLLATE $normalized';
}

String _nullsSql(bool? nullsFirst) => switch (nullsFirst) {
  true => ' NULLS FIRST',
  false => ' NULLS LAST',
  null => '',
};

/// JSON1 predicates for JSON text columns.
extension DbJsonPredicates on DbColumn<Object?> {
  DbPredicate jsonEquals(String path, Object? value) {
    return DbPredicate('json_extract($sql, ?) IS ?', [path, value]);
  }

  DbPredicate jsonTypeIs(String path, String type) {
    return DbPredicate('json_type($sql, ?) = ?', [path, type]);
  }

  DbPredicate jsonArrayContains(String path, Object? value) {
    return DbPredicate(
      'EXISTS (SELECT 1 FROM json_each($sql, ?) WHERE value IS ?)',
      [path, value],
    );
  }
}

/// A nullable text column with SQLite pattern-matching predicates.
final class NullableTextDbColumn extends DbColumn<String?> {
  const NullableTextDbColumn(
    super.name, {
    required super.codec,
    super.affinity,
  });

  DbPredicate like(String pattern, {bool caseSensitive = false}) {
    if (caseSensitive) {
      return DbPredicate('$sql GLOB ?', [_toGlobPattern(pattern)]);
    }
    return DbPredicate("$sql LIKE ? ESCAPE '\\' COLLATE NOCASE", [pattern]);
  }

  DbPredicate contains(String value, {bool caseSensitive = false}) =>
      like('%${_escapeLike(value)}%', caseSensitive: caseSensitive);

  DbPredicate startsWith(String value, {bool caseSensitive = false}) =>
      like('${_escapeLike(value)}%', caseSensitive: caseSensitive);

  DbPredicate endsWith(String value, {bool caseSensitive = false}) =>
      like('%${_escapeLike(value)}', caseSensitive: caseSensitive);

  DbPredicate matches(String query) => DbPredicate('$sql MATCH ?', [query]);

  DbPredicate greaterThan(String value) =>
      DbPredicate('$sql > ?', [encode(value)]);

  DbPredicate greaterThanOrEquals(String value) =>
      DbPredicate('$sql >= ?', [encode(value)]);

  DbPredicate lessThan(String value) =>
      DbPredicate('$sql < ?', [encode(value)]);

  DbPredicate lessThanOrEquals(String value) =>
      DbPredicate('$sql <= ?', [encode(value)]);

  DbPredicate between(String lower, String upper) =>
      DbPredicate('$sql BETWEEN ? AND ?', [encode(lower), encode(upper)]);
}

String _escapeLike(String value) {
  return value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');
}

String _toGlobPattern(String pattern) {
  final buffer = StringBuffer();
  var escaped = false;
  for (final rune in pattern.runes) {
    final character = String.fromCharCode(rune);
    if (escaped) {
      buffer.write(switch (character) {
        '*' => '[*]',
        '?' => '[?]',
        '[' => '[[]',
        _ => character,
      });
      escaped = false;
    } else if (character == r'\') {
      escaped = true;
    } else {
      buffer.write(switch (character) {
        '%' => '*',
        '_' => '?',
        '*' => '[*]',
        '?' => '[?]',
        '[' => '[[]',
        _ => character,
      });
    }
  }
  if (escaped) buffer.write(r'\');
  return buffer.toString();
}

DbCodec<bool> _boolCodec(String name) {
  return DbCodec<bool>(
    encode: (value) => value ? 1 : 0,
    decode: (value) {
      if (value == null) {
        throw StateError('Column $name is NULL');
      }
      if (value is bool) {
        return value;
      }
      if (value is num) {
        return value != 0;
      }
      throw StateError(
        'Column $name expected bool/integer, got ${value.runtimeType}',
      );
    },
  );
}

DbCodec<DateTime> _dateTimeCodec(String name) {
  return DbCodec<DateTime>(
    encode: (value) => value.toUtc().millisecondsSinceEpoch,
    decode: (value) {
      if (value == null) {
        throw StateError('Column $name is NULL');
      }
      if (value is int) {
        return DateTime.fromMillisecondsSinceEpoch(
          value,
          isUtc: true,
        ).toLocal();
      }
      if (value is String) {
        return DateTime.parse(value).toLocal();
      }
      throw StateError(
        'Column $name expected int/string, got ${value.runtimeType}',
      );
    },
  );
}

DbCodec<double> _doubleCodec(String name) {
  return DbCodec<double>(
    encode: identityEncode<double>,
    decode: (value) {
      if (value == null) {
        throw StateError('Column $name is NULL');
      }
      if (value is num) {
        return value.toDouble();
      }
      throw StateError(
        'Column $name expected number, got ${value.runtimeType}',
      );
    },
  );
}

DbCodec<int> _intCodec(String name) {
  return DbCodec<int>(
    encode: identityEncode<int>,
    decode: (value) {
      if (value == null) {
        throw StateError('Column $name is NULL');
      }
      if (value is int) {
        return value;
      }
      throw StateError('Column $name expected int, got ${value.runtimeType}');
    },
  );
}

DbCodec<String> _stringCodec(String name) {
  return DbCodec<String>(
    encode: identityEncode<String>,
    decode: (value) {
      if (value == null) {
        throw StateError('Column $name is NULL');
      }
      if (value is String) {
        return value;
      }
      throw StateError(
        'Column $name expected String, got ${value.runtimeType}',
      );
    },
  );
}

/// Creates a non-nullable boolean column.
DbColumn<bool> boolean(String name) {
  return DbColumn<bool>(name, codec: _boolCodec(name), affinity: 'INTEGER');
}

/// Creates a nullable boolean column.
DbColumn<bool?> nullableBoolean(String name) {
  return DbColumn<bool?>(
    name,
    codec: nullableCodec(_boolCodec(name)),
    affinity: 'INTEGER',
  );
}

/// Creates a non-nullable date-time column stored as UTC milliseconds.
ComparableDbColumn<DateTime> dateTime(String name) {
  return ComparableDbColumn<DateTime>(
    name,
    codec: _dateTimeCodec(name),
    affinity: 'INTEGER',
  );
}

/// Creates a nullable date-time column stored as UTC milliseconds.
NullableComparableDbColumn<DateTime> nullableDateTime(String name) {
  return NullableComparableDbColumn<DateTime>(
    name,
    codec: nullableCodec(_dateTimeCodec(name)),
    affinity: 'INTEGER',
  );
}

/// Creates a non-nullable floating-point column.
ComparableDbColumn<double> real(String name) {
  return ComparableDbColumn<double>(
    name,
    codec: _doubleCodec(name),
    affinity: 'REAL',
  );
}

/// Creates a nullable floating-point column.
NullableComparableDbColumn<double> nullableReal(String name) {
  return NullableComparableDbColumn<double>(
    name,
    codec: nullableCodec(_doubleCodec(name)),
    affinity: 'REAL',
  );
}

/// Creates a non-nullable integer column.
ComparableDbColumn<int> integer(String name) {
  return ComparableDbColumn<int>(
    name,
    codec: _intCodec(name),
    affinity: 'INTEGER',
  );
}

/// Creates a nullable integer column.
NullableComparableDbColumn<int> nullableInteger(String name) {
  return NullableComparableDbColumn<int>(
    name,
    codec: nullableCodec(_intCodec(name)),
    affinity: 'INTEGER',
  );
}

/// Creates a column containing arbitrary JSON data encoded as text.
DbColumn<Object?> jsonValue(String name) {
  return DbColumn<Object?>(
    name,
    codec: DbCodec<Object?>(
      encode: jsonEncode,
      decode: (value) => value is String ? jsonDecode(value) : value,
    ),
    affinity: 'TEXT',
  );
}

/// Creates a nullable column containing arbitrary JSON encoded as text.
DbColumn<Object?> nullableJsonValue(String name) {
  return DbColumn<Object?>(
    name,
    codec: DbCodec<Object?>(
      encode: (value) => value == null ? null : jsonEncode(value),
      decode: (value) => value is String ? jsonDecode(value) : value,
    ),
    affinity: 'TEXT',
  );
}

/// Creates a typed JSON column encoded as text.
DbColumn<T> json<T>(
  String name, {
  required JsonEncoder<T> encode,
  required JsonDecoder<T> decode,
}) {
  return DbColumn<T>(
    name,
    codec: DbCodec<T>(
      encode: (value) => jsonEncode(encode(value)),
      decode: (value) => decode(jsonDecode(value! as String)),
    ),
    affinity: 'TEXT',
  );
}

/// Creates a binary SQLite BLOB column.
DbColumn<Uint8List> blob(String name) {
  return DbColumn<Uint8List>(
    name,
    codec: DbCodec<Uint8List>(
      encode: identityEncode<Uint8List>,
      decode: (value) {
        if (value is Uint8List) return value;
        if (value is List<int>) return Uint8List.fromList(value);
        throw StateError('Column $name expected binary data');
      },
    ),
    affinity: 'BLOB',
  );
}

/// Creates a nullable binary SQLite BLOB column.
DbColumn<Uint8List?> nullableBlob(String name) {
  return DbColumn<Uint8List?>(
    name,
    codec: nullableCodec(blob(name)._codec),
    affinity: 'BLOB',
  );
}

/// Creates a non-nullable text column.
TextDbColumn text(String name) {
  return TextDbColumn(name, codec: _stringCodec(name), affinity: 'TEXT');
}

/// Creates a nullable text column.
NullableTextDbColumn nullableText(String name) {
  return NullableTextDbColumn(
    name,
    codec: nullableCodec(_stringCodec(name)),
    affinity: 'TEXT',
  );
}

/// An encoded assignment produced by a typed column.
abstract interface class AnyDbAssignment {
  String get columnName;
  Object? get encodedValue;
}

/// An immutable assignment whose value is checked against its column type.
final class DbAssignment<T> implements AnyDbAssignment {
  DbAssignment._(DbColumn<T> column, T value)
    : columnName = column.name,
      encodedValue = column.encode(value);

  @override
  final String columnName;
  @override
  final Object? encodedValue;
}
