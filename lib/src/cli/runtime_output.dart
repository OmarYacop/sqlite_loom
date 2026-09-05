part of 'runtime_cli.dart';

void _printMutationResult(
  String command, {
  required bool json,
  required SqliteLoomCliPrinter printLine,
  required Map<String, Object?> values,
}) {
  if (json) {
    _printJson(printLine, {'command': command, 'success': true, ...values});
  } else {
    for (final entry in values.entries) {
      printLine('${entry.key}: ${entry.value}');
    }
  }
}

Future<int> _exportTable(
  SqliteLoomDatabaseTools tools,
  String table,
  File output, {
  required String format,
}) async {
  final description = await tools.describe(table);
  final columns = (description['columns']! as List<Map<String, Object?>>)
      .map((column) => column['name'])
      .whereType<String>()
      .toList(growable: false);
  final temporary = File('${output.path}.sqlite_loom_tmp_$pid');
  final sink = temporary.openWrite();
  var rowCount = 0;
  var firstJsonRow = true;
  try {
    if (format == 'json') {
      sink.write('[');
    } else {
      sink.write(rowsToCsv(const [], columnNames: columns));
    }
    await for (final page in tools.exportPages(table)) {
      rowCount += page.length;
      if (format == 'csv') {
        sink.write(rowsToCsv(page, columnNames: columns, includeHeader: false));
      } else {
        for (final row in jsonSafeRows(page)) {
          if (!firstJsonRow) sink.write(',');
          sink.write(jsonEncode(row));
          firstJsonRow = false;
        }
      }
    }
    if (format == 'json') sink.write(']\n');
    await sink.flush();
    await sink.close();
    if (await output.exists()) await output.delete();
    await temporary.rename(output.path);
    return rowCount;
  } catch (_) {
    await sink.close();
    if (await temporary.exists()) await temporary.delete();
    rethrow;
  }
}

void _printRows(
  String command,
  List<Map<String, Object?>> rows, {
  required bool json,
  bool csv = false,
  required SqliteLoomCliPrinter printLine,
  Map<String, Object?> metadata = const {},
}) {
  if (json && csv) {
    throw ArgumentError('Choose either --json or --csv');
  }
  if (json) {
    _printJson(printLine, {
      'command': command,
      'success': true,
      ...metadata,
      'rowCount': rows.length,
      'rows': jsonSafeRows(rows),
    });
    return;
  }
  if (csv) {
    final csvOutput = rowsToCsv(rows);
    if (csvOutput.isNotEmpty) printLine(csvOutput.trimRight());
    return;
  }
  if (rows.isEmpty) {
    printLine('No rows.');
    return;
  }
  printLine(rowsToCsv(rows).trimRight());
}

void _printDescription(
  Map<String, Object?> description,
  SqliteLoomCliPrinter printLine,
) {
  printLine('${description['type']}: ${description['name']}');
  printLine('strict: ${description['strict']}');
  printLine('withoutRowid: ${description['withoutRowid']}');
  final sql = description['sql'];
  if (sql != null) printLine('sql: $sql');
  for (final section in ['columns', 'foreignKeys', 'indexes', 'triggers']) {
    final values = description[section]! as List<Map<String, Object?>>;
    printLine('$section: ${values.length}');
    if (values.isNotEmpty) printLine(rowsToCsv(values).trimRight());
  }
}

void _printFailure(
  String command,
  String message,
  bool json,
  SqliteLoomCliPrinter printLine,
) {
  if (json) {
    _printJson(printLine, {
      'command': command,
      'success': false,
      'error': message,
    });
  } else {
    printLine('Error: $message');
  }
}

void _printJson(SqliteLoomCliPrinter printLine, Map<String, Object?> value) {
  printLine(jsonEncode(value));
}

bool _isHelp(String command) =>
    command == 'help' || command == '--help' || command == '-h';

void _printHelp(SqliteLoomCliPrinter printLine) {
  printLine('sqlite_loom database commands:');
  printLine('  migrate [--to version] [--json]');
  printLine('  status [--json]');
  printLine('  rollback [--steps n] [--json]');
  printLine('  redo [--steps n] [--json]');
  printLine('  reset --force [--json]');
  printLine('  refresh --force [--json]');
  printLine('  fresh --force [--json]');
  printLine('  sandbox [--to version] [--json]');
  printLine('  schema:dump [--json]');
  printLine('  schema:diff [--json]');
  printLine('  db:inspect [--json]');
  printLine('  db:tables [--json]');
  printLine('  db:describe <table> [--json]');
  printLine(
    '  db:browse <table> [--limit n] [--offset n] [--order column] [--desc] [--json]',
  );
  printLine('  db:query (--sql SQL | --file path) [--json | --csv]');
  printLine('  db:explain (--sql SQL | --file path) [--json]');
  printLine(
    '  db:export <table> --output path [--format csv|json] [--force] [--json]',
  );
  printLine(
    '  db:insert <table> (--values-json object | --value column=value...) [--dry-run] [--json]',
  );
  printLine(
    '  db:update <table> (--set-json object | --set column=value...) (--where-json object | --where column=value... | --all) --force [--dry-run] [--json]',
  );
  printLine(
    '  db:delete <table> (--where-json object | --where column=value... | --all) --force [--dry-run] [--json]',
  );
  printLine('  db:truncate <table> --force [--dry-run] [--json]');
  printLine(
    '  db:execute (--sql SQL | --file path) --force [--dry-run] [--json]',
  );
  printLine(
    '  db:import <table> --input path [--format csv|json] [--dry-run] [--json]',
  );
  printLine('  db:copy <source> <destination> [--dry-run] [--json]');
  printLine('  db:vacuum [--json]');
  printLine('  db:integrity [--quick] [--json]');
  printLine('  db:optimize [--json]');
  printLine('  db:backup --output path [--json]');
  printLine('  db:restore --input path --force [--json]');
}
