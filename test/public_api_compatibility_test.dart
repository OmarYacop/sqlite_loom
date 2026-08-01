import 'package:sqlite_loom/sqlite_loom.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

void main() {
  sqfliteFfiInit();

  test('0.2 public query signatures remain source compatible', () async {
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    final loom = SqliteLoom(database);
    final DbTableQuery<_Fixture, int> query = loom.table(const _FixtureTable());
    final select = query.select([_FixtureTable.id, _FixtureTable.name]);
    final pluck = query.pluck(_FixtureTable.name);

    expect(select, isA<DbRowSelection<_Fixture, int>>());
    expect(pluck, isA<DbColumnSelection<_Fixture, int, String>>());
    expect(query.whereKey(1), isA<DbTableQuery<_Fixture, int>>());
    expect(DbPredicate.trusted('name = ?', ['safe']), isA<DbPredicate>());
    expect(DbOrdering.trusted('name ASC'), isA<DbOrdering>());
    await loom.close();
  });
}

// Compile-time fixture: changing these public types or signatures is an
// intentional compatibility decision that must update this test and changelog.
typedef _Fixture = ({int id, String name});

final class _FixtureTable extends DbTable<_Fixture, int> {
  const _FixtureTable();
  static final id = integer('id');
  static final name = text('name');

  @override
  Iterable<AnyDbColumn> get columns => [id, name];
  @override
  String get tableName => 'fixtures';
  @override
  DbColumn<int> get primaryKey => id;
  @override
  _Fixture decode(DbRow row) => (id: row.get(id), name: row.get(name));
  @override
  DbValues encode(_Fixture row) => DbValues({id: row.id, name: row.name});
  @override
  int keyOf(_Fixture row) => row.id;
}
