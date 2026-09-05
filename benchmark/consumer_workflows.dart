import 'dart:convert';
import 'dart:io';

import 'package:sqlite_loom/sqlite_loom.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../example/transactional_cache.dart';

/// Informational disk-backed workload. No machine-dependent throughput gate.
Future<void> main() async {
  sqfliteFfiInit();
  final directory = await Directory.systemTemp.createTemp('loom-consumer-');
  final observations = <DbObservation>[];
  final raw = await databaseFactoryFfi.openDatabase(
    '${directory.path}/cache.db',
  );
  await cacheProject.migrate(raw);
  final db = SqliteLoom(raw, observer: observations.add);
  try {
    await db.configure(writeAheadLogging: true);
    final time = DateTime.utc(2026, 9, 5);
    final watch = Stopwatch()..start();
    for (var page = 0; page < 20; page++) {
      await persistPage(
        db,
        [
          for (var i = 0; i < 500; i++)
            (
              id: page * 500 + i,
              title: 'Cached entry $i',
              modifiedAt: time.add(Duration(seconds: i ~/ 10)),
            ),
        ],
        scope: 'upcoming',
        nextCursor: 'page-${page + 1}',
      );
    }
    final writeMicros = watch.elapsedMicroseconds;
    watch.reset();
    var count = 0;
    await for (final page in db.entries.keysetPagesBy([
      DbCursorColumn(CacheEntries.modifiedAt),
      DbCursorColumn(CacheEntries.id),
    ], size: 100)) {
      count += page.length;
    }
    final readMicros = watch.elapsedMicroseconds;
    if (count != 10000 ||
        (await db.syncStates.find('upcoming'))!.cursor != 'page-20') {
      throw StateError('Consumer benchmark lost rows or sync state');
    }
    print(
      jsonEncode({
        'benchmark': 'diskCacheSyncAndCompositePagination',
        'rows': count,
        'syncPages': 20,
        'rowsPerReadPage': 100,
        'writeMicroseconds': writeMicros,
        'readMicroseconds': readMicros,
        'transactionStatements': observations
            .where(
              (e) => e.transactionId != null && e.operation != 'transaction',
            )
            .length,
        'transactions': observations
            .where((e) => e.operation == 'transaction')
            .length,
        'sqliteVersion': (await db.capabilities()).version.toString(),
      }),
    );
  } finally {
    await db.close();
    await directory.delete(recursive: true);
  }
}
