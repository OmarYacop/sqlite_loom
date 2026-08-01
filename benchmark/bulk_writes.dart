import 'dart:convert';
import 'dart:io';

import 'package:sqlite_loom/sqlite_loom.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main(List<String> arguments) async {
  sqfliteFfiInit();
  final database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  final loom = SqliteLoom(database);
  await database.execute(
    'CREATE TABLE benchmark_rows (id INTEGER PRIMARY KEY, value TEXT)',
  );
  final query = loom.table(const _BenchmarkTable());
  final rows = [
    for (var index = 0; index < 10000; index += 1)
      (id: index, value: 'value-$index'),
  ];
  final stopwatch = Stopwatch()..start();
  await query.insertAll(rows, batchSize: 500);
  stopwatch.stop();
  final milliseconds = stopwatch.elapsedMilliseconds.clamp(1, 1 << 31);
  final rowsPerSecond = (rows.length * 1000 / milliseconds).round();
  final readStopwatch = Stopwatch()..start();
  final loaded = await query.orderBy(_BenchmarkTable.id.ascending()).get();
  readStopwatch.stop();
  final readMilliseconds = readStopwatch.elapsedMilliseconds.clamp(1, 1 << 31);
  final readRowsPerSecond = (loaded.length * 1000 / readMilliseconds).round();
  print(
    jsonEncode({
      'benchmark': 'bulkRoundTrip',
      'rows': rows.length,
      'writeMilliseconds': stopwatch.elapsedMilliseconds,
      'writeRowsPerSecond': rowsPerSecond,
      'readMilliseconds': readStopwatch.elapsedMilliseconds,
      'readRowsPerSecond': readRowsPerSecond,
    }),
  );
  await loom.close();

  final minimumWrite = arguments.isEmpty ? null : int.parse(arguments[0]);
  final minimumRead = arguments.length < 2
      ? minimumWrite
      : int.parse(arguments[1]);
  if (minimumWrite != null && rowsPerSecond < minimumWrite) {
    stderr.writeln(
      'insertAll throughput $rowsPerSecond rows/s is below '
      '$minimumWrite rows/s',
    );
    exitCode = 1;
  }
  if (minimumRead != null && readRowsPerSecond < minimumRead) {
    stderr.writeln(
      'typed read throughput $readRowsPerSecond rows/s is below '
      '$minimumRead rows/s',
    );
    exitCode = 1;
  }
}

final class _BenchmarkTable extends DbTable<({int id, String value}), int> {
  const _BenchmarkTable();
  static final id = integer('id');
  static final value = text('value');
  @override
  String get tableName => 'benchmark_rows';
  @override
  DbColumn<int> get primaryKey => id;
  @override
  ({int id, String value}) decode(DbRow row) =>
      (id: row.get(id), value: row.get(value));
  @override
  DbValues encode(({int id, String value}) row) =>
      DbValues({id: row.id, value: row.value});
  @override
  int keyOf(({int id, String value}) row) => row.id;
}
