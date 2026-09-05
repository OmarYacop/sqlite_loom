import 'package:sqlite_loom/sqlite_loom.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

typedef CacheEntry = ({int id, String title, DateTime modifiedAt});
typedef SyncState = ({String scope, String? cursor});

final class CacheEntries extends DbTable<CacheEntry, int> {
  const CacheEntries();
  static final id = integer('id');
  static final title = text('title');
  static final modifiedAt = dateTime('modified_at');
  @override
  String get tableName => 'cache_entries';
  @override
  DbColumn<int> get primaryKey => id;
  @override
  Iterable<AnyDbColumn> get columns => [id, title, modifiedAt];
  @override
  CacheEntry decode(DbRow row) =>
      (id: row.get(id), title: row.get(title), modifiedAt: row.get(modifiedAt));
  @override
  DbValues encode(CacheEntry row) => DbValues.fromAssignments([
    id.set(row.id),
    title.set(row.title),
    modifiedAt.set(row.modifiedAt),
  ]);
  @override
  int keyOf(CacheEntry row) => row.id;
}

final class SyncStates extends DbTable<SyncState, String> {
  const SyncStates();
  static final scope = text('scope');
  static final cursor = nullableText('cursor');
  @override
  String get tableName => 'sync_states';
  @override
  DbColumn<String> get primaryKey => scope;
  @override
  Iterable<AnyDbColumn> get columns => [scope, cursor];
  @override
  SyncState decode(DbRow row) =>
      (scope: row.get(scope), cursor: row.get(cursor));
  @override
  DbValues encode(SyncState row) =>
      DbValues.fromAssignments([scope.set(row.scope), cursor.set(row.cursor)]);
  @override
  String keyOf(SyncState row) => row.scope;
}

// One extension serves normal reads, transactions, and savepoints.
extension CacheTables on DbSession {
  DbTableQuery<CacheEntry, int> get entries => table(const CacheEntries());
  DbTableQuery<SyncState, String> get syncStates => table(const SyncStates());
}

final cacheProject = SqliteLoomProject([
  CallbackDbMigration(
    version: 1,
    name: 'cache',
    up: (migration) async {
      await migration.schema.createTable('cache_entries', (table) {
        table.integer('id').primaryKey();
        table.text('title').notNull();
        table.dateTime('modified_at').notNull();
      });
      await migration.schema.createTable('sync_states', (table) {
        table.text('scope').primaryKey();
        table.text('cursor');
      });
    },
  ),
]);

/// The application decides what constitutes a page and when its cursor advances.
/// Loom provides atomicity, incremental batches, codecs and invalidation.
Future<void> persistPage(
  SqliteLoom db,
  Iterable<CacheEntry> entries, {
  required String scope,
  required String? nextCursor,
}) => db.transaction((tx) async {
  await tx.entries.upsertAll(entries, batchSize: 400);
  await tx.syncStates.upsert((scope: scope, cursor: nextCursor));
});

Future<void> main() async {
  sqfliteFfiInit();
  final handle = cacheProject.database(
    factory: databaseFactoryFfi,
    path: inMemoryDatabasePath,
  );
  final db = await handle.ready;
  try {
    await persistPage(
      db,
      [
        (id: 1, title: 'First', modifiedAt: DateTime.utc(2026, 9, 5)),
        (id: 2, title: 'Second', modifiedAt: DateTime.utc(2026, 9, 5)),
      ],
      scope: 'upcoming',
      nextCursor: 'page-2',
    );
    await for (final page in db.entries.keysetPagesBy([
      DbCursorColumn(CacheEntries.modifiedAt),
      DbCursorColumn(CacheEntries.id),
    ], size: 1)) {
      print(page.map((entry) => entry.title).join(', '));
    }
  } finally {
    await handle.close();
  }
}
