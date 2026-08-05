import 'dart:async';

import 'package:sqflite_common/sqlite_api.dart';

import '../internal/sql.dart';
import 'schema.dart';

/// Applies or reverses one migration using [migration].
typedef DbMigrationCallback =
    FutureOr<void> Function(DbMigrationContext migration);

/// Transaction-bound helpers available while a migration is running.
final class DbMigrationContext implements DatabaseExecutor {
  DbMigrationContext._(this.executor) : schema = DbSchema(executor);

  /// The exact executor owned by the migrator, normally a transaction.
  final DatabaseExecutor executor;

  /// Type-safe schema operations bound to [executor].
  final DbSchema schema;

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      executor.execute(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => executor.rawQuery(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => executor.query(
    table,
    distinct: distinct,
    columns: columns,
    where: where,
    whereArgs: whereArgs,
    groupBy: groupBy,
    having: having,
    orderBy: orderBy,
    limit: limit,
    offset: offset,
  );

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) => executor.insert(
    table,
    values,
    nullColumnHack: nullColumnHack,
    conflictAlgorithm: conflictAlgorithm,
  );

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) => executor.update(
    table,
    values,
    where: where,
    whereArgs: whereArgs,
    conflictAlgorithm: conflictAlgorithm,
  );

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      executor.delete(table, where: where, whereArgs: whereArgs);

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      executor.rawInsert(sql, arguments);

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      executor.rawUpdate(sql, arguments);

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      executor.rawDelete(sql, arguments);

  @override
  Future<QueryCursor> rawQueryCursor(
    String sql,
    List<Object?>? arguments, {
    int? bufferSize,
  }) => executor.rawQueryCursor(sql, arguments, bufferSize: bufferSize);

  @override
  Future<QueryCursor> queryCursor(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
    int? bufferSize,
  }) => executor.queryCursor(
    table,
    distinct: distinct,
    columns: columns,
    where: where,
    whereArgs: whereArgs,
    groupBy: groupBy,
    having: having,
    orderBy: orderBy,
    limit: limit,
    offset: offset,
    bufferSize: bufferSize,
  );

  @override
  Batch batch() => executor.batch();

  @override
  Database get database => executor.database;
}

/// A versioned, ordered database schema change.
abstract class DbMigration {
  /// Creates a migration.
  const DbMigration();

  /// The unique positive version number.
  int get version;

  /// A stable descriptive name.
  String get name;

  /// Optional stable checksum used to detect edited released migrations.
  String? get checksum => null;

  /// Applies this migration.
  FutureOr<void> up(DbMigrationContext migration);

  /// Reverses this migration.
  ///
  /// The default throws because rollback must never be assumed safe.
  FutureOr<void> down(DbMigrationContext migration) {
    throw UnsupportedError(
      'Migration $version $name does not support rollback',
    );
  }
}

/// A migration implemented with callback functions.
final class CallbackDbMigration extends DbMigration {
  /// Creates a callback migration.
  const CallbackDbMigration({
    required this.version,
    required this.name,
    required DbMigrationCallback up,
    DbMigrationCallback? down,
    this.checksum,
  }) : _up = up,
       _down = down;

  @override
  final int version;

  @override
  final String name;

  @override
  final String? checksum;

  final DbMigrationCallback _up;
  final DbMigrationCallback? _down;

  @override
  FutureOr<void> up(DbMigrationContext migration) => _up(migration);

  @override
  FutureOr<void> down(DbMigrationContext migration) {
    final callback = _down;
    if (callback == null) {
      return super.down(migration);
    }
    return callback(migration);
  }
}

/// Adds source-integrity metadata to an application migration.
///
/// Retained for source compatibility. Generated projects now use
/// [SqliteLoomProject] and do not expose checksum wrappers to application code.
final class ChecksummedDbMigration extends DbMigration {
  const ChecksummedDbMigration(this.migration, {required this.checksum});

  /// The application-authored migration.
  final DbMigration migration;

  @override
  int get version => migration.version;

  @override
  String get name => migration.name;

  @override
  final String checksum;

  @override
  FutureOr<void> up(DbMigrationContext migration) =>
      this.migration.up(migration);

  @override
  FutureOr<void> down(DbMigrationContext migration) =>
      this.migration.down(migration);
}

/// An application-level collection of migrations.
final class SqliteLoomProject {
  /// Creates a project from its ordered, application-readable migrations.
  const SqliteLoomProject(
    this.migrations, {
    this.retiredVersions = const <int>{},
  });

  /// Migrations belonging to the application.
  final List<DbMigration> migrations;

  /// Historical versions accepted in existing databases but never applied to
  /// new databases.
  final Set<int> retiredVersions;

  /// Highest schema version declared by this project, or zero when empty.
  int get latestMigrationVersion => migrations.fold(
    retiredVersions.fold(
      0,
      (latest, version) => version > latest ? version : latest,
    ),
    (latest, migration) =>
        migration.version > latest ? migration.version : latest,
  );

  /// Creates a migrator for [database].
  SqliteLoomMigrator migrator(Database database) => SqliteLoomMigrator(
    database,
    migrations: migrations,
    retiredVersions: retiredVersions,
  );

  /// Applies pending project migrations.
  Future<DbMigrationResult> migrate(Database database, {int? through}) =>
      migrator(database).migrate(through: through);
}

/// A migration record read from the migration tracking table.
final class DbAppliedMigration {
  /// Creates an applied migration record.
  const DbAppliedMigration({
    required this.version,
    required this.name,
    required this.batch,
    required this.appliedAt,
    this.checksum,
  });

  final int version;
  final String name;
  final int batch;
  final DateTime appliedAt;
  final String? checksum;
}

/// Joins a code-defined migration with its stored application record.
final class DbMigrationStatus {
  const DbMigrationStatus({
    required this.version,
    required this.name,
    required this.migration,
    required this.applied,
    required this.isRetired,
  });

  final int version;
  final String name;
  final DbMigration? migration;
  final DbAppliedMigration? applied;

  /// Whether this version was intentionally consolidated or retired.
  final bool isRetired;

  /// Whether this version has been applied.
  bool get isApplied => applied != null;

  /// Whether the database contains a version missing from application code.
  bool get isMissing => migration == null && !isRetired;
}

/// The result of applying pending migrations.
final class DbMigrationResult {
  const DbMigrationResult({required this.applied});

  final List<DbMigration> applied;

  /// Whether at least one migration ran.
  bool get didRun => applied.isNotEmpty;
}

/// The result of rolling back migrations.
final class DbRollbackResult {
  const DbRollbackResult({required this.rolledBack});

  final List<DbMigration> rolledBack;

  /// Whether at least one migration was reversed.
  bool get didRun => rolledBack.isNotEmpty;
}

/// The combined result of a reset followed by migration.
final class DbRefreshResult {
  const DbRefreshResult({required this.rollback, required this.migration});

  final DbRollbackResult rollback;
  final DbMigrationResult migration;
}

/// The result of dropping user tables and rebuilding the schema.
final class DbFreshResult {
  const DbFreshResult({required this.droppedTables, required this.migration});

  final List<String> droppedTables;
  final DbMigrationResult migration;
}

/// Applies, reports, and reverses an ordered migration list.
final class SqliteLoomMigrator {
  /// Creates a migrator for [database].
  ///
  /// Migration versions must be positive and unique.
  SqliteLoomMigrator(
    this.database, {
    required Iterable<DbMigration> migrations,
    Set<int> retiredVersions = const <int>{},
    String migrationTable = '_sqlite_loom_migrations',
    int busyRetryAttempts = 3,
    Duration busyRetryDelay = const Duration(milliseconds: 25),
  }) : _migrationTable = migrationTable,
       _migrations = _validateMigrations(migrations),
       _retiredVersions = Set.unmodifiable(retiredVersions),
       _busyRetryAttempts = busyRetryAttempts,
       _busyRetryDelay = busyRetryDelay {
    if (busyRetryAttempts < 0) {
      throw ArgumentError.value(
        busyRetryAttempts,
        'busyRetryAttempts',
        'Cannot be negative',
      );
    }
    if (busyRetryDelay.isNegative) {
      throw ArgumentError.value(
        busyRetryDelay,
        'busyRetryDelay',
        'Cannot be negative',
      );
    }
    final activeVersions = _migrations.map((migration) => migration.version);
    if (_retiredVersions.any((version) => version <= 0) ||
        activeVersions.any(_retiredVersions.contains)) {
      throw ArgumentError.value(
        retiredVersions,
        'retiredVersions',
        'Must be positive and cannot overlap active migrations',
      );
    }
  }

  final Database database;
  final String _migrationTable;
  final List<DbMigration> _migrations;
  final Set<int> _retiredVersions;
  final int _busyRetryAttempts;
  final Duration _busyRetryDelay;

  /// Applies pending migrations, optionally only through [through].
  Future<DbMigrationResult> migrate({int? through}) async {
    await _ensureMigrationTable();
    var migrated = const <DbMigration>[];
    Future<void> applyPending() => database.transaction<void>((txn) async {
      final applied = await _appliedByVersion(txn);
      _throwIfAppliedMigrationIsMissing(applied.values);
      _throwIfAppliedMigrationChanged(applied.values);
      final pending = _migrations
          .where((migration) => !applied.containsKey(migration.version))
          .where((migration) => through == null || migration.version <= through)
          .toList(growable: false);
      if (pending.isEmpty) return;
      final batch = await _nextBatch(txn);
      final now = DateTime.now().toUtc().toIso8601String();
      for (final migration in pending) {
        await migration.up(DbMigrationContext._(txn));
        await txn.insert(_migrationTable, {
          'version': migration.version,
          'name': migration.name,
          'batch': batch,
          'applied_at': now,
          'checksum': migration.checksum,
        });
      }
      migrated = pending;
    });
    for (var attempt = 0; ; attempt += 1) {
      try {
        await applyPending();
        break;
      } catch (error) {
        if (!_isSqliteBusy(error) || attempt >= _busyRetryAttempts) rethrow;
        await Future<void>.delayed(_busyRetryDelay * (attempt + 1));
      }
    }

    return DbMigrationResult(applied: migrated);
  }

  /// Drops every user table and reapplies all migrations.
  ///
  /// Requires an explicit destructive opt-in.
  Future<DbFreshResult> fresh({bool allowDestructive = false}) async {
    if (!allowDestructive) {
      throw StateError('fresh() is destructive. Pass allowDestructive: true.');
    }
    final tables = await _userTables();
    final foreignKeys = await database.rawQuery('PRAGMA foreign_keys');
    final foreignKeysWereEnabled = foreignKeys.single.values.first == 1;
    await database.execute('PRAGMA foreign_keys = OFF');
    try {
      await database.transaction<void>((txn) async {
        for (final table in tables.reversed) {
          await txn.execute('DROP TABLE IF EXISTS ${quoteIdentifier(table)}');
        }
      });
    } finally {
      await database.execute(
        'PRAGMA foreign_keys = ${foreignKeysWereEnabled ? 'ON' : 'OFF'}',
      );
    }
    final migration = await migrate();
    return DbFreshResult(droppedTables: tables, migration: migration);
  }

  /// Rolls back all batches and then reapplies all migrations.
  Future<DbRefreshResult> refresh() async {
    final rollback = await reset();
    final migration = await migrate();
    return DbRefreshResult(rollback: rollback, migration: migration);
  }

  /// Rolls back every applied migration.
  Future<DbRollbackResult> reset() async {
    await _ensureMigrationTable();
    final applied = await _appliedMigrations();
    final batchCount = applied.map((record) => record.batch).toSet().length;
    if (batchCount == 0) {
      return const DbRollbackResult(rolledBack: []);
    }
    return rollback(batches: batchCount);
  }

  /// Rolls back the most recent [batches].
  Future<DbRollbackResult> rollback({int batches = 1}) async {
    if (batches < 1) {
      throw ArgumentError.value(batches, 'batches', 'Must be at least 1');
    }
    await _ensureMigrationTable();
    final applied = await _appliedMigrations();
    _throwIfAppliedMigrationIsMissing(applied);
    _throwIfAppliedMigrationChanged(applied);
    if (applied.isEmpty) {
      return const DbRollbackResult(rolledBack: []);
    }

    final targetBatches = <int>{};
    for (final record in applied.reversed) {
      targetBatches.add(record.batch);
      if (targetBatches.length == batches) {
        break;
      }
    }
    final toRollback = applied
        .where((record) => targetBatches.contains(record.batch))
        .toList(growable: false)
        .reversed
        .toList(growable: false);
    final rolledBack = <DbMigration>[];
    final migrationsByVersion = {
      for (final migration in _migrations) migration.version: migration,
    };

    await database.transaction<void>((txn) async {
      for (final record in toRollback) {
        final migration = migrationsByVersion[record.version]!;
        await migration.down(DbMigrationContext._(txn));
        await txn.delete(
          _migrationTable,
          where: 'version = ?',
          whereArgs: [migration.version],
        );
        rolledBack.add(migration);
      }
    });

    return DbRollbackResult(rolledBack: rolledBack);
  }

  /// Reports the relationship between code and applied migrations.
  Future<List<DbMigrationStatus>> status() async {
    await _ensureMigrationTable();
    final applied = await _appliedByVersion();
    final migrationsByVersion = {
      for (final migration in _migrations) migration.version: migration,
    };
    final versions = <int>{
      ...applied.keys,
      ...migrationsByVersion.keys,
      ..._retiredVersions,
    }.toList(growable: false)..sort();

    return [
      for (final version in versions)
        DbMigrationStatus(
          version: version,
          name:
              migrationsByVersion[version]?.name ??
              applied[version]?.name ??
              'retired_$version',
          migration: migrationsByVersion[version],
          applied: applied[version],
          isRetired: _retiredVersions.contains(version),
        ),
    ];
  }

  Future<Map<int, DbAppliedMigration>> _appliedByVersion([
    DatabaseExecutor? executor,
  ]) async {
    return {
      for (final migration in await _appliedMigrations(executor))
        migration.version: migration,
    };
  }

  Future<List<DbAppliedMigration>> _appliedMigrations([
    DatabaseExecutor? executor,
  ]) async {
    final rows = await (executor ?? database).query(
      _migrationTable,
      orderBy: 'batch ASC, version ASC',
    );
    return rows.map(_decodeAppliedMigration).toList(growable: false);
  }

  DbAppliedMigration _decodeAppliedMigration(Map<String, Object?> row) {
    return DbAppliedMigration(
      version: row['version']! as int,
      name: row['name']! as String,
      batch: row['batch']! as int,
      appliedAt: DateTime.parse(row['applied_at']! as String),
      checksum: row['checksum'] as String?,
    );
  }

  Future<void> _ensureMigrationTable() async {
    await database.execute(
      'CREATE TABLE IF NOT EXISTS ${quoteIdentifier(_migrationTable)} ('
      'version INTEGER PRIMARY KEY, '
      'name TEXT NOT NULL, '
      'batch INTEGER NOT NULL, '
      'applied_at TEXT NOT NULL, '
      'checksum TEXT'
      ')',
    );
    final columns = await database.rawQuery(
      'PRAGMA table_info(${quoteIdentifier(_migrationTable)})',
    );
    if (!columns.any((column) => column['name'] == 'checksum')) {
      await database.execute(
        'ALTER TABLE ${quoteIdentifier(_migrationTable)} ADD COLUMN checksum TEXT',
      );
    }
  }

  Future<int> _nextBatch([DatabaseExecutor? executor]) async {
    final rows = await (executor ?? database).rawQuery(
      'SELECT MAX(batch) AS batch FROM ${quoteIdentifier(_migrationTable)}',
    );
    final batch = rows.first['batch'];
    if (batch == null) {
      return 1;
    }
    return (batch as int) + 1;
  }

  void _throwIfAppliedMigrationIsMissing(Iterable<DbAppliedMigration> applied) {
    final knownVersions =
        _migrations.map((migration) => migration.version).toSet()
          ..addAll(_retiredVersions);
    final missing = applied
        .where((record) => !knownVersions.contains(record.version))
        .toList(growable: false);
    if (missing.isNotEmpty) {
      final versions = missing.map((record) => record.version).join(', ');
      throw StateError('Applied migrations are missing from code: $versions');
    }
  }

  void _throwIfAppliedMigrationChanged(Iterable<DbAppliedMigration> applied) {
    final migrationsByVersion = {
      for (final migration in _migrations) migration.version: migration,
    };
    final changed = applied
        .where((record) {
          final expected = migrationsByVersion[record.version]?.checksum;
          return expected != null &&
              record.checksum != null &&
              record.checksum != expected;
        })
        .toList(growable: false);
    if (changed.isNotEmpty) {
      final versions = changed.map((record) => record.version).join(', ');
      throw StateError('Applied migration checksums changed: $versions');
    }
  }

  Future<List<String>> _userTables() async {
    final rows = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
    );
    return rows.map((row) => row['name']! as String).toList(growable: false);
  }
}

bool _isSqliteBusy(Object error) {
  if (error is! DatabaseException) return false;
  final code = error.getResultCode();
  return code != null && (code & 0xff) == 5;
}

List<DbMigration> _validateMigrations(Iterable<DbMigration> migrations) {
  final ordered = migrations.toList(growable: false)
    ..sort((left, right) => left.version.compareTo(right.version));
  final seen = <int>{};
  for (final migration in ordered) {
    if (migration.version < 1) {
      throw ArgumentError.value(
        migration.version,
        'version',
        'Migration version must be positive',
      );
    }
    if (migration.name.trim().isEmpty) {
      throw ArgumentError.value(
        migration.name,
        'name',
        'Migration name cannot be empty',
      );
    }
    if (!seen.add(migration.version)) {
      throw ArgumentError.value(
        migration.version,
        'version',
        'Duplicate migration version',
      );
    }
  }
  return ordered;
}
