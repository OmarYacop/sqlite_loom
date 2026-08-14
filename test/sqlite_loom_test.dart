import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqlite_loom/sqlite_loom.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

void main() {
  sqfliteFfiInit();

  late Database database;
  late SqliteLoom db;

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    db = SqliteLoom(database);
    await database.execute('''
      CREATE TABLE chats (
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        note TEXT,
        archived INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      )
    ''');
  });

  tearDown(() async {
    await db.close();
  });

  test('detects and exposes runtime SQLite capabilities', () async {
    final capabilities = await db.capabilities();

    expect(capabilities.version.atLeast(3, 0), isTrue);
    expect(
      capabilities.supports(DbFeature.returning),
      capabilities.version.atLeast(3, 35),
    );
    expect(
      capabilities.supports(DbFeature.strictTables),
      capabilities.version.atLeast(3, 37),
    );
  });

  test('caches capability detection across guarded writes', () async {
    final first = db.capabilities();
    final second = db.capabilities();

    expect(identical(first, second), isTrue);
    await first;
  });

  test('parses SQLite versions with patch suffixes', () {
    final version = DbSqliteVersion.parse('3.45.2-custom');

    expect(version.toString(), '3.45.2');
    expect(version.atLeast(3, 45, 1), isTrue);
    expect(version.atLeast(3, 46), isFalse);
  });

  test('randomized typed predicates agree with Dart filtering', () async {
    final random = Random(0x51A7E);
    final now = DateTime.utc(2026, 7, 17, 12);
    final rows = List.generate(100, (index) {
      final token = String.fromCharCodes(
        List.generate(8, (_) => 97 + random.nextInt(26)),
      );
      return Chat(
        id: index + 1,
        title: token,
        archived: random.nextBool(),
        updatedAt: now,
      );
    });
    await db.chats.insertAll(rows);

    for (var iteration = 0; iteration < 40; iteration += 1) {
      final needle = String.fromCharCode(97 + random.nextInt(26));
      final archived = random.nextBool();
      final actual = await db.chats
          .where(
            ChatsTable.title.contains(needle) &
                ChatsTable.archived.equals(archived),
          )
          .orderBy(ChatsTable.id.ascending())
          .pluck(ChatsTable.id)
          .get();
      final expected = rows
          .where(
            (row) => row.title.contains(needle) && row.archived == archived,
          )
          .map((row) => row.id)
          .toList();
      expect(actual, expected, reason: 'iteration $iteration');
    }
  });

  test(
    'fuzzed identifiers and hostile values stay inside SQL boundaries',
    () async {
      final random = Random(0xF022);
      const alphabet = 'abcXYZ_0123456789';
      final schema = DbSchema(database);
      for (var iteration = 0; iteration < 30; iteration += 1) {
        final suffix = List.generate(
          10,
          (_) => alphabet[random.nextInt(alphabet.length)],
        ).join();
        final tableName = 'fuzz_$iteration$suffix';
        await schema.createTable(tableName, (table) {
          table.integer('id').primaryKey();
        });
        final rows = await database.query(
          'sqlite_master',
          columns: ['name'],
          where: 'type = ? AND name = ?',
          whereArgs: ['table', tableName],
        );
        expect(rows.single['name'], tableName);
        await schema.dropTable(tableName);
      }
      for (final hostileName in [
        'quoted"name',
        'semi;colon',
        'space name',
        'dash-name',
        'unicode_é',
      ]) {
        await expectLater(
          schema.createTable(hostileName, (table) {
            table.integer('id').primaryKey();
          }),
          throwsArgumentError,
        );
      }

      final now = DateTime.utc(2026, 7, 17, 12);
      const hostile = "' OR 1 = 1; DROP TABLE chats; -- %_\\\u0000";
      await db.chats.insert(
        Chat(id: 1, title: hostile, archived: false, updatedAt: now),
      );
      expect(await db.chats.where(ChatsTable.title.equals(hostile)).count(), 1);
      expect(await db.chats.where(ChatsTable.title.contains('%_')).count(), 1);
      expect(await db.chats.count(), 1);
    },
  );

  test('decodes typed rows and supports extension scopes', () async {
    final now = DateTime.utc(2026, 7, 17, 12);
    await db.chats.insert(
      Chat(id: 1, title: 'General', archived: false, updatedAt: now),
    );
    await db.chats.insert(
      Chat(id: 2, title: 'Archive', archived: true, updatedAt: now),
    );

    final rows = await db.chats
        .active()
        .orderBy(ChatsTable.id.ascending())
        .get();

    expect(rows, [
      Chat(id: 1, title: 'General', archived: false, updatedAt: now.toLocal()),
    ]);
  });

  test('empty inValues predicate is safe and never mutates all rows', () async {
    final now = DateTime.utc(2026, 7, 17, 12);
    await db.chats.insert(
      Chat(id: 1, title: 'General', archived: false, updatedAt: now),
    );
    await db.chats.insert(
      Chat(id: 2, title: 'Random', archived: false, updatedAt: now),
    );

    final affected = await db.chats
        .where(ChatsTable.id.inValues(const <int>[]))
        .delete();

    expect(affected, 0);
    expect(await db.chats.count(), 2);
  });

  test('nullable predicates compile to SQLite-safe null checks', () async {
    final now = DateTime.utc(2026, 7, 17, 12);
    await db.chats.insert(
      Chat(
        id: 1,
        title: 'General',
        note: null,
        archived: false,
        updatedAt: now,
      ),
    );
    await db.chats.insert(
      Chat(
        id: 2,
        title: 'Random',
        note: 'pinned',
        archived: false,
        updatedAt: now,
      ),
    );

    expect(await db.chats.where(ChatsTable.note.equals(null)).count(), 1);
    expect(await db.chats.where(ChatsTable.note.notEquals(null)).count(), 1);
    expect(
      await db.chats
          .where(ChatsTable.note.inValues(const [null, 'pinned']))
          .count(),
      2,
    );
    expect(
      await db.chats.where(ChatsTable.note.notInValues(const [null])).count(),
      1,
    );
    expect(await db.chats.where(ChatsTable.note.lessThan('z')).count(), 1);
  });

  test('insert publishes changed primary keys', () async {
    final changeFuture = db.changes.first;
    await db.chats.insert(
      Chat(
        id: 7,
        title: 'General',
        archived: false,
        updatedAt: DateTime.utc(2026, 7, 17, 12),
      ),
    );

    final change = await changeFuture;
    expect(change[const ChatsTable().tableId]?.keys, {7});
  });

  test(
    'manual invalidation refreshes writes made through a raw handle',
    () async {
      final emissions = <List<Chat>>[];
      final refreshed = Completer<List<Chat>>();
      final subscription = db.chats.watch().listen((rows) {
        emissions.add(rows);
        if (emissions.length == 2) refreshed.complete(rows);
      });
      while (emissions.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await database.insert('chats', {
        'id': 9,
        'title': 'External abstraction',
        'archived': 0,
        'updated_at': DateTime.utc(2026, 7, 17).millisecondsSinceEpoch,
      });

      db.invalidate({const ChatsTable().tableId});

      expect((await refreshed.future).single.id, 9);
      await subscription.cancel();
    },
  );

  test(
    'data-version monitor refreshes writes from another connection',
    () async {
      final directory = await Directory.systemTemp.createTemp('loom_external_');
      final path = '${directory.path}/external.sqlite';
      final first = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final second = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final loom = SqliteLoom(first);
      DbExternalChangeMonitor? monitor;
      StreamSubscription<List<Chat>>? subscription;
      try {
        await first.execute('''
        CREATE TABLE chats (
          id INTEGER PRIMARY KEY,
          title TEXT NOT NULL,
          note TEXT,
          archived INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL
        )
      ''');
        monitor = await loom.monitorExternalChanges(
          tables: {const ChatsTable().tableId},
          interval: const Duration(hours: 1),
        );
        final emissions = <List<Chat>>[];
        final refreshed = Completer<List<Chat>>();
        subscription = loom.chats.watch().listen((rows) {
          emissions.add(rows);
          if (emissions.length == 2) refreshed.complete(rows);
        });
        while (emissions.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        await second.insert('chats', {
          'id': 10,
          'title': 'Other connection',
          'archived': 0,
          'updated_at': DateTime.utc(2026, 7, 17).millisecondsSinceEpoch,
        });

        expect(await monitor.checkNow(), isTrue);
        expect((await refreshed.future).single.id, 10);
      } finally {
        await subscription?.cancel();
        await monitor?.close();
        await loom.close();
        await second.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'update and delete require explicit allRows for whole-table mutation',
    () async {
      expect(
        () => db.chats.update(DbValues({ChatsTable.title: 'Changed'})),
        throwsA(isA<StateError>()),
      );
      expect(() => db.chats.delete(), throwsA(isA<StateError>()));
    },
  );

  test(
    'watch emits initial result and coalesces committed transaction changes',
    () async {
      final emissions = <List<Chat>>[];
      final initialEmission = Completer<List<Chat>>();
      final secondEmission = Completer<List<Chat>>();
      final subscription = db.chats
          .orderBy(ChatsTable.id.ascending())
          .watch()
          .listen((rows) {
            emissions.add(rows);
            if (!initialEmission.isCompleted) {
              initialEmission.complete(rows);
            } else if (!secondEmission.isCompleted) {
              secondEmission.complete(rows);
            }
          });

      expect(await initialEmission.future, isEmpty);

      final now = DateTime.utc(2026, 7, 17, 12);
      await db.transaction((tx) async {
        await tx.chats.insert(
          Chat(id: 1, title: 'General', archived: false, updatedAt: now),
        );
        await tx.chats.insert(
          Chat(id: 2, title: 'Random', archived: false, updatedAt: now),
        );
      });

      final rows = await secondEmission.future.timeout(
        const Duration(seconds: 2),
      );
      expect(rows.map((chat) => chat.id), [1, 2]);
      expect(emissions.length, 2);

      await subscription.cancel();
    },
  );

  test('rolled back transaction does not notify watchers', () async {
    final emissions = <int>[];
    final subscription = db.chats.watchCount().listen(emissions.add);
    await pumpEventQueue();

    await expectLater(
      db.transaction<void>((tx) async {
        await tx.chats.insert(
          Chat(
            id: 1,
            title: 'General',
            archived: false,
            updatedAt: DateTime.utc(2026, 7, 17, 12),
          ),
        );
        throw StateError('rollback');
      }),
      throwsA(isA<StateError>()),
    );
    await pumpEventQueue();

    expect(emissions, [0]);
    expect(await db.chats.count(), 0);

    await subscription.cancel();
  });

  test('transactions reject live query creation', () async {
    await db.transaction<void>((tx) async {
      expect(() => tx.chats.watch(), throwsA(isA<StateError>()));
    });
  });

  test('select reads only one typed column', () async {
    final now = DateTime.utc(2026, 7, 17, 12);
    await db.chats.insertAll([
      Chat(id: 1, title: 'Alpha', archived: false, updatedAt: now),
      Chat(id: 2, title: 'Beta', archived: false, updatedAt: now),
    ]);

    final titles = await db.chats
        .orderBy(ChatsTable.id.ascending())
        .pluck(ChatsTable.title)
        .get();

    expect(titles, ['Alpha', 'Beta']);
  });

  test('insertAll batches rows and publishes one keyed change', () async {
    final changes = <DbChangeSet>[];
    final subscription = db.changes.listen(changes.add);
    final now = DateTime.utc(2026, 7, 17, 12);

    await db.chats.insertAll([
      Chat(id: 10, title: 'Ten', archived: false, updatedAt: now),
      Chat(id: 11, title: 'Eleven', archived: false, updatedAt: now),
    ]);

    expect(await db.chats.count(), 2);
    expect(changes, hasLength(1));
    expect(changes.single[const ChatsTable().tableId]?.keys, {10, 11});
    await subscription.cancel();
  });

  test('upsert updates in place without SQLite replacement deletes', () async {
    await database.execute('CREATE TABLE chat_deletes (id INTEGER NOT NULL)');
    await database.execute('''
      CREATE TRIGGER record_chat_delete AFTER DELETE ON chats
      BEGIN
        INSERT INTO chat_deletes (id) VALUES (OLD.id);
      END
    ''');
    final now = DateTime.utc(2026, 7, 17, 12);
    await db.chats.insert(
      Chat(id: 1, title: 'Before', archived: false, updatedAt: now),
    );

    await db.chats.upsert(
      Chat(id: 1, title: 'After', archived: true, updatedAt: now),
    );

    expect((await db.chats.find(1))?.title, 'After');
    expect(await database.query('chat_deletes'), isEmpty);
  });

  test('upsertAll batches inserts and updates', () async {
    final now = DateTime.utc(2026, 7, 17, 12);
    await db.chats.insert(
      Chat(id: 1, title: 'Before', archived: false, updatedAt: now),
    );

    await db.chats.upsertAll([
      Chat(id: 1, title: 'After', archived: true, updatedAt: now),
      Chat(id: 2, title: 'New', archived: false, updatedAt: now),
    ]);

    final rows = await db.chats.orderBy(ChatsTable.id.ascending()).get();
    expect(rows.map((row) => row.title), ['After', 'New']);
  });

  test('key-scoped watch ignores changes to unrelated primary keys', () async {
    final emissions = <Chat?>[];
    final initial = Completer<void>();
    final target = Completer<void>();
    final subscription = db.chats.whereKey(1).watchFirstOrNull().listen((row) {
      emissions.add(row);
      if (!initial.isCompleted) initial.complete();
      if (row?.id == 1 && !target.isCompleted) target.complete();
    });
    await initial.future.timeout(const Duration(seconds: 5));
    final now = DateTime.utc(2026, 7, 17, 12);

    await db.chats.insert(
      Chat(id: 2, title: 'Other', archived: false, updatedAt: now),
    );
    await pumpEventQueue();
    expect(emissions, [null]);

    await db.chats.insert(
      Chat(id: 1, title: 'Target', archived: false, updatedAt: now),
    );
    await target.future.timeout(const Duration(seconds: 5));
    expect(emissions.map((row) => row?.id), [null, 1]);
    await subscription.cancel();
  });

  test('text predicates, keyset cursors, and aggregates compose', () async {
    final now = DateTime.utc(2026, 7, 17, 12);
    await db.chats.insertAll([
      Chat(id: 1, title: 'Alpha_1', archived: false, updatedAt: now),
      Chat(id: 2, title: 'alpha%2', archived: false, updatedAt: now),
      Chat(id: 3, title: 'Beta', archived: false, updatedAt: now),
    ]);

    expect(await db.chats.where(ChatsTable.title.contains('_1')).count(), 1);
    expect(await db.chats.after(ChatsTable.id, 1).pluck(ChatsTable.id).get(), [
      2,
      3,
    ]);
    expect(await db.chats.sum(ChatsTable.id), 6);
    expect(await db.chats.average(ChatsTable.id), 2);
    expect(await db.chats.minimum(ChatsTable.id), 1);
    expect(await db.chats.maximum(ChatsTable.id), 3);
  });

  test(
    'grouped selections expose typed aggregates, having, and plans',
    () async {
      final now = DateTime.utc(2026, 7, 17, 12);
      await db.chats.insertAll([
        Chat(id: 1, title: 'One', archived: false, updatedAt: now),
        Chat(id: 2, title: 'Two', archived: false, updatedAt: now),
        Chat(id: 3, title: 'Three', archived: true, updatedAt: now),
      ]);
      final rowCount = DbAggregate.count(as: 'row_count');
      final latest = DbAggregate.maximum(
        ChatsTable.updatedAt,
        as: 'latest_update',
      );
      final selection = db.chats
          .groupBy([ChatsTable.archived])
          .having(DbPredicate.trusted('COUNT(*) >= ?', [2]))
          .orderBy(const DbOrdering.trusted('row_count DESC'))
          .select([ChatsTable.archived, rowCount, latest]);

      final rows = await selection.get();

      expect(rows, hasLength(1));
      expect(rows.single.get(ChatsTable.archived), isFalse);
      expect(rows.single.get(rowCount.resultColumn), 2);
      expect(rows.single.get(latest.resultColumn), now.toLocal());
      expect(await selection.count(), 1);
      expect(selection.compile().sql, contains('HAVING'));
      expect(await selection.explain(), isNotEmpty);

      final paged = db.chats
          .groupBy([ChatsTable.archived])
          .orderBy(ChatsTable.archived.ascending())
          .limit(1)
          .select([ChatsTable.archived, rowCount]);
      expect(await paged.get(), hasLength(1));
      expect(await paged.count(), 2);
    },
  );

  test('select projects multiple columns into typed rows', () async {
    final now = DateTime.utc(2026, 7, 17, 12);
    await db.chats.insert(
      Chat(id: 1, title: 'Projected', archived: false, updatedAt: now),
    );

    final row = (await db.chats.select([
      ChatsTable.id,
      ChatsTable.title,
    ]).get()).single;
    expect(row.get(ChatsTable.id), 1);
    expect(row.get(ChatsTable.title), 'Projected');

    final decoded = await db.chats
        .select([ChatsTable.id, ChatsTable.title])
        .distinct()
        .decodeWith(
          (row) => '${row.get(ChatsTable.id)}:${row.get(ChatsTable.title)}',
        )
        .get();
    expect(decoded, ['1:Projected']);
  });

  test('queries compile and expose SQLite query plans', () async {
    await database.execute('CREATE INDEX chats_title_idx ON chats(title)');
    final query = db.chats.where(ChatsTable.title.equals('Indexed')).limit(1);

    final compiled = query.compile(columns: [ChatsTable.id]);
    final plan = await query.explain();

    expect(compiled.sql, contains('SELECT "id" FROM "chats"'));
    expect(compiled.arguments, ['Indexed']);
    expect(plan.any((row) => row.usesIndex('chats_title_idx')), isTrue);
  });

  test('keysetPages reads large queries in bounded pages', () async {
    final now = DateTime.utc(2026, 7, 17, 12);
    await db.chats.insertAll([
      for (var id = 1; id <= 5; id += 1)
        Chat(id: id, title: '$id', archived: false, updatedAt: now),
    ]);

    final pages = await db.chats.keysetPages(ChatsTable.id, size: 2).toList();

    expect(pages.map((page) => page.map((row) => row.id).toList()), [
      [1, 2],
      [3, 4],
      [5],
    ]);
  });

  test('JSON and BLOB codecs round-trip SQLite values', () async {
    final jsonColumn = jsonValue('payload');
    final blobColumn = blob('bytes');
    await database.execute(
      'CREATE TABLE payloads (id INTEGER PRIMARY KEY, payload TEXT, bytes BLOB)',
    );
    await database.insert('payloads', {
      'id': 1,
      'payload': jsonColumn.encode({'ready': true}),
      'bytes': blobColumn.encode(Uint8List.fromList([1, 2, 3])),
    });
    final row = (await database.query('payloads')).single;

    expect(jsonColumn.decode(row['payload']), {'ready': true});
    expect(blobColumn.decode(row['bytes']), Uint8List.fromList([1, 2, 3]));
  });

  test('raw reads can watch explicitly declared dependencies', () async {
    final emissions = <List<Map<String, Object?>>>[];
    final initial = Completer<void>();
    final changed = Completer<void>();
    final subscription = db
        .watchRaw(
          'SELECT COUNT(*) AS count FROM chats',
          dependsOn: {const DbTableId('chats')},
        )
        .listen((rows) {
          emissions.add(rows);
          if (!initial.isCompleted) {
            initial.complete();
          } else if (!changed.isCompleted) {
            changed.complete();
          }
        });
    await initial.future;

    await db.chats.insert(
      Chat(
        id: 1,
        title: 'Raw',
        archived: false,
        updatedAt: DateTime.utc(2026, 7, 17, 12),
      ),
    );
    await changed.future.timeout(const Duration(seconds: 2));

    expect(emissions.map((rows) => rows.single['count']), [0, 1]);
    await subscription.cancel();
  });

  test(
    'schema helpers support strict tables, columns, checks, and views',
    () async {
      final schema = DbSchema(database);
      await schema.createTable('metrics', (table) {
        table.integer('id').primaryKey();
        table.integer('score').notNull();
        table
            .integer('double_score')
            .generatedAs(const DbSqlLiteral('score * 2'), stored: true);
        table.text('note');
        table.check('score >= 0');
      }, strict: true);
      await schema.renameColumn('metrics', 'note', 'label');
      await schema.dropColumn('metrics', 'label');
      await schema.createView(
        'positive_metrics',
        const DbSqlLiteral('SELECT id FROM metrics'),
      );

      await database.insert('metrics', {'id': 1, 'score': 2});
      expect(await database.query('positive_metrics'), [
        {'id': 1},
      ]);
      expect((await database.query('metrics')).single['double_score'], 4);
      await expectLater(
        database.insert('metrics', {'id': 2, 'score': -1}),
        throwsA(anything),
      );
      await schema.dropView('positive_metrics');
    },
  );

  test('schema helpers create expression indexes and triggers', () async {
    final schema = DbSchema(database);
    await schema.createTable('audit', (table) {
      table.id();
      table.text('message').notNull();
    });
    await schema.createExpressionIndex('idx_chats_lower_title', 'chats', const [
      DbSqlLiteral('lower(title)'),
    ]);
    await schema.createTrigger(
      'trg_chats_audit',
      'chats',
      timing: DbTriggerTiming.after,
      event: DbTriggerEvent.insert,
      body: const DbSqlLiteral(
        "INSERT INTO audit(message) VALUES ('chat inserted')",
      ),
    );

    await db.chats.insert(
      Chat(
        id: 1,
        title: 'Tracked',
        archived: false,
        updatedAt: DateTime.utc(2026, 7, 17),
      ),
    );

    expect((await database.query('audit')).single['message'], 'chat inserted');
    await schema.dropTrigger('trg_chats_audit');
  });

  test('observer reports timings without bound arguments', () async {
    final observations = <DbObservation>[];
    final observedDatabase = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    final observed = SqliteLoom(
      observedDatabase,
      observer: observations.add,
      slowQueryThreshold: Duration.zero,
      observerContext: const {'database': 'test'},
    );
    await observed.rawRead('SELECT ? AS secret', arguments: ['hidden']);

    expect(observations, hasLength(1));
    expect(observations.single.operation, 'query');
    expect(observations.single.sql, 'SELECT ? AS secret');
    expect(observations.single.sqlFingerprint, 'SELECT ? AS secret');
    expect(observations.single.resultCount, 1);
    expect(observations.single.sequence, 0);
    expect(observations.single.startedAt, isNotNull);
    expect(observations.single.isSlow, isTrue);
    expect(observations.single.context, {'database': 'test'});
    await observed.close();
  });

  test('observer failures cannot change successful write semantics', () async {
    final observerErrors = <Object>[];
    final observed = SqliteLoom(
      database,
      observer: (_) => throw StateError('observer failed'),
      onObserverError: (error, _) => observerErrors.add(error),
    );

    await observed
        .table(const ChatsTable())
        .insert(
          Chat(
            id: 1,
            title: 'Committed',
            archived: false,
            updatedAt: DateTime.utc(2026, 7, 17, 12),
          ),
        );
    await observed.table(const ChatsTable()).insertAll([
      Chat(
        id: 2,
        title: 'Batch committed',
        archived: false,
        updatedAt: DateTime.utc(2026, 7, 17, 12),
      ),
    ]);

    expect(await observed.table(const ChatsTable()).count(), 2);
    expect(observerErrors, hasLength(3));
  });

  test('observer reports failed operations and transaction outcomes', () async {
    final observations = <DbObservation>[];
    final observedDatabase = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    final observed = SqliteLoom(observedDatabase, observer: observations.add);

    await expectLater(
      observed.rawRead('SELECT * FROM missing_table'),
      throwsA(anything),
    );
    await observed.transaction((_) async {});

    expect(
      observations.any(
        (event) => event.operation == 'query' && !event.succeeded,
      ),
      isTrue,
    );
    expect(
      observations.any(
        (event) => event.operation == 'transaction' && event.succeeded,
      ),
      isTrue,
    );
    await observed.close();
  });

  test('close is idempotent for lifecycle-safe cleanup', () async {
    final ownedDatabase = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    final owned = SqliteLoom(ownedDatabase);

    await Future.wait([owned.close(), owned.close()]);
    await owned.close();
  });

  test('cancelled live query suppresses an in-flight reload', () async {
    final changes = StreamController<DbChangeSet>.broadcast();
    final loadStarted = Completer<void>();
    final releaseLoad = Completer<int>();
    final emitted = <int>[];
    final live = DbLiveQuery<int>(
      changes: changes.stream,
      dependencies: {const DbTableId('delayed')},
      load: () {
        loadStarted.complete();
        return releaseLoad.future;
      },
      equals: (left, right) => left == right,
    );
    final subscription = live.stream.listen(emitted.add);
    await loadStarted.future.timeout(const Duration(seconds: 5));

    await subscription.cancel();
    releaseLoad.complete(1);
    await pumpEventQueue();

    expect(emitted, isEmpty);
    await changes.close();
  });

  test('connection configuration and integrity checks are exposed', () async {
    await db.configure(
      foreignKeys: true,
      busyTimeout: const Duration(seconds: 1),
      synchronous: DbSynchronous.normal,
    );

    expect(await db.integrityCheck(quick: true), ['ok']);
  });

  test('rolled-back savepoint discards data and reactive changes', () async {
    final changes = <DbChangeSet>[];
    final subscription = db.changes.listen(changes.add);
    final now = DateTime.utc(2026, 7, 17, 12);

    await db.transaction((tx) async {
      try {
        await tx.savepoint((nested) async {
          await nested
              .table(const ChatsTable())
              .insert(
                Chat(
                  id: 1,
                  title: 'Rolled back',
                  archived: false,
                  updatedAt: now,
                ),
              );
          throw StateError('rollback savepoint');
        });
      } on StateError {
        // The outer transaction remains usable.
      }
      await tx
          .table(const ChatsTable())
          .insert(
            Chat(id: 2, title: 'Committed', archived: false, updatedAt: now),
          );
    });

    final ids = await db.chats.pluck(ChatsTable.id).get();
    expect(ids, [2]);
    expect(changes.single[const ChatsTable().tableId]?.keys, {2});
    await subscription.cancel();
  });

  test('bulk writes can be split into bounded batches', () async {
    final now = DateTime.utc(2026, 7, 17, 12);
    await db.chats.insertAll([
      for (var id = 1; id <= 5; id += 1)
        Chat(id: id, title: '$id', archived: false, updatedAt: now),
    ], batchSize: 2);

    expect(await db.chats.count(), 5);
  });

  test('failed batch is atomic and publishes no reactive change', () async {
    final changes = <DbChangeSet>[];
    final subscription = db.changes.listen(changes.add);
    final now = DateTime.utc(2026, 7, 17, 12);

    await expectLater(
      db.chats.insertAll([
        Chat(id: 1, title: 'First', archived: false, updatedAt: now),
        Chat(id: 1, title: 'Duplicate', archived: false, updatedAt: now),
      ]),
      throwsA(anything),
    );
    await pumpEventQueue();

    expect(await db.chats.count(), 0);
    expect(changes, isEmpty);
    await subscription.cancel();
  });

  test('runtime schema validation checks declared column affinities', () async {
    final validation = await DbSchema(database).validate([const ChatsTable()]);

    expect(validation.isValid, isTrue);
  });

  test('runtime schema validation checks mapped primary keys', () async {
    await database.execute('CREATE TABLE invalid_pk (id INTEGER, name TEXT)');

    final result = await DbSchema(
      database,
    ).validate([const _InvalidPrimaryKeyTable()]);

    expect(result.isValid, isFalse);
    expect(
      result.issues.any(
        (issue) => issue.message.contains('is not a primary key'),
      ),
      isTrue,
    );
  });

  test('runtime schema validation catches unsafe SQL nullability', () async {
    await database.execute(
      'CREATE TABLE invalid_nullability (id INTEGER PRIMARY KEY, name TEXT)',
    );

    final result = await DbSchema(
      database,
    ).validate([const _InvalidNullabilityTable()]);

    expect(
      result.issues.any((issue) => issue.message.contains('permits NULL')),
      isTrue,
    );
  });

  test('runtime schema validation checks indexes and foreign keys', () async {
    await database.execute(
      'CREATE TABLE parents (id INTEGER PRIMARY KEY) STRICT',
    );
    await database.execute('''
      CREATE TABLE validated_children (
        id INTEGER PRIMARY KEY,
        parent_id INTEGER NOT NULL REFERENCES parents(id) ON DELETE CASCADE,
        name TEXT NOT NULL
      ) STRICT
    ''');
    await database.execute(
      'CREATE UNIQUE INDEX idx_validated_child_name '
      'ON validated_children(name)',
    );

    final valid = await DbSchema(
      database,
    ).validate([const _ValidatedChildTable()]);
    await database.execute('DROP INDEX idx_validated_child_name');
    final invalid = await DbSchema(
      database,
    ).validate([const _ValidatedChildTable()]);

    expect(valid.isValid, isTrue);
    expect(
      invalid.issues.any((issue) => issue.message.contains('index')),
      isTrue,
    );
  });

  test(
    'returning writes and optimistic versions avoid follow-up reads',
    () async {
      await database.execute(
        'ALTER TABLE chats ADD COLUMN version INTEGER NOT NULL DEFAULT 0',
      );
      final version = integer('version');
      final now = DateTime.utc(2026, 7, 17, 12);
      final inserted = await db.chats.insertReturning(
        Chat(id: 1, title: 'Initial', archived: false, updatedAt: now),
      );

      final updated = await db.chats
          .whereKey(1)
          .updateReturning(DbValues({ChatsTable.title: 'Updated'}));
      final won = await db.chats
          .whereKey(1)
          .updateIfVersion(version, 0, DbValues({ChatsTable.archived: true}));
      final lost = await db.chats
          .whereKey(1)
          .updateIfVersion(version, 0, DbValues({ChatsTable.archived: false}));
      final deleted = await db.chats.whereKey(1).deleteReturning();

      expect(inserted.title, 'Initial');
      expect(updated.single.title, 'Updated');
      expect(won, isTrue);
      expect(lost, isFalse);
      expect(deleted.single.archived, isTrue);
    },
  );

  test('optimistic updates require an exact primary-key scope', () async {
    final version = integer('version');
    await expectLater(
      db.chats.updateIfVersion(
        version,
        0,
        DbValues({ChatsTable.archived: true}),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('DbValues stringification redacts encoded values', () {
    final values = DbValues({ChatsTable.title: 'secret-token'});

    expect(values.toString(), contains('title'));
    expect(values.toString(), isNot(contains('secret-token')));
  });

  test(
    'join builder qualifies and decodes columns from multiple tables',
    () async {
      await database.execute(
        'CREATE TABLE tags (id INTEGER PRIMARY KEY, chat_id INTEGER, label TEXT)',
      );
      final now = DateTime.utc(2026, 7, 17, 12);
      await db.chats.insert(
        Chat(id: 1, title: 'Joined', archived: false, updatedAt: now),
      );
      await database.insert('tags', {'id': 5, 'chat_id': 1, 'label': 'work'});
      await database.insert('tags', {'id': 6, 'chat_id': 1, 'label': 'home'});
      await database.insert('tags', {'id': 7, 'chat_id': 1, 'label': 'work'});
      final chatId = DbJoinColumn('c', ChatsTable.id);
      final tagChatId = DbJoinColumn('t', TagsTable.chatId);
      final label = DbJoinColumn('t', TagsTable.label);

      final selection = db
          .joinFrom(const ChatsTable(), as: 'c')
          .innerJoin(
            const TagsTable(),
            as: 't',
            on: chatId.equalsColumn(tagChatId),
          )
          .orderBy(label.descending())
          .limit(2)
          .select([chatId, label]);
      final rows = await selection.get();
      final decoded = await selection
          .decodeWith((row) => row.get(label.resultColumn))
          .get();
      final distinct = await db
          .joinFrom(const ChatsTable(), as: 'c')
          .innerJoin(
            const TagsTable(),
            as: 't',
            on: chatId.equalsColumn(tagChatId),
          )
          .distinct()
          .orderBy(label.ascending())
          .select([label])
          .get();

      expect(rows.map((row) => row.get(chatId.resultColumn)), [1, 1]);
      expect(decoded, ['work', 'work']);
      expect(distinct.map((row) => row.get(label.resultColumn)), [
        'home',
        'work',
      ]);
      expect(await selection.count(), 3);
      expect(await selection.exists(), isTrue);
      expect(selection.compile().sql, contains('ORDER BY'));
      expect(await selection.explain(), isNotEmpty);
    },
  );

  test(
    'typed relationships load and group related rows without N+1 reads',
    () async {
      await database.execute(
        'CREATE TABLE tags (id INTEGER PRIMARY KEY, chat_id INTEGER, label TEXT)',
      );
      await database.execute(
        'CREATE TABLE notes ('
        'id INTEGER PRIMARY KEY, chat_id INTEGER, marker TEXT, body TEXT)',
      );
      final now = DateTime.utc(2026, 7, 17, 12);
      final chats = [
        Chat(id: 1, title: 'One', archived: false, updatedAt: now),
        Chat(id: 2, title: 'Two', archived: false, updatedAt: now),
        Chat(id: 3, title: 'Empty', archived: false, updatedAt: now),
      ];
      await db.chats.insertAll(chats);
      await db.table(const TagsTable()).insertAll([
        {'id': 1, 'chat_id': 1, 'label': 'b'},
        {'id': 2, 'chat_id': 1, 'label': 'a'},
        {'id': 3, 'chat_id': 2, 'label': 'c'},
      ]);
      await db.table(const NotesTable()).insertAll([
        {'id': 10, 'chat_id': 1, 'marker': 'd', 'body': 'first'},
        {'id': 11, 'chat_id': 2, 'marker': 'b', 'body': 'second'},
        {'id': 12, 'chat_id': 3, 'marker': 'z', 'body': 'third'},
      ]);
      final tags = DbHasMany<Chat, int, Map<String, Object?>, int>(
        parent: ChatsTable(),
        children: TagsTable(),
        foreignKey: TagsTable.chatId,
        foreignKeyOf: _tagChatId,
      );
      final chat = DbBelongsTo<Map<String, Object?>, int, Chat, int>(
        source: TagsTable(),
        target: ChatsTable(),
        foreignKey: TagsTable.chatId,
        foreignKeyOf: _tagChatId,
      );
      final notes = DbHasMany<Chat, int, Map<String, Object?>, int>(
        parent: ChatsTable(),
        children: NotesTable(),
        foreignKey: NotesTable.chatId,
        foreignKeyOf: _noteChatId,
      );
      final timeline = DbMergedRelationships<Chat, int, String>([
        dbMergedRelationshipSource(
          relationship: tags,
          cursorColumn: TagsTable.label,
          convert: (row) => 'tag:${row['label']}',
        ),
        dbMergedRelationshipSource(
          relationship: notes,
          cursorColumn: NotesTable.marker,
          convert: (row) => 'note:${row['marker']}:${row['body']}',
        ),
      ]);

      final grouped = await tags.loadAll(
        db,
        chats,
        transform: (query) => query.orderBy(TagsTable.label.ascending()),
      );
      final limited = await tags.loadAllLimited(
        db,
        chats,
        limit: 1,
        batchSize: 1,
        transform: (query) => query.orderBy(TagsTable.label.descending()),
      );
      final batched = await tags.loadAllBatched(
        db,
        chats,
        batchSize: 1,
        transform: (query) => query.orderBy(TagsTable.label.ascending()),
      );
      final owners = await chat.loadAll(
        db,
        await db.table(const TagsTable()).get(),
      );
      final merged = await timeline.load(db, chats, limit: 2);
      final older = await timeline.loadKeys(
        db,
        [1, 2, 3],
        limit: 2,
        cursor: const DbMergedCursorBound.before('c'),
      );

      expect(grouped[1]!.map((row) => row['label']), ['a', 'b']);
      expect(grouped[2]!.map((row) => row['label']), ['c']);
      expect(grouped[3], isEmpty);
      expect(limited[1]!.single['label'], 'b');
      expect(limited[2]!.single['label'], 'c');
      expect(limited[3], isEmpty);
      expect(batched[1]!.map((row) => row['label']), ['a', 'b']);
      expect(batched[2]!.map((row) => row['label']), ['c']);
      expect(batched[3], isEmpty);
      expect(merged[1], ['note:d:first', 'tag:b']);
      expect(merged[2], ['tag:c', 'note:b:second']);
      expect(merged[3], ['note:z:third']);
      expect(older[1], ['tag:b', 'tag:a']);
      expect(older[2], ['note:b:second']);
      expect(older[3], isEmpty);
      expect(owners[1]?.title, 'One');
      expect(owners[3]?.title, 'Two');
    },
  );

  test('has-one relationships reject duplicate related rows', () async {
    await database.execute(
      'CREATE TABLE tags (id INTEGER PRIMARY KEY, chat_id INTEGER, label TEXT)',
    );
    final chat = Chat(
      id: 1,
      title: 'One',
      archived: false,
      updatedAt: DateTime.utc(2026, 7, 17, 12),
    );
    await db.chats.insert(chat);
    await db.table(const TagsTable()).insertAll([
      {'id': 1, 'chat_id': 1, 'label': 'a'},
      {'id': 2, 'chat_id': 1, 'label': 'b'},
    ]);
    final featuredTag = DbHasOne<Chat, int, Map<String, Object?>, int>(
      parent: ChatsTable(),
      related: TagsTable(),
      foreignKey: TagsTable.chatId,
      foreignKeyOf: _tagChatId,
    );

    await expectLater(featuredTag.load(db, chat), throwsStateError);
  });

  test('composite key predicates combine typed key parts', () async {
    final now = DateTime.utc(2026, 7, 17, 12);
    await db.chats.insert(
      Chat(id: 1, title: 'Composite', archived: false, updatedAt: now),
    );
    final key = DbCompositeKey([
      DbKeyPart(ChatsTable.id, 1),
      DbKeyPart(ChatsTable.title, 'Composite'),
    ]);

    expect(await db.chats.whereCompositeKey(key).count(), 1);
  });
}

final class Chat {
  const Chat({
    required this.id,
    required this.title,
    this.note,
    required this.archived,
    required this.updatedAt,
  });

  final int id;
  final String title;
  final String? note;
  final bool archived;
  final DateTime updatedAt;

  @override
  bool operator ==(Object other) {
    return other is Chat &&
        other.id == id &&
        other.title == title &&
        other.note == note &&
        other.archived == archived &&
        other.updatedAt == updatedAt;
  }

  @override
  int get hashCode => Object.hash(id, title, note, archived, updatedAt);

  @override
  String toString() {
    return 'Chat(id: $id, title: $title, note: $note, archived: $archived, updatedAt: $updatedAt)';
  }
}

final class ChatsTable extends DbTable<Chat, int> {
  const ChatsTable();

  static final id = integer('id');
  static final title = text('title');
  static final note = nullableText('note');
  static final archived = boolean('archived');
  static final updatedAt = dateTime('updated_at');

  @override
  String get tableName => 'chats';

  @override
  DbColumn<int> get primaryKey => id;

  @override
  Iterable<AnyDbColumn> get columns => [id, title, note, archived, updatedAt];

  @override
  Chat decode(DbRow row) {
    return Chat(
      id: row.get(id),
      title: row.get(title),
      note: row.get(note),
      archived: row.get(archived),
      updatedAt: row.get(updatedAt),
    );
  }

  @override
  DbValues encode(Chat row) {
    return DbValues({
      id: row.id,
      title: row.title,
      note: row.note,
      archived: row.archived,
      updatedAt: row.updatedAt,
    });
  }

  @override
  int keyOf(Chat row) => row.id;
}

extension TestDb on SqliteLoom {
  DbTableQuery<Chat, int> get chats => table(const ChatsTable());
}

extension TestTx on SqliteLoomTransaction {
  DbTableQuery<Chat, int> get chats => table(const ChatsTable());
}

extension ChatScopes on DbTableQuery<Chat, int> {
  DbTableQuery<Chat, int> active() => where(ChatsTable.archived.equals(false));
}

final class TagsTable extends DbTable<Map<String, Object?>, int> {
  const TagsTable();
  static final id = integer('id');
  static final chatId = integer('chat_id');
  static final label = text('label');

  @override
  Iterable<AnyDbColumn> get columns => [id, chatId, label];
  @override
  String get tableName => 'tags';
  @override
  DbColumn<int> get primaryKey => id;
  @override
  Map<String, Object?> decode(DbRow row) => row.asMap;
  @override
  DbValues encode(Map<String, Object?> row) => DbValues.raw(row);
  @override
  int keyOf(Map<String, Object?> row) => row['id']! as int;
}

int _tagChatId(Map<String, Object?> row) => row['chat_id']! as int;

final class NotesTable extends DbTable<Map<String, Object?>, int> {
  const NotesTable();
  static final id = integer('id');
  static final chatId = integer('chat_id');
  static final marker = text('marker');
  static final body = text('body');

  @override
  Iterable<AnyDbColumn> get columns => [id, chatId, marker, body];
  @override
  String get tableName => 'notes';
  @override
  DbColumn<int> get primaryKey => id;
  @override
  Map<String, Object?> decode(DbRow row) => row.asMap;
  @override
  DbValues encode(Map<String, Object?> row) => DbValues.raw(row);
  @override
  int keyOf(Map<String, Object?> row) => row['id']! as int;
}

int _noteChatId(Map<String, Object?> row) => row['chat_id']! as int;

final class _InvalidPrimaryKeyTable extends DbTable<Map<String, Object?>, int> {
  const _InvalidPrimaryKeyTable();
  static final id = integer('id');
  static final name = text('name');

  @override
  String get tableName => 'invalid_pk';
  @override
  DbColumn<int> get primaryKey => id;
  @override
  Iterable<AnyDbColumn> get columns => [id, name];
  @override
  Map<String, Object?> decode(DbRow row) => row.asMap;
  @override
  DbValues encode(Map<String, Object?> row) => DbValues.raw(row);
  @override
  int keyOf(Map<String, Object?> row) => row['id']! as int;
}

final class _InvalidNullabilityTable
    extends DbTable<Map<String, Object?>, int> {
  const _InvalidNullabilityTable();
  static final id = integer('id');
  static final name = text('name');

  @override
  String get tableName => 'invalid_nullability';
  @override
  DbColumn<int> get primaryKey => id;
  @override
  Iterable<AnyDbColumn> get columns => [id, name];
  @override
  Map<String, Object?> decode(DbRow row) => row.asMap;
  @override
  DbValues encode(Map<String, Object?> row) => DbValues.raw(row);
  @override
  int keyOf(Map<String, Object?> row) => row['id']! as int;
}

final class _ValidatedChildTable extends DbTable<Map<String, Object?>, int> {
  const _ValidatedChildTable();

  static final id = integer('id');
  static final parentId = integer('parent_id');
  static final name = text('name');

  @override
  String get tableName => 'validated_children';
  @override
  DbColumn<int> get primaryKey => id;
  @override
  Iterable<AnyDbColumn> get columns => [id, parentId, name];
  @override
  DbTableSchema get schema => const DbTableSchema(
    strict: true,
    withoutRowId: false,
    foreignKeys: [
      DbForeignKeyExpectation(
        columns: ['parent_id'],
        referencesTable: 'parents',
        referencesColumns: ['id'],
        onDelete: 'CASCADE',
      ),
    ],
    indexes: [
      DbIndexExpectation(
        name: 'idx_validated_child_name',
        columns: ['name'],
        unique: true,
      ),
    ],
  );
  @override
  Map<String, Object?> decode(DbRow row) => row.asMap;
  @override
  DbValues encode(Map<String, Object?> row) => DbValues.raw(row);
  @override
  int keyOf(Map<String, Object?> row) => row['id']! as int;
}
