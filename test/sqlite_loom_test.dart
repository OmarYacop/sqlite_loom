import 'dart:async';

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
