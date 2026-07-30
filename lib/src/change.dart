import 'table.dart';

/// The category of a recorded table mutation.
enum DbChangeKind { insert, update, delete, raw }

/// Aggregated mutation information for one table.
final class DbTableChange {
  const DbTableChange({
    required this.table,
    required this.kinds,
    required this.keys,
  });

  final DbTableId table;
  final Set<DbChangeKind> kinds;
  final Set<Object?>? keys;

  /// Whether the affected primary keys could not be determined.
  bool get affectsUnknownKeys => keys == null;
}

/// An immutable collection of mutations committed together.
final class DbChangeSet {
  const DbChangeSet._(this._changes);

  final Map<DbTableId, DbTableChange> _changes;

  Iterable<DbTableChange> get changes => _changes.values;

  bool get isEmpty => _changes.isEmpty;

  bool get isNotEmpty => _changes.isNotEmpty;

  /// Whether any table in [tables] changed.
  bool affects(Iterable<DbTableId> tables) {
    for (final table in tables) {
      if (_changes.containsKey(table)) {
        return true;
      }
    }
    return false;
  }

  DbTableChange? operator [](DbTableId table) => _changes[table];
}

/// Collects and merges changes before publication.
final class DbChangeAccumulator {
  final Map<DbTableId, DbTableChange> _changes = <DbTableId, DbTableChange>{};

  bool get isEmpty => _changes.isEmpty;

  bool get isNotEmpty => _changes.isNotEmpty;

  /// Records a change, optionally limited to [keys].
  void add(DbTableId table, DbChangeKind kind, {Iterable<Object?>? keys}) {
    final previous = _changes[table];
    final nextKinds = <DbChangeKind>{
      if (previous != null) ...previous.kinds,
      kind,
    };
    final nextKeys = _mergeKeys(previous, keys);
    _changes[table] = DbTableChange(
      table: table,
      kinds: Set.unmodifiable(nextKinds),
      keys: nextKeys == null ? null : Set.unmodifiable(nextKeys),
    );
  }

  /// Merges all changes from [other].
  void addAll(DbChangeAccumulator other) {
    for (final change in other._changes.values) {
      for (final kind in change.kinds) {
        add(change.table, kind, keys: change.keys);
      }
    }
  }

  /// Freezes the accumulated changes.
  DbChangeSet toChangeSet() => DbChangeSet._(Map.unmodifiable(_changes));

  Set<Object?>? _mergeKeys(DbTableChange? previous, Iterable<Object?>? next) {
    if (previous == null) {
      return next == null ? null : <Object?>{...next};
    }
    if (previous.keys == null || next == null) {
      return null;
    }
    return <Object?>{...previous.keys!, ...next};
  }
}
