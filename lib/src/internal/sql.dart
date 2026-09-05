final _identifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

String quoteIdentifier(String identifier) {
  if (!_identifierPattern.hasMatch(identifier)) {
    throw ArgumentError.value(
      identifier,
      'identifier',
      'Invalid SQL identifier',
    );
  }
  return '"$identifier"';
}

String? joinSql(Iterable<String> parts, String separator) {
  final filtered = parts
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (filtered.isEmpty) {
    return null;
  }
  return filtered.join(separator);
}

/// SQLite requires a LIMIT clause whenever OFFSET is present.
String paginationSql(int? limit, int? offset) =>
    '${limit != null
        ? ' LIMIT $limit'
        : offset != null
        ? ' LIMIT -1'
        : ''}'
    '${offset != null ? ' OFFSET $offset' : ''}';

String collationSql(String? collation) {
  if (collation == null) return '';
  final normalized = collation.trim().toUpperCase();
  const supported = {'BINARY', 'NOCASE', 'RTRIM'};
  if (!supported.contains(normalized)) {
    throw ArgumentError.value(collation, 'collation', 'Unsupported collation');
  }
  return ' COLLATE $normalized';
}

String nullOrderingSql(bool? nullsFirst) => switch (nullsFirst) {
  true => ' NULLS FIRST',
  false => ' NULLS LAST',
  null => '',
};

int firstLimit(int? limit) => limit == 0 ? 0 : 1;
