import 'package:sqlite_loom/sqlite_loom.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import '../example/transactional_cache.dart';

void main() {
  sqfliteFfiInit();
  test(
    'cache pages and their sync cursor commit or roll back together',
    () async {
      final handle = cacheProject.database(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      final db = await handle.ready;
      addTearDown(handle.close);
      final time = DateTime.utc(2026, 9, 5);
      await persistPage(
        db,
        [(id: 1, title: 'Original', modifiedAt: time)],
        scope: 'schedule',
        nextCursor: 'first',
      );
      final changes = <DbChangeSet>[];
      final subscription = db.changes.listen(changes.add);
      Iterable<CacheEntry> failingPage() sync* {
        for (var i = 0; i < 401; i++) {
          yield (id: i + 1, title: 'Changed', modifiedAt: time);
        }
        throw StateError('download iterator failed');
      }

      await expectLater(
        persistPage(db, failingPage(), scope: 'schedule', nextCursor: 'second'),
        throwsStateError,
      );
      expect(await db.entries.count(), 1);
      expect((await db.entries.find(1))!.title, 'Original');
      expect((await db.syncStates.find('schedule'))!.cursor, 'first');
      expect(changes, isEmpty);
      final committed = db.changes.first;
      await persistPage(
        db,
        [(id: 2, title: 'New', modifiedAt: time)],
        scope: 'schedule',
        nextCursor: 'second',
      );
      expect(
        (await committed).changes.map((change) => change.table),
        containsAll([const CacheEntries().tableId, const SyncStates().tableId]),
      );
      expect((await db.syncStates.find('schedule'))!.cursor, 'second');
      final pages = await db.entries.keysetPagesBy([
        DbCursorColumn(CacheEntries.modifiedAt),
        DbCursorColumn(CacheEntries.id),
      ], size: 1).toList();
      expect(pages.expand((page) => page).map((row) => row.id), [1, 2]);
      await subscription.cancel();
    },
  );
}
