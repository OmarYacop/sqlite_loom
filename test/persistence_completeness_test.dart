import 'package:sqlite_loom/sqlite_loom.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'query_composition_test.dart' show Item, Items, ItemSession, item;

final class BrokenItems extends DbTable<Item, int> {
  const BrokenItems();
  @override
  String get tableName => 'items';
  @override
  DbColumn<int> get primaryKey => Items.id;
  @override
  Item decode(DbRow row) => throw StateError('decoder failed');
  @override
  DbValues encode(Item row) => const Items().encode(row);
  @override
  int keyOf(Item row) => row.id;
}

final class NullableItems extends DbTable<Item, int> {
  const NullableItems();
  static final name = nullableText('name');
  @override
  String get tableName => 'items';
  @override
  DbColumn<int> get primaryKey => Items.id;
  @override
  Iterable<AnyDbColumn> get columns => [
    Items.id,
    name,
    Items.parent,
    Items.active,
  ];
  @override
  Item decode(DbRow row) => (
    id: row.get(Items.id),
    name: row.get(name) ?? '',
    parent: row.get(Items.parent),
    active: row.get(Items.active),
  );
  @override
  DbValues encode(Item row) => const Items().encode(row);
  @override
  int keyOf(Item row) => row.id;
}

void main() {
  sqfliteFfiInit();
  late SqliteLoom db;
  late Database raw;
  final observations = <DbObservation>[];
  final changes = <DbChangeSet>[];
  setUp(() async {
    observations.clear();
    changes.clear();
    raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await raw.execute(
      'CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT NOT NULL, parent INTEGER NOT NULL, active INTEGER NOT NULL)',
    );
    db = SqliteLoom(raw, observer: observations.add);
    final subscription = db.changes.listen(changes.add);
    addTearDown(subscription.cancel);
  });
  tearDown(() => db.close());

  test('explicit row ID zero invalidates single and batch inserts', () async {
    await db.items.insert(item(0));
    expect(changes, hasLength(1));
    await db.items.whereKey(0).delete();
    changes.clear();
    await db.items.insertAll([item(0)]);
    expect(changes, hasLength(1));
    expect(await db.items.find(0), isNotNull);
    changes.clear();
    await expectLater(
      db.transaction((tx) async {
        await tx.items.insert(item(1));
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    expect(changes, isEmpty);
  });

  test('generated row ID zero is a successful insert', () async {
    await db.items.insert(item(-1));
    changes.clear();
    final id = await db.items.insertValues(
      DbValues.fromAssignments([
        Items.name.set('generated'),
        Items.parent.set(1),
        Items.active.set(true),
      ]),
    );
    expect(id, 0);
    expect(changes, hasLength(1));
    await db.items.whereKey(0).delete();
    changes.clear();
    final ignoredModeId = await db.items.insertValues(
      DbValues.fromAssignments([
        Items.name.set('generated with ignore'),
        Items.parent.set(1),
        Items.active.set(true),
      ]),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    expect(ignoredModeId, 0);
    expect(changes, hasLength(1));
  });

  test(
    'nullable merged cursors follow SQLite null ordering without gaps',
    () async {
      await raw.execute('DROP TABLE items');
      await raw.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT, parent INTEGER NOT NULL, active INTEGER NOT NULL)',
      );
      for (var id = 0; id < 12; id++) {
        await raw.insert('items', {
          'id': id,
          'name': id % 3 == 0 ? null : 'same',
          'parent': 1,
          'active': 1,
        });
      }
      final merged = DbMergedRelationships<Item, int, Item>([
        for (final first in [true, false])
          dbMergedRelationshipSource(
            relationship: DbHasMany<Item, int, Item, int>(
              parent: const Items(),
              children: const NullableItems(),
              foreignKey: Items.parent,
              foreignKeyOf: (row) => row.parent,
            ),
            cursorColumn: NullableItems.name,
            convert: (Item row) => row,
            transform: (query) => query.where(
              first ? Items.id.lessThan(6) : Items.id.greaterThanOrEquals(6),
            ),
          ),
      ]);
      for (final descending in [false, true]) {
        final expected = (await merged.loadKeys(
          db,
          [1],
          limit: 20,
          descending: descending,
        ))[1]!;
        final actual = <Item>[];
        DbMergedContinuation? cursor;
        do {
          final page = await merged.loadPage(
            db,
            1,
            limit: 2,
            descending: descending,
            cursor: cursor,
          );
          actual.addAll(page.items);
          cursor = page.nextCursor;
          expect(actual.length, lessThanOrEqualTo(12));
        } while (cursor != null);
        expect(actual, expected);
      }
    },
  );

  test('returning records committed write before a decoder can fail', () async {
    await expectLater(
      db.table(const BrokenItems()).insertReturning(item(0)),
      throwsStateError,
    );
    expect(await db.items.count(), 1);
    expect(changes, hasLength(1));
    changes.clear();
    await expectLater(
      db.transaction(
        (tx) => tx.table(const BrokenItems()).insertReturning(item(1)),
      ),
      throwsStateError,
    );
    expect(await db.items.count(), 1);
    expect(changes, isEmpty);
  });

  test(
    'transaction statements and savepoints share a correlation ID',
    () async {
      await db.transaction((tx) async {
        await tx.items.insert(item(1));
        await tx.items.get();
        await tx.savepoint((nested) => nested.items.insertAll([item(2)]));
      });
      expect(
        observations.map((o) => o.operation),
        containsAll(['insert', 'query', 'batch', 'execute', 'transaction']),
      );
      expect(observations.map((o) => o.transactionId).toSet(), {0});
      expect(
        observations.map((o) => o.sequence).toSet().length,
        observations.length,
      );
      await expectLater(
        db.transaction((tx) => tx.items.insert(item(1))),
        throwsA(isA<DatabaseException>()),
      );
      expect(observations.last.transactionId, 1);
      expect(observations.last.succeeded, isFalse);
      await db.items.count();
      expect(observations.last.transactionId, isNull);
    },
  );

  test('complete schema validation includes generated columns', () async {
    await raw.execute(
      'ALTER TABLE items ADD COLUMN name_length INTEGER GENERATED ALWAYS AS (length(name)) VIRTUAL',
    );
    final result = await DbSchema(
      raw,
    ).validate([const Items()], requireAllColumns: true);
    expect(result.issues.map((issue) => issue.message), [
      'column name_length is not mapped',
    ]);
  });

  test('complete schema check is opt-in for partial mappings', () async {
    expect(
      (await DbSchema(raw).validate([const BrokenItems()])).isValid,
      isTrue,
    );
    final result = await DbSchema(
      raw,
    ).validate([const BrokenItems()], requireAllColumns: true);
    expect(
      result.issues.map((i) => i.message),
      containsAll([
        'column name is not mapped',
        'column parent is not mapped',
        'column active is not mapped',
      ]),
    );
    expect(
      (await DbSchema(
        raw,
      ).validate([const Items()], requireAllColumns: true)).isValid,
      isTrue,
    );
  });

  for (final descending in [false, true]) {
    test(
      'merged continuation preserves ties, descending=$descending',
      () async {
        await db.items.insertAll(
          List.generate(15, (i) => item(i, name: 'group${i ~/ 6}')),
        );
        DbMergedRelationships<Item, int, Item> feed() => DbMergedRelationships([
          for (final active in [true, false])
            dbMergedRelationshipSource(
              relationship: DbHasMany<Item, int, Item, int>(
                parent: const Items(),
                children: const Items(),
                foreignKey: Items.parent,
                foreignKeyOf: (row) => row.parent,
              ),
              cursorColumn: Items.name,
              convert: (Item row) => row,
              transform: (query) => query.where(
                active ? Items.id.lessThan(8) : Items.id.greaterThanOrEquals(8),
              ),
            ),
        ]);
        final merged = feed();
        final expected = (await merged.loadKeys(
          db,
          [1],
          limit: 100,
          descending: descending,
        ))[1]!;
        for (final size in [1, 2, 4, 6, 15, 20]) {
          final actual = <Item>[];
          DbMergedContinuation? cursor;
          do {
            final page = await merged.loadPage(
              db,
              1,
              limit: size,
              descending: descending,
              cursor: cursor,
            );
            actual.addAll(page.items);
            cursor = page.nextCursor;
            expect(actual.length, lessThanOrEqualTo(15));
          } while (cursor != null);
          expect(actual, expected);
        }
        final first = await merged.loadPage(
          db,
          1,
          limit: 1,
          descending: descending,
        );
        await expectLater(
          merged.loadPage(
            db,
            2,
            limit: 1,
            descending: descending,
            cursor: first.nextCursor,
          ),
          throwsArgumentError,
        );
        await expectLater(
          feed().loadPage(
            db,
            1,
            limit: 1,
            descending: descending,
            cursor: first.nextCursor,
          ),
          throwsArgumentError,
        );
        await expectLater(
          merged.loadPage(
            db,
            1,
            limit: 1,
            descending: !descending,
            cursor: first.nextCursor,
          ),
          throwsArgumentError,
        );
      },
    );
  }
}
