/// Converts a Dart value into a SQLite-compatible value.
typedef DbValueEncoder<T> = Object? Function(T value);

/// Converts a SQLite value into a Dart value.
typedef DbValueDecoder<T> = T Function(Object? value);

/// Defines the bidirectional storage representation for a column type.
final class DbCodec<T> {
  /// Creates a codec from its [encode] and [decode] functions.
  const DbCodec({required this.encode, required this.decode});

  /// Encodes a Dart value.
  final DbValueEncoder<T> encode;

  /// Decodes a stored value.
  final DbValueDecoder<T> decode;
}

/// Returns [value] unchanged.
Object? identityEncode<T>(T value) => value;

/// Adapts a non-nullable [codec] to accept and return null.
DbCodec<T?> nullableCodec<T>(DbCodec<T> codec) {
  return DbCodec<T?>(
    encode: (value) => value == null ? null : codec.encode(value),
    decode: (value) => value == null ? null : codec.decode(value),
  );
}
