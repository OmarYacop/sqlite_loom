/// Value equality for SQLite projections, including decoded JSON and BLOBs.
/// Domain model equality remains controlled by DbTable.equals.
bool dbValueEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (!dbValueEquals(left[i], right[i])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final key in left.keys) {
      if (!right.containsKey(key) || !dbValueEquals(left[key], right[key])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}
