import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common/sqlite_api.dart';

import 'database_tools.dart';

final class SqliteLoomDatabaseMutations {
  const SqliteLoomDatabaseMutations(this.database, this.tools);

  final Database database;
  final SqliteLoomDatabaseTools tools;

  Future<void> validateValues(
    String table,
    Map<String, Object?> values, {
    bool allowEmpty = false,
  }) => _validateValues(table, values, allowEmpty: allowEmpty);

  Future<int> insert(String table, Map<String, Object?> values) async {
    await _validateValues(table, values, allowEmpty: false);
    final columns = values.keys.toList(growable: false);
    final placeholders = List.filled(columns.length, '?').join(', ');
    return database.rawInsert(
      'INSERT INTO ${quoteIdentifier(table)} '
      '(${columns.map(quoteIdentifier).join(', ')}) VALUES ($placeholders)',
      [for (final column in columns) _sqlValue(values[column])],
    );
  }

  Future<MutationPreview> preview(
    String table,
    Map<String, Object?> where,
  ) async {
    await _validateValues(table, where, allowEmpty: true);
    final predicate = _predicate(where);
    final countRows = await database.rawQuery(
      'SELECT COUNT(*) AS count FROM ${quoteIdentifier(table)}${predicate.sql}',
      predicate.arguments,
    );
    final samples = await database.rawQuery(
      'SELECT * FROM ${quoteIdentifier(table)}${predicate.sql} LIMIT 20',
      predicate.arguments,
    );
    return MutationPreview(
      count: countRows.single['count']! as int,
      rows: samples
          .map(Map<String, Object?>.unmodifiable)
          .toList(growable: false),
    );
  }

  Future<int> update(
    String table,
    Map<String, Object?> values,
    Map<String, Object?> where,
  ) async {
    await _validateValues(table, values, allowEmpty: false);
    await _validateValues(table, where, allowEmpty: true);
    final assignments = values.keys
        .map((column) => '${quoteIdentifier(column)} = ?')
        .join(', ');
    final predicate = _predicate(where);
    return database.rawUpdate(
      'UPDATE ${quoteIdentifier(table)} SET $assignments${predicate.sql}',
      [
        for (final value in values.values) _sqlValue(value),
        ...predicate.arguments,
      ],
    );
  }

  Future<int> delete(String table, Map<String, Object?> where) async {
    await _validateValues(table, where, allowEmpty: true);
    final predicate = _predicate(where);
    return database.rawDelete(
      'DELETE FROM ${quoteIdentifier(table)}${predicate.sql}',
      predicate.arguments,
    );
  }

  Future<int> truncate(String table) async {
    await tools.describe(table);
    return database.transaction((transaction) async {
      final count = await transaction.rawDelete(
        'DELETE FROM ${quoteIdentifier(table)}',
      );
      final sequenceTable = await transaction.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence'",
      );
      if (sequenceTable.isNotEmpty) {
        await transaction.rawDelete(
          'DELETE FROM sqlite_sequence WHERE name = ?',
          [table],
        );
      }
      return count;
    });
  }

  String validateExecutableSql(String sql) {
    final statement = sql.trim();
    if (statement.isEmpty) {
      throw ArgumentError.value(sql, 'sql', 'SQL must not be empty');
    }
    final firstKeyword = _firstSqlKeyword(statement);
    if ({
      'BEGIN',
      'COMMIT',
      'END',
      'ROLLBACK',
      'SAVEPOINT',
      'RELEASE',
    }.contains(firstKeyword)) {
      throw ArgumentError(
        'Transaction-control SQL is not accepted; db:execute is already atomic.',
      );
    }
    if ({'SELECT', 'VALUES', 'EXPLAIN'}.contains(firstKeyword)) {
      throw ArgumentError('Use db:query or db:explain for read-only SQL.');
    }
    if (!{
      'INSERT',
      'UPDATE',
      'DELETE',
      'REPLACE',
      'CREATE',
      'ALTER',
      'DROP',
    }.contains(firstKeyword)) {
      throw ArgumentError(
        'db:execute accepts one INSERT, UPDATE, DELETE, REPLACE, CREATE, ALTER, or DROP statement.',
      );
    }
    return statement;
  }

  Future<void> execute(String sql) async {
    final statement = validateExecutableSql(sql);
    await database.transaction((transaction) => transaction.execute(statement));
  }

  Future<ImportResult> importRows(
    String table,
    List<Map<String, Object?>> rows, {
    bool dryRun = false,
  }) async {
    final description = await tools.describe(table);
    final columns = _columnNames(description).toSet();
    for (final row in rows) {
      _validateColumns(table, row, columns, allowEmpty: false);
    }
    if (dryRun || rows.isEmpty) {
      return ImportResult(parsed: rows.length, inserted: 0);
    }
    await database.transaction((transaction) async {
      for (final row in rows) {
        final columns = row.keys.toList(growable: false);
        await transaction.rawInsert(
          'INSERT INTO ${quoteIdentifier(table)} '
          '(${columns.map(quoteIdentifier).join(', ')}) '
          'VALUES (${List.filled(columns.length, '?').join(', ')})',
          [for (final column in columns) _sqlValue(row[column])],
        );
      }
    });
    return ImportResult(parsed: rows.length, inserted: rows.length);
  }

  Future<int> copy(String source, String destination) async {
    final shared = await copyColumns(source, destination);
    final columns = shared.map(quoteIdentifier).join(', ');
    return database.rawUpdate(
      'INSERT INTO ${quoteIdentifier(destination)} ($columns) '
      'SELECT $columns FROM ${quoteIdentifier(source)}',
    );
  }

  Future<List<String>> copyColumns(String source, String destination) async {
    if (source == destination) {
      throw ArgumentError('Source and destination tables must be different.');
    }
    final sourceDescription = await tools.describe(source);
    final destinationDescription = await tools.describe(destination);
    final sourceColumns = _columnNames(sourceDescription).toSet();
    final destinationColumns = _columnNames(destinationDescription);
    final shared = destinationColumns
        .where(sourceColumns.contains)
        .toList(growable: false);
    if (shared.isEmpty) {
      throw ArgumentError('Source and destination have no columns in common.');
    }
    return shared;
  }

  Future<void> _validateValues(
    String table,
    Map<String, Object?> values, {
    required bool allowEmpty,
  }) async {
    final description = await tools.describe(table);
    final columns = _columnNames(description).toSet();
    _validateColumns(table, values, columns, allowEmpty: allowEmpty);
  }

  void _validateColumns(
    String table,
    Map<String, Object?> values,
    Set<String> columns, {
    required bool allowEmpty,
  }) {
    if (!allowEmpty && values.isEmpty) {
      throw ArgumentError('At least one column value is required.');
    }
    for (final column in values.keys) {
      if (!columns.contains(column)) {
        throw ArgumentError.value(
          column,
          'column',
          'Column does not exist in $table',
        );
      }
    }
  }
}

final class MutationPreview {
  const MutationPreview({required this.count, required this.rows});

  final int count;
  final List<Map<String, Object?>> rows;
}

final class ImportResult {
  const ImportResult({required this.parsed, required this.inserted});

  final int parsed;
  final int inserted;
}

Future<List<Map<String, Object?>>> readImportRows(
  File input, {
  required String format,
}) async {
  final contents = await input.readAsString();
  if (format == 'json') {
    final decoded = jsonDecode(contents);
    if (decoded is! List<Object?>) {
      throw const FormatException(
        'JSON import must contain an array of objects.',
      );
    }
    return [
      for (final (index, value) in decoded.indexed)
        if (value is Map<String, Object?>)
          Map<String, Object?>.unmodifiable(value)
        else
          throw FormatException('JSON row ${index + 1} must be an object.'),
    ];
  }
  if (format != 'csv') {
    throw ArgumentError.value(format, '--format', 'Must be csv or json');
  }
  final records = _parseCsv(contents);
  if (records.isEmpty) return const [];
  final headers = records.first;
  if (headers.isEmpty || headers.any((header) => header.isEmpty)) {
    throw const FormatException('CSV header names must not be empty.');
  }
  if (headers.toSet().length != headers.length) {
    throw const FormatException('CSV header names must be unique.');
  }
  return [
    for (final (index, record) in records.skip(1).indexed)
      if (record.length == headers.length)
        {
          for (var column = 0; column < headers.length; column++)
            headers[column]: record[column],
        }
      else
        throw FormatException(
          'CSV row ${index + 2} has ${record.length} fields; expected ${headers.length}.',
        ),
  ];
}

List<String> _columnNames(Map<String, Object?> description) =>
    (description['columns']! as List<Map<String, Object?>>)
        .map((column) => column['name'])
        .whereType<String>()
        .toList(growable: false);

({String sql, List<Object?> arguments}) _predicate(
  Map<String, Object?> values,
) {
  if (values.isEmpty) return (sql: '', arguments: const []);
  final clauses = <String>[];
  final arguments = <Object?>[];
  for (final entry in values.entries) {
    if (entry.value == null) {
      clauses.add('${quoteIdentifier(entry.key)} IS NULL');
    } else {
      clauses.add('${quoteIdentifier(entry.key)} = ?');
      arguments.add(_sqlValue(entry.value));
    }
  }
  return (sql: ' WHERE ${clauses.join(' AND ')}', arguments: arguments);
}

Object? _sqlValue(Object? value) {
  if (value == null || value is num || value is String || value is List<int>) {
    return value;
  }
  if (value is bool) return value ? 1 : 0;
  if (value is List<Object?> &&
      value.every((item) => item is int && item >= 0 && item <= 255)) {
    return <int>[for (final item in value) item! as int];
  }
  if (value is Map<String, Object?> &&
      value.length == 1 &&
      value['base64'] is String) {
    try {
      return base64Decode(value['base64']! as String);
    } on FormatException {
      throw ArgumentError.value(value, 'value', 'Invalid base64 BLOB value');
    }
  }
  throw ArgumentError.value(
    value,
    'value',
    'SQL values must be null, boolean, numeric, text, or byte arrays',
  );
}

String _firstSqlKeyword(String sql) => sql
    .replaceFirst(RegExp(r'^(?:\s|--[^\n]*(?:\n|$)|/\*[\s\S]*?\*/)*'), '')
    .split(RegExp(r'[^A-Za-z]'))
    .first
    .toUpperCase();

List<List<String>> _parseCsv(String input) {
  if (input.isEmpty) return const [];
  final records = <List<String>>[];
  var record = <String>[];
  final field = StringBuffer();
  var quoted = false;
  for (var index = 0; index < input.length; index++) {
    final character = input[index];
    if (quoted) {
      if (character == '"') {
        if (index + 1 < input.length && input[index + 1] == '"') {
          field.write('"');
          index++;
        } else {
          quoted = false;
        }
      } else {
        field.write(character);
      }
      continue;
    }
    if (character == '"' && field.isEmpty) {
      quoted = true;
    } else if (character == ',') {
      record.add(field.toString());
      field.clear();
    } else if (character == '\n' || character == '\r') {
      if (character == '\r' &&
          index + 1 < input.length &&
          input[index + 1] == '\n') {
        index++;
      }
      record.add(field.toString());
      field.clear();
      records.add(record);
      record = <String>[];
    } else {
      field.write(character);
    }
  }
  if (quoted) throw const FormatException('CSV contains an unclosed quote.');
  if (field.isNotEmpty || record.isNotEmpty) {
    record.add(field.toString());
    records.add(record);
  }
  return records;
}
