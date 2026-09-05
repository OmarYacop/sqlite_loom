import '../model/column.dart';
import '../model/expression.dart';
import '../model/row.dart';
import '../model/table.dart';
import '../database/session.dart';
import '../internal/sql.dart';
import 'query.dart';

/// Transforms a relationship query before it is executed or watched.
typedef DbRelationshipQuery<Row, Key> =
    DbTableQuery<Row, Key> Function(DbTableQuery<Row, Key> query);

/// A one-to-many relationship described by a child foreign-key column.
///
/// Relationship descriptors are immutable and do not own a database. Keep
/// them next to table declarations and pass the active [SqliteLoom] when
/// loading related rows.
final class DbHasMany<Parent, ParentKey, Child, ChildKey> {
  const DbHasMany({
    required this.parent,
    required this.children,
    required this.foreignKey,
    required this.foreignKeyOf,
  });

  final DbTable<Parent, ParentKey> parent;
  final DbTable<Child, ChildKey> children;
  final AnyDbColumn foreignKey;
  final ParentKey Function(Child child) foreignKeyOf;

  /// Builds the child query for one [parentRow].
  DbTableQuery<Child, ChildKey> query(DbSession db, Parent parentRow) {
    return db
        .table(children)
        .where(_foreignKeyEquals(foreignKey, parent.keyOf(parentRow)));
  }

  /// Builds one child query covering every supplied parent key.
  DbTableQuery<Child, ChildKey> queryKeys(
    DbSession db,
    Iterable<ParentKey> parentKeys,
  ) {
    final keys = parentKeys.toSet();
    return db
        .table(children)
        .where(
          keys.isEmpty ? DbPredicate.never : _foreignKeyIn(foreignKey, keys),
        );
  }

  /// Loads children belonging to one [parentRow].
  Future<List<Child>> load(
    DbSession db,
    Parent parentRow, {
    DbRelationshipQuery<Child, ChildKey>? transform,
  }) {
    final base = query(db, parentRow);
    return (transform?.call(base) ?? base).get();
  }

  /// Loads all children in one query and groups them by parent key.
  Future<Map<ParentKey, List<Child>>> loadAll(
    DbSession db,
    Iterable<Parent> parentRows, {
    DbRelationshipQuery<Child, ChildKey>? transform,
  }) async {
    final keys = parentRows.map(parent.keyOf).toSet();
    if (keys.isEmpty) return const {};
    final base = queryKeys(db, keys);
    final rows = await (transform?.call(base) ?? base).get();
    return _group(keys, rows);
  }

  /// Loads large parent sets in bind-limit-safe chunks and merges the groups.
  ///
  /// Use this when the number of parent keys may exceed the SQLite runtime's
  /// variable limit. [batchSize] is deliberately conservative by default for
  /// older mobile SQLite builds.
  Future<Map<ParentKey, List<Child>>> loadAllBatched(
    DbSession db,
    Iterable<Parent> parentRows, {
    DbRelationshipQuery<Child, ChildKey>? transform,
    int batchSize = 400,
  }) async {
    if (batchSize < 1) {
      throw ArgumentError.value(batchSize, 'batchSize', 'Must be positive');
    }
    final rowsByKey = <ParentKey, Parent>{};
    for (final row in parentRows) {
      rowsByKey[parent.keyOf(row)] = row;
    }
    final grouped = <ParentKey, List<Child>>{
      for (final key in rowsByKey.keys) key: <Child>[],
    };
    final rows = rowsByKey.values.toList(growable: false);
    for (var start = 0; start < rows.length; start += batchSize) {
      final end = _batchEnd(start, batchSize, rows.length);
      final batch = await loadAll(
        db,
        rows.sublist(start, end),
        transform: transform,
      );
      for (final entry in batch.entries) {
        grouped[entry.key]!.addAll(entry.value);
      }
    }
    return _freezeGroups(grouped);
  }

  /// Loads a separately filtered, ordered, and limited child page per parent.
  ///
  /// Unlike applying `limit()` through [transform] to [loadAll], [limit]
  /// applies independently to every parent. Loom compiles the portable
  /// compound query internally so application repositories remain typed.
  Future<Map<ParentKey, List<Child>>> loadAllLimited(
    DbSession db,
    Iterable<Parent> parentRows, {
    required int limit,
    DbRelationshipQuery<Child, ChildKey>? transform,
    int batchSize = 100,
  }) async {
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'Must be positive');
    }
    if (batchSize < 1) {
      throw ArgumentError.value(batchSize, 'batchSize', 'Must be positive');
    }
    final rowsByKey = <ParentKey, Parent>{};
    for (final row in parentRows) {
      rowsByKey[parent.keyOf(row)] = row;
    }
    final grouped = <ParentKey, List<Child>>{
      for (final key in rowsByKey.keys) key: <Child>[],
    };
    final rows = rowsByKey.values.toList(growable: false);
    for (var start = 0; start < rows.length; start += batchSize) {
      final end = _batchEnd(start, batchSize, rows.length);
      final compiled = <DbCompiledQuery>[];
      for (final parentRow in rows.sublist(start, end)) {
        final base = query(db, parentRow);
        final transformed = transform?.call(base) ?? base;
        compiled.add(transformed.limit(limit).compile());
      }
      final sql = compiled
          .map((query) => 'SELECT * FROM (${query.sql})')
          .join(' UNION ALL ');
      final arguments = [for (final query in compiled) ...query.arguments];
      final maps = await db.rawRead(sql, arguments: arguments);
      for (final map in maps) {
        final child = children.decode(DbRow(map));
        final key = foreignKeyOf(child);
        final bucket = grouped[key];
        if (bucket != null) bucket.add(child);
      }
    }
    return _freezeGroups(grouped);
  }

  /// Watches children belonging to one [parentRow].
  Stream<List<Child>> watch(
    DbSession db,
    Parent parentRow, {
    DbRelationshipQuery<Child, ChildKey>? transform,
  }) {
    final base = query(db, parentRow);
    return (transform?.call(base) ?? base).watch();
  }

  /// Watches one batched child query and groups emissions by parent key.
  Stream<Map<ParentKey, List<Child>>> watchAll(
    DbSession db,
    Iterable<Parent> parentRows, {
    DbRelationshipQuery<Child, ChildKey>? transform,
  }) {
    final keys = parentRows.map(parent.keyOf).toSet();
    final base = queryKeys(db, keys);
    return (transform?.call(base) ?? base).watch().map(
      (rows) => _group(keys, rows),
    );
  }

  Map<ParentKey, List<Child>> _group(
    Set<ParentKey> keys,
    Iterable<Child> rows,
  ) {
    final grouped = <ParentKey, List<Child>>{
      for (final key in keys) key: <Child>[],
    };
    for (final row in rows) {
      final key = foreignKeyOf(row);
      final bucket = grouped[key];
      if (bucket != null) bucket.add(row);
    }
    return _freezeGroups(grouped);
  }

  Map<ParentKey, List<Child>> _freezeGroups(
    Map<ParentKey, List<Child>> grouped,
  ) => Map.unmodifiable({
    for (final entry in grouped.entries)
      entry.key: List<Child>.unmodifiable(entry.value),
  });
}

int _batchEnd(int start, int batchSize, int length) {
  final candidate = start + batchSize;
  return candidate < length ? candidate : length;
}

enum _DbMergedCursorDirection { before, after }

/// A typed exclusive cursor boundary for a merged relationship query.
final class DbMergedCursorBound {
  const DbMergedCursorBound.before(this.value)
    : _direction = _DbMergedCursorDirection.before;

  const DbMergedCursorBound.after(this.value)
    : _direction = _DbMergedCursorDirection.after;

  final Object? value;
  final _DbMergedCursorDirection _direction;
}

/// An opaque continuation tied to its relationship instance, parent and order.
/// Obtain it from [DbMergedPage.nextCursor]; do not reuse after changing filters.
final class DbMergedContinuation {
  const DbMergedContinuation._(
    this._owner,
    this._parent,
    this._descending,
    this._value,
    this._source,
    this._key,
  );
  final Object _owner;
  final Object? _parent;
  final bool _descending;
  final Object? _value;
  final int _source;
  final Object? _key;
}

/// A merged page with a complete cursor, including ordering tie breakers.
final class DbMergedPage<Result> {
  DbMergedPage._(Iterable<Result> items, this.nextCursor)
    : items = List.unmodifiable(items);
  final List<Result> items;

  /// Null when no more rows were present at read time.
  final DbMergedContinuation? nextCursor;
}

/// One heterogeneous child source participating in a merged relationship.
///
/// Create instances with [dbMergedRelationshipSource] so the child row type
/// remains inferred while callers store differently typed sources together.
final class DbMergedRelationshipSource<Parent, ParentKey, Result> {
  DbMergedRelationshipSource._({
    required this.columns,
    required this.cursorColumn,
    required this.primaryKeyColumn,
    required this.parentKeyOf,
    required DbCompiledQuery Function(
      DbSession db,
      ParentKey parentKey,
      int sourceLimit,
      bool descending,
      DbMergedCursorBound? cursor,
      DbPredicate? continuation,
    )
    compile,
    required Result Function(Map<String, Object?> row) decode,
  }) : _compile = compile,
       _decode = decode;

  final List<AnyDbColumn> columns;
  final AnyDbColumn cursorColumn;
  final AnyDbColumn primaryKeyColumn;
  final ParentKey Function(Parent parent) parentKeyOf;
  final DbCompiledQuery Function(
    DbSession db,
    ParentKey parentKey,
    int sourceLimit,
    bool descending,
    DbMergedCursorBound? cursor,
    DbPredicate? continuation,
  )
  _compile;
  final Result Function(Map<String, Object?> row) _decode;
}

/// Creates a typed heterogeneous source from a has-many relationship.
DbMergedRelationshipSource<Parent, ParentKey, Result>
dbMergedRelationshipSource<Parent, ParentKey, Child, ChildKey, Result>({
  required DbHasMany<Parent, ParentKey, Child, ChildKey> relationship,
  required AnyDbColumn cursorColumn,
  required Result Function(Child child) convert,
  DbRelationshipQuery<Child, ChildKey>? transform,
}) {
  final columns = relationship.children.columns.toList(growable: false);
  final names = columns.map((column) => column.name).toList(growable: false);
  if (names.toSet().length != names.length) {
    throw ArgumentError.value(columns, 'columns', 'Duplicate column names');
  }
  if (!names.contains(cursorColumn.name)) {
    throw ArgumentError.value(
      cursorColumn,
      'cursorColumn',
      'Must be included in ${relationship.children.tableName}.columns',
    );
  }
  if (!names.contains(relationship.children.primaryKey.name)) {
    throw ArgumentError.value(
      relationship.children.primaryKey,
      'primaryKey',
      'Must be included in ${relationship.children.tableName}.columns',
    );
  }
  return DbMergedRelationshipSource._(
    columns: columns,
    cursorColumn: cursorColumn,
    primaryKeyColumn: relationship.children.primaryKey,
    parentKeyOf: relationship.parent.keyOf,
    compile: (db, parentKey, sourceLimit, descending, cursor, continuation) {
      final direction = descending ? 'DESC' : 'ASC';
      var base = relationship
          .queryKeys(db, [parentKey])
          .orderBy(
            DbOrdering('${quoteIdentifier(cursorColumn.name)} $direction'),
          )
          .orderBy(
            DbOrdering(
              '${quoteIdentifier(relationship.children.primaryKey.name)} '
              '$direction',
            ),
          );
      if (cursor != null) {
        final comparison = switch (cursor._direction) {
          _DbMergedCursorDirection.before => '<',
          _DbMergedCursorDirection.after => '>',
        };
        base = base.where(
          DbPredicate('${quoteIdentifier(cursorColumn.name)} $comparison ?', [
            cursorColumn.encodeAny(cursor.value),
          ]),
        );
      }
      if (continuation != null) base = base.where(continuation);
      final query = transform?.call(base) ?? base;
      return query.limit(sourceLimit).compile(columns: columns);
    },
    decode: (row) => convert(relationship.children.decode(DbRow(row))),
  );
}

/// Merges heterogeneous has-many sources into one ordered child page per
/// parent while preserving each source's typed decoder.
final class DbMergedRelationships<Parent, ParentKey, Result> {
  DbMergedRelationships(
    Iterable<DbMergedRelationshipSource<Parent, ParentKey, Result>> sources,
  ) : sources = List.unmodifiable(sources) {
    if (this.sources.isEmpty) {
      throw ArgumentError.value(sources, 'sources', 'Cannot be empty');
    }
    final affinities = this.sources
        .map((source) => source.cursorColumn.affinity)
        .toSet();
    if (affinities.length > 1) {
      throw ArgumentError.value(
        sources,
        'sources',
        'Cursor columns must use the same SQLite affinity',
      );
    }
  }

  final List<DbMergedRelationshipSource<Parent, ParentKey, Result>> sources;

  /// Loads one globally ordered, independently limited page per parent.
  ///
  /// Every source is capped at [limit] before merging. This is equivalent to
  /// scanning the full source for a top-[limit] result, while bounding work.
  /// [batchSize] also keeps compound terms and bound variables within limits
  /// commonly found in older mobile SQLite builds.
  Future<Map<ParentKey, List<Result>>> load(
    DbSession db,
    Iterable<Parent> parentRows, {
    required int limit,
    bool descending = true,
    int batchSize = 100,
    DbMergedCursorBound? cursor,
  }) async {
    final firstSource = sources.first;
    final keys = <ParentKey>{};
    for (final parent in parentRows) {
      keys.add(firstSource.parentKeyOf(parent));
    }
    return _loadKeys(
      db,
      keys,
      limit: limit,
      descending: descending,
      batchSize: batchSize,
      cursor: cursor,
    );
  }

  /// Loads merged child pages directly from parent keys.
  Future<Map<ParentKey, List<Result>>> loadKeys(
    DbSession db,
    Iterable<ParentKey> parentKeys, {
    required int limit,
    bool descending = true,
    int batchSize = 100,
    DbMergedCursorBound? cursor,
  }) => _loadKeys(
    db,
    parentKeys,
    limit: limit,
    descending: descending,
    batchSize: batchSize,
    cursor: cursor,
  );

  /// Reads a page for one parent and returns a lossless continuation.
  ///
  /// Ordering is cursor, source position, then primary key, including SQLite
  /// null ordering. Keep this descriptor and its filters stable while
  /// paging. Pages are separate reads; use a transaction for a stable snapshot.
  Future<DbMergedPage<Result>> loadPage(
    DbSession db,
    ParentKey parentKey, {
    required int limit,
    bool descending = true,
    DbMergedContinuation? cursor,
  }) async {
    if (limit < 1)
      throw ArgumentError.value(limit, 'limit', 'Must be positive');
    if (cursor != null &&
        (!identical(cursor._owner, this) ||
            cursor._parent != parentKey ||
            cursor._descending != descending)) {
      throw ArgumentError.value(
        cursor,
        'cursor',
        'Relationship, parent or order changed',
      );
    }
    final boundaries = <DbMergedContinuation>[];
    final grouped = await _loadKeys(
      db,
      [parentKey],
      limit: limit + 1,
      descending: descending,
      batchSize: 1,
      continuation: cursor,
      onRow: (row) => boundaries.add(
        DbMergedContinuation._(
          this,
          parentKey,
          descending,
          row['_loom_cursor'],
          row['_loom_source']! as int,
          row['_loom_key'],
        ),
      ),
    );
    final items = grouped[parentKey]!;
    return DbMergedPage._(
      items.take(limit),
      items.length > limit ? boundaries[limit - 1] : null,
    );
  }

  Future<Map<ParentKey, List<Result>>> _loadKeys(
    DbSession db,
    Iterable<ParentKey> parentKeys, {
    required int limit,
    required bool descending,
    required int batchSize,
    DbMergedCursorBound? cursor,
    DbMergedContinuation? continuation,
    void Function(Map<String, Object?> row)? onRow,
  }) async {
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'Must be positive');
    }
    if (batchSize < 1) {
      throw ArgumentError.value(batchSize, 'batchSize', 'Must be positive');
    }
    final keys = parentKeys.toSet().toList(growable: false);
    final grouped = <ParentKey, List<Result>>{
      for (final key in keys) key: <Result>[],
    };
    if (keys.isEmpty) return _freezeMergedGroups(grouped);

    final allColumnNames = <String>[];
    for (final source in sources) {
      for (final column in source.columns) {
        if (!allColumnNames.contains(column.name)) {
          allColumnNames.add(column.name);
        }
      }
    }
    const reserved = {
      '_loom_source',
      '_loom_parent',
      '_loom_cursor',
      '_loom_key',
    };
    if (allColumnNames.any(reserved.contains)) {
      throw StateError('Mapped columns cannot use SQLite Loom merge aliases');
    }

    for (var start = 0; start < keys.length; start += batchSize) {
      final end = _batchEnd(start, batchSize, keys.length);
      final parentSelections = <String>[];
      final arguments = <Object?>[];
      for (var parentIndex = start; parentIndex < end; parentIndex += 1) {
        final sourceSelections = <String>[];
        for (
          var sourceIndex = 0;
          sourceIndex < sources.length;
          sourceIndex += 1
        ) {
          final source = sources[sourceIndex];
          final compiled = source._compile(
            db,
            keys[parentIndex],
            limit,
            descending,
            cursor,
            continuation == null
                ? null
                : _continuationPredicate(source, sourceIndex, continuation),
          );
          final sourceNames = source.columns
              .map((column) => column.name)
              .toSet();
          sourceSelections.add(
            'SELECT $sourceIndex AS ${quoteIdentifier('_loom_source')}, '
            '$parentIndex AS ${quoteIdentifier('_loom_parent')}, '
            '${quoteIdentifier(source.cursorColumn.name)} AS '
            '${quoteIdentifier('_loom_cursor')}, '
            '${quoteIdentifier(source.primaryKeyColumn.name)} AS '
            '${quoteIdentifier('_loom_key')}, '
            '${allColumnNames.map((name) => sourceNames.contains(name) ? quoteIdentifier(name) : 'NULL AS ${quoteIdentifier(name)}').join(', ')} '
            'FROM (${compiled.sql}) AS ${quoteIdentifier('_loom_row')}',
          );
          arguments.addAll(compiled.arguments);
        }
        final direction = descending ? 'DESC' : 'ASC';
        parentSelections.add(
          'SELECT * FROM (${sourceSelections.join(' UNION ALL ')}) '
          'AS ${quoteIdentifier('_loom_sources')} '
          'ORDER BY ${quoteIdentifier('_loom_cursor')} $direction, '
          '${quoteIdentifier('_loom_source')} ASC, '
          '${quoteIdentifier('_loom_key')} $direction LIMIT $limit',
        );
      }
      final direction = descending ? 'DESC' : 'ASC';
      final sql =
          'SELECT * FROM ('
          '${parentSelections.map((selection) => 'SELECT * FROM ($selection)').join(' UNION ALL ')}'
          ') AS ${quoteIdentifier('_loom_merged')} '
          'ORDER BY ${quoteIdentifier('_loom_parent')} ASC, '
          '${quoteIdentifier('_loom_cursor')} $direction, '
          '${quoteIdentifier('_loom_source')} ASC, '
          '${quoteIdentifier('_loom_key')} $direction';
      final maps = await db.rawRead(sql, arguments: arguments);
      for (final map in maps) {
        final sourceIndex = map['_loom_source']! as int;
        final parentIndex = map['_loom_parent']! as int;
        final source = sources[sourceIndex];
        final sourceRow = <String, Object?>{
          for (final column in source.columns) column.name: map[column.name],
        };
        grouped[keys[parentIndex]]!.add(source._decode(sourceRow));
        onRow?.call(map);
      }
    }
    return _freezeMergedGroups(grouped);
  }
}

DbPredicate _continuationPredicate(
  DbMergedRelationshipSource<dynamic, dynamic, dynamic> source,
  int sourceIndex,
  DbMergedContinuation cursor,
) {
  final column = quoteIdentifier(source.cursorColumn.name);
  final key = quoteIdentifier(source.primaryKeyColumn.name);
  final comparison = cursor._descending ? '<' : '>';
  final value = cursor._value;
  final strict = value == null
      ? (cursor._descending ? '0' : '$column IS NOT NULL')
      : (cursor._descending
            ? '($column < ? OR $column IS NULL)'
            : '$column > ?');
  final arguments = <Object?>[if (value != null) value];
  // Source order is always ascending, including descending feeds.
  if (sourceIndex > cursor._source) {
    return DbPredicate('$strict OR $column IS ?', [...arguments, value]);
  }
  if (sourceIndex == cursor._source) {
    return DbPredicate('$strict OR ($column IS ? AND $key $comparison ?)', [
      ...arguments,
      value,
      cursor._key,
    ]);
  }
  return DbPredicate(strict, arguments);
}

Map<Key, List<Result>> _freezeMergedGroups<Key, Result>(
  Map<Key, List<Result>> grouped,
) => Map.unmodifiable({
  for (final entry in grouped.entries)
    entry.key: List<Result>.unmodifiable(entry.value),
});

/// A one-to-one relationship described by a related foreign-key column.
final class DbHasOne<Parent, ParentKey, Related, RelatedKey> {
  const DbHasOne({
    required this.parent,
    required this.related,
    required this.foreignKey,
    required this.foreignKeyOf,
  });

  final DbTable<Parent, ParentKey> parent;
  final DbTable<Related, RelatedKey> related;
  final AnyDbColumn foreignKey;
  final ParentKey Function(Related row) foreignKeyOf;

  DbHasMany<Parent, ParentKey, Related, RelatedKey> get _many => DbHasMany(
    parent: parent,
    children: related,
    foreignKey: foreignKey,
    foreignKeyOf: foreignKeyOf,
  );

  /// Loads the related row, returning null when absent and rejecting duplicates.
  Future<Related?> load(DbSession db, Parent parentRow) async {
    final rows = await _many.query(db, parentRow).limit(2).get();
    _rejectDuplicates(parent.keyOf(parentRow), rows);
    return rows.firstOrNull;
  }

  /// Loads and groups related rows in one query.
  Future<Map<ParentKey, Related?>> loadAll(
    DbSession db,
    Iterable<Parent> parentRows,
  ) async {
    final grouped = await _many.loadAll(db, parentRows);
    return Map.unmodifiable({
      for (final entry in grouped.entries)
        entry.key: _single(entry.key, entry.value),
    });
  }

  /// Watches the related row for one parent.
  Stream<Related?> watch(DbSession db, Parent parentRow) {
    final key = parent.keyOf(parentRow);
    return _many
        .query(db, parentRow)
        .limit(2)
        .watch()
        .map((rows) => _single(key, rows));
  }

  Related? _single(ParentKey key, List<Related> rows) {
    _rejectDuplicates(key, rows);
    return rows.firstOrNull;
  }

  void _rejectDuplicates(ParentKey key, List<Related> rows) {
    if (rows.length > 1) {
      throw StateError(
        'Expected at most one ${related.tableName} row for '
        '${parent.tableName} key $key, found ${rows.length}',
      );
    }
  }
}

/// An inverse relationship from a source row to its referenced target row.
final class DbBelongsTo<Source, SourceKey, Target, TargetKey> {
  const DbBelongsTo({
    required this.source,
    required this.target,
    required this.foreignKey,
    required this.foreignKeyOf,
  });

  final DbTable<Source, SourceKey> source;
  final DbTable<Target, TargetKey> target;

  /// The source-table column carrying the target key.
  final AnyDbColumn foreignKey;
  final TargetKey? Function(Source row) foreignKeyOf;

  /// Builds the target query for [sourceRow].
  DbTableQuery<Target, TargetKey> query(DbSession db, Source sourceRow) {
    final key = foreignKeyOf(sourceRow);
    final base = db.table(target);
    return key == null ? base.where(DbPredicate.never) : base.whereKey(key);
  }

  /// Loads the referenced target row, or null for an absent/null reference.
  Future<Target?> load(DbSession db, Source sourceRow) {
    return query(db, sourceRow).firstOrNull();
  }

  /// Loads all distinct targets once and maps them back to source keys.
  Future<Map<SourceKey, Target?>> loadAll(
    DbSession db,
    Iterable<Source> sourceRows,
  ) async {
    final rows = sourceRows.toList(growable: false);
    final targetKeys = rows.map(foreignKeyOf).whereType<TargetKey>().toSet();
    final targets = targetKeys.isEmpty
        ? <Target>[]
        : await db
              .table(target)
              .where(target.primaryKey.inValues(targetKeys))
              .get();
    final byKey = {for (final row in targets) target.keyOf(row): row};
    return Map.unmodifiable({
      for (final row in rows) source.keyOf(row): byKey[foreignKeyOf(row)],
    });
  }

  /// Watches the referenced target row for [sourceRow].
  Stream<Target?> watch(DbSession db, Source sourceRow) {
    return query(db, sourceRow).watchFirstOrNull();
  }
}

DbPredicate _foreignKeyEquals<Key>(AnyDbColumn column, Key value) {
  return DbPredicate('${quoteIdentifier(column.name)} = ?', [
    column.encodeAny(value),
  ]);
}

DbPredicate _foreignKeyIn<Key>(AnyDbColumn column, Set<Key> values) {
  final encoded = values.map(column.encodeAny).toList(growable: false);
  return DbPredicate(
    '${quoteIdentifier(column.name)} IN '
    '(${List.filled(encoded.length, '?').join(', ')})',
    encoded,
  );
}
