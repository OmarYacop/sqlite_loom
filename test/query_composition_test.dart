import 'dart:async';
import 'dart:typed_data';

import 'package:sqlite_loom/sqlite_loom.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

typedef Item = ({int id, String name, int parent, bool active});

final class Items extends DbTable<Item, int> {
  const Items();
  static final id = integer('id');
  static final name = text('name');
  static final parent = integer('parent');
  static final active = boolean('active');
  @override
  String get tableName => 'items';
  @override
  DbColumn<int> get primaryKey => id;
  @override
  Iterable<AnyDbColumn> get columns => [id, name, parent, active];
  @override
  Item decode(DbRow row) => (
    id: row.get(id),
    name: row.get(name),
    parent: row.get(parent),
    active: row.get(active),
  );
  @override
  DbValues encode(Item row) => DbValues.fromAssignments([
    id.set(row.id),
    name.set(row.name),
    parent.set(row.parent),
    active.set(row.active),
  ]);
  @override
  int keyOf(Item row) => row.id;
}

extension ItemSession on DbSession {
  DbTableQuery<Item, int> get items => table(const Items());
}

Item item(int id, {String? name, int parent = 1}) =>
    (id: id, name: name ?? 'name$id', parent: parent, active: true);

void main() {
  sqfliteFfiInit();
  late SqliteLoom db;
  var batches = 0;
  Completer<void>? nextRead;
  setUp(() async {
    batches = 0;
    final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    db = SqliteLoom(
      raw,
      observer: (event) {
        if (event.operation == 'batch' && event.succeeded) batches++;
        if (event.operation == 'query' &&
            event.succeeded &&
            nextRead != null &&
            !nextRead!.isCompleted)
          nextRead!.complete();
      },
    );
    await raw.execute(
      'CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT NOT NULL, parent INTEGER NOT NULL, active INTEGER NOT NULL)',
    );
  });
  tearDown(() => db.close());

  test('offset-only SQL works for compile, explain and projections', () async {
    await db.items.insertAll([item(1), item(2), item(3)]);
    final query = db.items.orderBy(Items.id.ascending()).offset(1);
    expect(query.compile().sql, contains('LIMIT -1 OFFSET 1'));
    expect(await query.explain(), isNotEmpty);
    expect((await query.select([Items.id]).get()).map((r) => r.get(Items.id)), [
      2,
      3,
    ]);
    expect((await query.get()).map((r) => r.id), [2, 3]);
  });

  for (final keyset in [false, true]) {
    test(
      '${keyset ? 'cursor' : 'offset'} pages honor limits and initial offsets',
      () async {
        await db.items.insertAll(List.generate(9, (i) => item(i + 1)));
        for (final limit in [0, 1, 3, 4, 20]) {
          for (final offset in [0, 2, 20]) {
            final query = db.items
                .orderBy(Items.id.ascending())
                .offset(offset)
                .limit(limit);
            final expected = (await query.get()).map((r) => r.id).toList();
            final pages =
                await (keyset
                        ? query.keysetPages(Items.id, size: 2)
                        : query.pages(size: 2))
                    .toList();
            expect(pages.expand((p) => p).map((r) => r.id), expected);
          }
        }
      },
    );
  }

  test(
    'keysets reject incompatible sorting instead of skipping rows',
    () async {
      await db.items.insertAll([
        item(1, name: 'z'),
        item(2, name: 'a'),
        item(3, name: 'b'),
      ]);
      await expectLater(
        db.items
            .orderBy(Items.name.ascending())
            .keysetPages(Items.id, size: 2)
            .toList(),
        throwsStateError,
      );
      await expectLater(
        db.items.orderBy(Items.id.descending()).keysetPages(Items.id).toList(),
        throwsStateError,
      );
      final pages = await db.items
          .orderBy(Items.id.descending())
          .keysetPages(Items.id, descending: true, size: 2)
          .toList();
      expect(pages.expand((p) => p).map((r) => r.id), [3, 2, 1]);
    },
  );

  test(
    'composite cursors traverse ties and mixed directions exactly once',
    () async {
      await db.items.insertAll(
        List.generate(23, (i) => item(i + 1, name: 'group${i % 3}')),
      );
      for (final descending in [false, true]) {
        final name = DbCursorColumn(Items.name, descending: descending);
        final id = DbCursorColumn(Items.id, descending: !descending);
        final ordered = db.items.orderBy(name.ordering).orderBy(id.ordering);
        final expected = await ordered.get();
        final pages = await ordered.keysetPagesBy([name, id], size: 2).toList();
        expect(pages.expand((p) => p), expected);
        final bound = expected[7];
        expect(
          await db.items.afterCursor([
            name.at(bound.name),
            id.at(bound.id),
          ]).get(),
          expected.skip(8),
        );
      }
      expect(() => db.items.afterCursor([]), throwsArgumentError);
      expect(
        () => db.items.afterCursor([
          DbCursorColumn(Items.id).at(1),
          DbCursorColumn(Items.id).at(2),
        ]),
        throwsArgumentError,
      );
      expect(
        () => DbCursorColumn(nullableInteger('nullable')),
        throwsArgumentError,
      );
      expect(
        () => db.items.offset(2).afterCursor([DbCursorColumn(Items.id).at(1)]),
        throwsStateError,
      );
    },
  );

  test(
    'all mutation terminals reject read modifiers without changing rows',
    () async {
      await db.items.insertAll([item(1), item(2), item(3)]);
      for (final q in [
        db.items.whereKey(1).limit(1),
        db.items.allRows().offset(0),
        db.items.allRows().orderBy(Items.id.ascending()),
      ]) {
        final values = DbValues.fromAssignments([Items.active.set(false)]);
        await expectLater(q.delete(), throwsStateError);
        await expectLater(q.update(values), throwsStateError);
        await expectLater(q.deleteReturning(), throwsStateError);
        await expectLater(q.updateReturning(values), throwsStateError);
      }
      await expectLater(
        db.items
            .whereKey(1)
            .limit(1)
            .updateIfVersion(
              Items.parent,
              1,
              DbValues.fromAssignments([Items.active.set(false)]),
            ),
        throwsStateError,
      );
      expect(await db.items.count(), 3);
      expect(await db.items.where(Items.active.equals(false)).count(), 0);
    },
  );

  test(
    'typed assignments encode nullable and boolean values and reject duplicates',
    () async {
      await db.items.insert(item(1));
      await db.items
          .whereKey(1)
          .update(DbValues.fromAssignments([Items.active.set(false)]));
      expect((await db.items.find(1))!.active, false);
      expect(DbValues.fromAssignments([nullableText('note').set(null)]).asMap, {
        'note': null,
      });
      expect(
        () => DbValues.fromAssignments([Items.id.set(1), Items.id.set(2)]),
        throwsArgumentError,
      );
    },
  );

  final children = DbHasMany<Item, int, Item, int>(
    parent: const Items(),
    children: const Items(),
    foreignKey: Items.parent,
    foreignKeyOf: (row) => row.parent,
  );
  test(
    'same session extension, relationships and joins work in transactions',
    () async {
      await db.transaction((tx) async {
        await tx.items.insertAll([item(1), item(2)]);
        expect(await children.load(tx, item(1)), hasLength(2));
        expect((await children.loadAllBatched(tx, [item(1)]))[1], hasLength(2));
        expect(
          (await children.loadAllLimited(tx, [item(1)], limit: 1))[1],
          hasLength(1),
        );
        final parent = DbJoinColumn('p', Items.id);
        final child = DbJoinColumn('c', Items.parent);
        final selection = tx
            .joinFrom(const Items(), as: 'p')
            .innerJoin(const Items(), as: 'c', on: parent.equalsColumn(child))
            .select([parent, child]);
        expect(await selection.count(), 2);
        expect(await selection.get(), hasLength(2));
        expect(() => selection.watch(), throwsStateError);
        expect(() => children.watch(tx, item(1)), throwsStateError);
        expect(() => children.watchAll(tx, [item(1)]), throwsStateError);
        await tx.savepoint((nested) async {
          expect(await children.load(nested, item(1)), hasLength(2));
        });
      });
      await expectLater(
        db.transaction((tx) async {
          await tx.items.insert(item(3));
          expect(await children.load(tx, item(1)), hasLength(3));
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect(await db.items.count(), 2);
    },
  );

  for (final upsert in [false, true]) {
    test(
      '${upsert ? 'upsert' : 'insert'} consumes sized input only after each batch completes',
      () async {
        Iterable<Item> input() sync* {
          for (var i = 0; i < 5; i++) {
            expect(batches, i ~/ 2);
            yield item(i + 1);
          }
        }

        if (upsert) {
          await db.items.upsertAll(input(), batchSize: 2);
        } else {
          await db.items.insertAll(input(), batchSize: 2);
        }
        expect(await db.items.count(), 5);
        expect(batches, 3);
        await expectLater(
          db.items.insertAll([], batchSize: 0),
          throwsArgumentError,
        );
        await expectLater(
          db.items.upsertAll([], batchSize: -1),
          throwsArgumentError,
        );
      },
    );
  }

  test(
    'transaction rolls back previous chunks after a later chunk fails',
    () async {
      final changes = <DbChangeSet>[];
      final subscription = db.changes.listen(changes.add);
      await expectLater(
        db.transaction(
          (tx) => tx.items.insertAll([item(1), item(2), item(1)], batchSize: 2),
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(await db.items.count(), 0);
      await subscription.cancel();
      expect(changes, isEmpty);
    },
  );

  test('primary key changes refresh a watcher on the new key', () async {
    await db.items.insert(item(1));
    final values = StreamIterator(db.items.whereKey(2).watchFirstOrNull());
    try {
      expect(await values.moveNext(), true);
      expect(values.current, isNull);
      await db.items
          .whereKey(1)
          .update(DbValues.fromAssignments([Items.id.set(2)]));
      expect(await values.moveNext().timeout(const Duration(seconds: 3)), true);
      expect(values.current!.id, 2);
    } finally {
      await values.cancel();
    }
  });

  test('unique-key replacements invalidate the removed primary key', () async {
    await db.database.execute('CREATE UNIQUE INDEX item_name ON items(name)');
    await db.items.insert(item(1, name: 'same'));
    final values = StreamIterator(db.items.whereKey(1).watchFirstOrNull());
    try {
      await values.moveNext();
      expect(values.current!.id, 1);
      await db.items.insert(
        item(2, name: 'same'),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      expect(await values.moveNext().timeout(const Duration(seconds: 3)), true);
      expect(values.current, isNull);
    } finally {
      await values.cancel();
    }
  });
  test('first terminals preserve an explicit zero limit', () async {
    await db.items.insert(item(1));
    expect(await db.items.limit(0).firstOrNull(), isNull);
    expect(await db.items.limit(0).pluck(Items.name).firstOrNull(), isNull);
    expect(
      await db.items.limit(0).groupBy([Items.parent]).select([
        Items.parent,
      ]).firstOrNull(),
      isNull,
    );
    expect(
      await db.joinFrom(const Items(), as: 'i').limit(0).select([
        DbJoinColumn('i', Items.id),
      ]).firstOrNull(),
      isNull,
    );
    expect(await db.items.limit(0).count(), 1);
    expect(await db.items.limit(0).exists(), true);
  });

  test('join null equality and immutable unique projection aliases', () async {
    await db.items.insert(item(1));
    await db.database.execute('ALTER TABLE items ADD COLUMN note TEXT');
    final note = DbJoinColumn('i', nullableText('note'));
    final columns = <AnyDbJoinColumn>[note];
    final selection = db
        .joinFrom(const Items(), as: 'i')
        .where(note.equalsValue(null))
        .select(columns);
    columns.clear();
    expect(await selection.count(), 1);
    expect(() => selection.columns.clear(), throwsUnsupportedError);
    expect(
      () => db.joinFrom(const Items(), as: 'i').select([note, note]),
      throwsArgumentError,
    );
  });

  test(
    'projected BLOB reloads suppress equal values and emit actual changes',
    () async {
      await db.items.insert(item(1));
      await db.database.execute('ALTER TABLE items ADD COLUMN payload BLOB');
      await db.database.update('items', {
        'payload': Uint8List.fromList([1, 2]),
      });
      final payload = blob('payload');
      for (final selection in [false, true]) {
        final emissions = <Object?>[];
        final initial = Completer<void>();
        final stream = selection
            ? db.items.select([payload]).watch()
            : db.items.pluck(payload).watch();
        final subscription = stream.listen((value) {
          emissions.add(value);
          if (!initial.isCompleted) initial.complete();
        });
        await initial.future;
        nextRead = Completer<void>();
        db.invalidate({const Items().tableId});
        await nextRead!.future;
        await Future<void>.delayed(Duration.zero);
        expect(emissions, hasLength(1));
        await subscription.cancel();
        nextRead = null;
      }
    },
  );

  test('raw watches snapshot dependency and argument collections', () async {
    await db.items.insert(item(1));
    final dependencies = {const Items().tableId};
    final arguments = <Object?>[1];
    final stream = db.watchRaw(
      'SELECT name FROM items WHERE id = ?',
      arguments: arguments,
      dependsOn: dependencies,
    );
    arguments[0] = 999;
    dependencies.clear();
    final values = StreamIterator(stream);
    try {
      await values.moveNext();
      expect(values.current.single['name'], 'name1');
      await db.items
          .whereKey(1)
          .update(DbValues.fromAssignments([Items.name.set('changed')]));
      expect(await values.moveNext().timeout(const Duration(seconds: 3)), true);
      expect(values.current.single['name'], 'changed');
    } finally {
      await values.cancel();
    }
  });
}
