part of 'query.dart';

/// A typed single-column projection derived from a table query.
final class DbColumnSelection<Row, Key, T> {
  DbColumnSelection._(this._source, this.column);

  final DbTableQuery<Row, Key> _source;
  final DbColumn<T> column;

  Future<List<T>> get() async {
    final where = _source._compileWhere();
    final maps = await _source._executor.query(
      _source._table.tableName,
      columns: [column.name],
      where: where?.sql,
      whereArgs: where?.arguments,
      orderBy: _source._compileOrderBy(),
      limit: _source._limit,
      offset: _source._offset,
    );
    return maps
        .map((map) => column.decode(map[column.name]))
        .toList(growable: false);
  }

  /// Returns the first projected value or throws when there is none.
  Future<T> first() async {
    final values = await _source
        .limit(firstLimit(_source._limit))
        .pluck(column)
        .get();
    if (values.isEmpty) throw StateError('No projected value found');
    return values.first;
  }

  /// Returns the first projected value, or null.
  Future<T?> firstOrNull() async {
    final values = await _source
        .limit(firstLimit(_source._limit))
        .pluck(column)
        .get();
    return values.isEmpty ? null : values.first;
  }

  Stream<List<T>> watch() =>
      _source._watch<List<T>>(load: get, equals: dbValueEquals);

  /// Watches the first projected value or null.
  Stream<T?> watchFirstOrNull() =>
      _source._watch<T?>(load: firstOrNull, equals: dbValueEquals);
}

/// A selected set of columns decoded lazily through [DbRow.get].
final class DbRowSelection<Row, Key> {
  DbRowSelection._(
    this._source,
    List<AnyDbColumn> columns, {
    bool distinct = false,
  }) : columns = List.unmodifiable(columns),
       _distinct = distinct {
    if (columns.isEmpty) {
      throw ArgumentError.value(columns, 'columns', 'Cannot be empty');
    }
    final names = columns.map((column) => column.name).toSet();
    if (names.length != columns.length) {
      throw ArgumentError.value(columns, 'columns', 'Duplicate column names');
    }
  }

  final DbTableQuery<Row, Key> _source;
  final List<AnyDbColumn> columns;
  final bool _distinct;

  /// Removes duplicate projected rows.
  DbRowSelection<Row, Key> distinct() =>
      DbRowSelection._(_source, columns, distinct: true);

  /// Decodes each projected row into an application-specific result.
  DbDecodedSelection<Row, Key, Result> decodeWith<Result>(
    Result Function(DbRow row) decode,
  ) {
    return DbDecodedSelection._(this, decode);
  }

  Future<List<DbRow>> get() async {
    final compiled = _source.compile(columns: columns);
    final sql = _distinct
        ? compiled.sql.replaceFirst('SELECT ', 'SELECT DISTINCT ')
        : compiled.sql;
    final maps = await _source._executor.rawQuery(sql, compiled.arguments);
    return maps.map(DbRow.new).toList(growable: false);
  }

  Stream<List<DbRow>> watch() => _source._watch<List<DbRow>>(
    load: get,
    equals: (left, right) => dbValueEquals(
      left.map((row) => row.asMap).toList(),
      right.map((row) => row.asMap).toList(),
    ),
  );
}

/// A projection decoded directly into [Result] values.
final class DbDecodedSelection<Row, Key, Result> {
  const DbDecodedSelection._(this._selection, this._decode);
  final DbRowSelection<Row, Key> _selection;
  final Result Function(DbRow row) _decode;

  Future<List<Result>> get() async =>
      (await _selection.get()).map(_decode).toList(growable: false);

  Stream<List<Result>> watch() => _selection.watch().map(
    (rows) => rows.map(_decode).toList(growable: false),
  );
}
