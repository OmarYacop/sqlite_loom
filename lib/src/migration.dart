import 'dart:async';

import 'package:sqflite_common/sqlite_api.dart';

import 'internal/sql.dart';

/// Applies or reverses one migration using [db].
typedef DbMigrationCallback = FutureOr<void> Function(DatabaseExecutor db);

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
  FutureOr<void> up(DatabaseExecutor db);

  /// Reverses this migration.
  ///
  /// The default throws because rollback must never be assumed safe.
  FutureOr<void> down(DatabaseExecutor db) {
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
  FutureOr<void> up(DatabaseExecutor db) => _up(db);

  @override
  FutureOr<void> down(DatabaseExecutor db) {
    final callback = _down;
    if (callback == null) {
      return super.down(db);
    }
    return callback(db);
  }
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
  });

  final int version;
  final String name;
  final DbMigration? migration;
  final DbAppliedMigration? applied;

  /// Whether this version has been applied.
  bool get isApplied => applied != null;

  /// Whether the database contains a version missing from application code.
  bool get isMissing => migration == null;
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
    String migrationTable = '_sqlite_loom_migrations',
    int busyRetryAttempts = 3,
    Duration busyRetryDelay = const Duration(milliseconds: 25),
  }) : _migrationTable = migrationTable,
       _migrations = _validateMigrations(migrations),
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
  }

  final Database database;
  final String _migrationTable;
  final List<DbMigration> _migrations;
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
        await migration.up(txn);
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
    await database.execute('PRAGMA foreign_keys = OFF');
    try {
      await database.transaction<void>((txn) async {
        for (final table in tables.reversed) {
          await txn.execute('DROP TABLE IF EXISTS ${quoteIdentifier(table)}');
        }
      });
    } finally {
      await database.execute('PRAGMA foreign_keys = ON');
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
        await migration.down(txn);
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
    }.toList(growable: false)..sort();

    return [
      for (final version in versions)
        DbMigrationStatus(
          version: version,
          name: migrationsByVersion[version]?.name ?? applied[version]!.name,
          migration: migrationsByVersion[version],
          applied: applied[version],
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
    final knownVersions = _migrations
        .map((migration) => migration.version)
        .toSet();
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
          return record.checksum != null && record.checksum != expected;
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
