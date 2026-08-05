import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

/// Internal, renderer-independent database inspection and query operations.
final class SqliteLoomDatabaseTools {
  const SqliteLoomDatabaseTools(this.database);

  final Database database;

  Future<List<Map<String, Object?>>> tables() async {
    final rows = await database.rawQuery('''
      SELECT type, name, tbl_name, sql
      FROM sqlite_master
      WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
      ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END, name
    ''');
    return _immutableRows(rows);
  }

  Future<Map<String, Object?>> describe(String table) async {
    final objectRows = await database.rawQuery(
      '''
        SELECT type, name, tbl_name, sql
        FROM sqlite_master
        WHERE name = ? AND type IN ('table', 'view')
      ''',
      [table],
    );
    if (objectRows.isEmpty) {
      throw ArgumentError.value(table, 'table', 'Table or view does not exist');
    }

    final quoted = quoteIdentifier(table);
    final columns = await database.rawQuery('PRAGMA table_xinfo($quoted)');
    final foreignKeys = await database.rawQuery(
      'PRAGMA foreign_key_list($quoted)',
    );
    final indexes = await database.rawQuery('PRAGMA index_list($quoted)');
    final indexDetails = <Map<String, Object?>>[];
    for (final index in indexes) {
      final name = index['name'];
      if (name is! String) continue;
      final details = await database.rawQuery(
        'PRAGMA index_xinfo(${quoteIdentifier(name)})',
      );
      indexDetails.add({...index, 'columns': _immutableRows(details)});
    }
    final triggers = await database.rawQuery(
      '''
        SELECT name, sql
        FROM sqlite_master
        WHERE type = 'trigger' AND tbl_name = ?
        ORDER BY name
      ''',
      [table],
    );
    final object = objectRows.single;
    final sql = object['sql'];
    final normalizedSql = sql is String ? sql.toUpperCase() : '';
    return Map<String, Object?>.unmodifiable({
      'type': object['type'],
      'name': object['name'],
      'sql': sql,
      'strict': RegExp(
        r'\bSTRICT\s*;?\s*$',
        caseSensitive: false,
      ).hasMatch(sql is String ? sql.trim() : ''),
      'withoutRowid': normalizedSql.contains('WITHOUT ROWID'),
      'columns': _immutableRows(columns),
      'foreignKeys': _immutableRows(foreignKeys),
      'indexes': List<Map<String, Object?>>.unmodifiable(indexDetails),
      'triggers': _immutableRows(triggers),
    });
  }

  Future<List<Map<String, Object?>>> browse(
    String table, {
    required int limit,
    required int offset,
    String? orderBy,
    bool descending = false,
  }) async {
    final description = await describe(table);
    final columns = description['columns']! as List<Map<String, Object?>>;
    if (orderBy != null &&
        !columns.any((column) => column['name'] == orderBy)) {
      throw ArgumentError.value(
        orderBy,
        'orderBy',
        'Column does not exist in $table',
      );
    }
    final ordering = orderBy == null
        ? ''
        : ' ORDER BY ${quoteIdentifier(orderBy)} ${descending ? 'DESC' : 'ASC'}';
    final rows = await database.rawQuery(
      'SELECT * FROM ${quoteIdentifier(table)}$ordering LIMIT ? OFFSET ?',
      [limit, offset],
    );
    return _immutableRows(rows);
  }

  Future<List<Map<String, Object?>>> readOnlyQuery(String sql) async {
    final statement = sql.trim();
    if (statement.isEmpty) {
      throw ArgumentError.value(sql, 'sql', 'SQL must not be empty');
    }
    if (!_looksLikeReadOnlyStatement(statement)) {
      throw ArgumentError(
        'db:query accepts SELECT, WITH, VALUES, or read-only EXPLAIN statements only.',
      );
    }

    try {
      return await _underQueryOnly(() => database.rawQuery(statement));
    } catch (error) {
      final message = '$error'.toLowerCase();
      if (message.contains('readonly') || message.contains('read-only')) {
        throw ArgumentError('db:query only accepts read-only SQL.');
      }
      rethrow;
    }
  }

  Future<List<Map<String, Object?>>> explain(String sql) async {
    final statement = sql.trim();
    if (statement.isEmpty) {
      throw ArgumentError.value(sql, 'sql', 'SQL must not be empty');
    }
    if (!_looksLikeExplainableStatement(statement)) {
      throw ArgumentError('db:explain only accepts read-only SQL.');
    }
    return _underQueryOnly(
      () => database.rawQuery('EXPLAIN QUERY PLAN $statement'),
    );
  }

  Stream<List<Map<String, Object?>>> exportPages(
    String table, {
    int pageSize = 1000,
  }) async* {
    await describe(table);
    var offset = 0;
    while (true) {
      final rows = _immutableRows(
        await database.rawQuery(
          'SELECT * FROM ${quoteIdentifier(table)} LIMIT ? OFFSET ?',
          [pageSize, offset],
        ),
      );
      if (rows.isEmpty) return;
      yield rows;
      if (rows.length < pageSize) return;
      offset += rows.length;
    }
  }

  Future<List<Map<String, Object?>>> _underQueryOnly(
    Future<List<Map<String, Object?>>> Function() action,
  ) async {
    final current = await database.rawQuery('PRAGMA query_only');
    final wasEnabled = current.single.values.first == 1;
    if (!wasEnabled) await database.execute('PRAGMA query_only = ON');
    try {
      return _immutableRows(await action());
    } finally {
      if (!wasEnabled) await database.execute('PRAGMA query_only = OFF');
    }
  }
}

String quoteIdentifier(String value) {
  if (value.isEmpty || value.contains('\u0000')) {
    throw ArgumentError.value(value, 'identifier', 'Invalid SQL identifier');
  }
  return '"${value.replaceAll('"', '""')}"';
}

String rowsToCsv(
  List<Map<String, Object?>> rows, {
  Iterable<String>? columnNames,
  bool includeHeader = true,
}) {
  final columns = (columnNames ?? (rows.isEmpty ? const [] : rows.first.keys))
      .toList(growable: false);
  if (columns.isEmpty) return '';
  final buffer = StringBuffer();
  if (includeHeader) buffer.writeln(columns.map(_csvCell).join(','));
  for (final row in rows) {
    buffer.writeln(columns.map((column) => _csvCell(row[column])).join(','));
  }
  return buffer.toString();
}

Object? jsonSafeSqlValue(Object? value) {
  if (value is List<int>) return {'base64': base64Encode(value)};
  return value;
}

List<Map<String, Object?>> jsonSafeRows(List<Map<String, Object?>> rows) => [
  for (final row in rows)
    {for (final entry in row.entries) entry.key: jsonSafeSqlValue(entry.value)},
];

List<Map<String, Object?>> _immutableRows(List<Map<String, Object?>> rows) =>
    rows.map(Map<String, Object?>.unmodifiable).toList(growable: false);

bool _looksLikeReadOnlyStatement(String sql) {
  final withoutComments = _withoutLeadingComments(sql);
  return withoutComments.startsWith('SELECT') ||
      withoutComments.startsWith('WITH') ||
      withoutComments.startsWith('VALUES') ||
      withoutComments.startsWith('EXPLAIN SELECT') ||
      withoutComments.startsWith('EXPLAIN QUERY PLAN SELECT') ||
      withoutComments.startsWith('EXPLAIN WITH') ||
      withoutComments.startsWith('EXPLAIN QUERY PLAN WITH');
}

bool _looksLikeExplainableStatement(String sql) {
  final withoutComments = _withoutLeadingComments(sql);
  return withoutComments.startsWith('SELECT') ||
      withoutComments.startsWith('WITH') ||
      withoutComments.startsWith('VALUES');
}

String _withoutLeadingComments(String sql) => sql
    .replaceFirst(RegExp(r'^(?:\s|--[^\n]*(?:\n|$)|/\*[\s\S]*?\*/)*'), '')
    .toUpperCase();

String _csvCell(Object? value) {
  if (value == null) return '';
  final text = value is List<int> ? base64Encode(value) : '$value';
  if (!text.contains(RegExp('[,"\\r\\n]'))) return text;
  return '"${text.replaceAll('"', '""')}"';
}
