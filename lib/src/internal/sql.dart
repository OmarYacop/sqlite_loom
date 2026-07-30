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
