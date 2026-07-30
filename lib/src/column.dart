import 'codec.dart';
import 'expression.dart';
import 'internal/sql.dart';

/// Converts a Dart object into a JSON-compatible value.
typedef JsonEncoder<T> = Object? Function(T value);

/// Converts a decoded JSON value into a Dart object.
typedef JsonDecoder<T> = T Function(Object? value);

/// The non-generic column interface used by [DbValues].
abstract interface class AnyDbColumn {
  /// The SQL column name.
  String get name;

  /// Encodes a dynamically typed value.
  Object? encodeAny(Object? value);
}

/// A named SQLite column storing values of type [T].
final class DbColumn<T> implements AnyDbColumn {
  /// Creates a column backed by [codec].
  const DbColumn(this.name, {required DbCodec<T> codec}) : _codec = codec;

  @override
  final String name;
  final DbCodec<T> _codec;

  /// The safely quoted SQL identifier.
  String get sql => quoteIdentifier(name);

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
  DbOrdering ascending() => DbOrdering('$sql ASC');

  /// Orders this column from largest to smallest.
  DbOrdering descending() => DbOrdering('$sql DESC');

  @override
  String toString() => 'DbColumn<$T>($name)';
}

/// A non-nullable column with range comparison predicates.
final class ComparableDbColumn<T> extends DbColumn<T> {
  const ComparableDbColumn(super.name, {required super.codec});

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
  const NullableComparableDbColumn(super.name, {required super.codec});

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
  return DbColumn<bool>(name, codec: _boolCodec(name));
}

/// Creates a nullable boolean column.
DbColumn<bool?> nullableBoolean(String name) {
  return DbColumn<bool?>(name, codec: nullableCodec(_boolCodec(name)));
}

/// Creates a non-nullable date-time column stored as UTC milliseconds.
ComparableDbColumn<DateTime> dateTime(String name) {
  return ComparableDbColumn<DateTime>(name, codec: _dateTimeCodec(name));
}

/// Creates a nullable date-time column stored as UTC milliseconds.
NullableComparableDbColumn<DateTime> nullableDateTime(String name) {
  return NullableComparableDbColumn<DateTime>(
    name,
    codec: nullableCodec(_dateTimeCodec(name)),
  );
}

/// Creates a non-nullable floating-point column.
ComparableDbColumn<double> real(String name) {
  return ComparableDbColumn<double>(name, codec: _doubleCodec(name));
}

/// Creates a nullable floating-point column.
NullableComparableDbColumn<double> nullableReal(String name) {
  return NullableComparableDbColumn<double>(
    name,
    codec: nullableCodec(_doubleCodec(name)),
  );
}

/// Creates a non-nullable integer column.
ComparableDbColumn<int> integer(String name) {
  return ComparableDbColumn<int>(name, codec: _intCodec(name));
}

/// Creates a nullable integer column.
NullableComparableDbColumn<int> nullableInteger(String name) {
  return NullableComparableDbColumn<int>(
    name,
    codec: nullableCodec(_intCodec(name)),
  );
}

/// Creates a column containing arbitrary JSON data encoded as text.
DbColumn<Object?> jsonValue(String name) {
  return DbColumn<Object?>(
    name,
    codec: DbCodec<Object?>(
      encode: identityEncode<Object?>,
      decode: (value) => value,
    ),
  );
}

/// Creates a non-nullable text column.
DbColumn<String> text(String name) {
  return DbColumn<String>(name, codec: _stringCodec(name));
}

/// Creates a nullable text column.
DbColumn<String?> nullableText(String name) {
  return DbColumn<String?>(name, codec: nullableCodec(_stringCodec(name)));
}
