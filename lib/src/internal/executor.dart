import 'dart:async';

import 'package:sqflite_common/sqlite_api.dart';

import '../change.dart';
import '../table.dart';

abstract interface class DbExecutorAdapter {
  DatabaseExecutor get executor;

  bool get canWatch;

  Stream<DbChangeSet> get changes;

  Future<int> delete(String table, {String? where, List<Object?>? whereArgs});

  Future<void> execute(String sql, [List<Object?>? arguments]);

  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  });

  Future<List<Map<String, Object?>>> query(
    String table, {
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
  });

  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  });

  void record(DbTableId table, DbChangeKind kind, {Iterable<Object?>? keys});
}
