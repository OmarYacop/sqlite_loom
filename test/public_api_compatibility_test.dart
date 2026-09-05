import 'dart:convert';
import 'dart:io';

import 'package:sqlite_loom/sqlite_loom.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

void main() {
  sqfliteFfiInit();

  test(
    'typed assignments and cursor bounds reject wrong value types',
    () async {
      final temp = await Directory.systemTemp.createTemp('loom_type_check_');
      addTearDown(() => temp.delete(recursive: true));
      final original = File('.dart_tool/package_config.json').absolute;
      final config =
          jsonDecode(await original.readAsString()) as Map<String, dynamic>;
      for (final entry in config['packages'] as List) {
        final package = entry as Map<String, dynamic>;
        package['rootUri'] = original.uri
            .resolve(package['rootUri'] as String)
            .toString();
      }
      await Directory('${temp.path}/.dart_tool').create();
      await File(
        '${temp.path}/.dart_tool/package_config.json',
      ).writeAsString(jsonEncode(config));
      final fixture = File('${temp.path}/invalid.dart');
      await fixture.writeAsString("""
import 'package:sqlite_loom/sqlite_loom.dart';
void main() {
  final id = integer('id');
  id.set('wrong');
  DbCursorColumn(id).at('wrong');
}
""");
      final result = await Process.run(Platform.resolvedExecutable, [
        'analyze',
        '--format=machine',
        fixture.path,
      ]);
      expect(result.exitCode, isNot(0));
      final output = '${result.stdout}${result.stderr}';
      expect(
        'ARGUMENT_TYPE_NOT_ASSIGNABLE'.allMatches(output),
        hasLength(2),
        reason: output,
      );
      expect(output, isNot(contains('URI_DOES_NOT_EXIST')));
    },
  );

  test('0.4 public query signatures remain source compatible', () async {
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    final loom = SqliteLoom(database);
    final DbTableQuery<_Fixture, int> query = loom.table(const _FixtureTable());
    final DbSession session = loom;
    final DbAssignment<String> assignment = _FixtureTable.name.set('typed');
    expect(DbValues.fromAssignments([assignment]).asMap, {'name': 'typed'});
    final cursor = DbCursorColumn(_FixtureTable.id);
    expect(
      session
          .table(const _FixtureTable())
          .afterCursor([cursor.at(1)])
          .compile()
          .arguments,
      [1],
    );
    final select = query.select([_FixtureTable.id, _FixtureTable.name]);
    final pluck = query.pluck(_FixtureTable.name);
    final aggregate = DbAggregate.count();
    final grouped = query.groupBy([_FixtureTable.name]).select([
      _FixtureTable.name,
      aggregate,
    ]);
    final relation = DbHasMany<_Fixture, int, _Fixture, int>(
      parent: const _FixtureTable(),
      children: const _FixtureTable(),
      foreignKey: _FixtureTable.id,
      foreignKeyOf: (row) => row.id,
    );
    final mergedSource = dbMergedRelationshipSource(
      relationship: relation,
      cursorColumn: _FixtureTable.name,
      convert: (row) => row,
    );
    final merged = DbMergedRelationships<_Fixture, int, _Fixture>([
      mergedSource,
    ]);

    expect(select, isA<DbRowSelection<_Fixture, int>>());
    expect(pluck, isA<DbColumnSelection<_Fixture, int, String>>());
    expect(grouped, isA<DbGroupedSelection<_Fixture, int>>());
    expect(
      relation.query(loom, (id: 1, name: 'fixture')),
      isA<DbTableQuery<_Fixture, int>>(),
    );
    expect(merged, isA<DbMergedRelationships<_Fixture, int, _Fixture>>());
    expect(query.whereKey(1), isA<DbTableQuery<_Fixture, int>>());
    expect(DbPredicate.trusted('name = ?', ['safe']), isA<DbPredicate>());
    expect(DbOrdering.trusted('name ASC'), isA<DbOrdering>());
    loom.invalidate({const _FixtureTable().tableId});
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
