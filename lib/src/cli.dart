import 'dart:async';

import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// Opens the database used by the migration CLI.
typedef SqliteLoomDatabaseOpener = FutureOr<Database> Function();

/// Receives one line of CLI output.
typedef SqliteLoomCliPrinter = void Function(String line);

/// Runs an application-owned migration command and returns an exit code.
///
/// Supported commands are `migrate`, `status`, `rollback`, `reset`, `refresh`,
/// and `fresh`. The opened database is always closed before this function
/// returns.
Future<int> runSqliteLoomCli(
  List<String> args, {
  required SqliteLoomDatabaseOpener openDatabase,
  required Iterable<DbMigration> migrations,
  bool allowDestructive = false,
  SqliteLoomCliPrinter printLine = print,
}) async {
  final command = args.isEmpty ? 'help' : args.first;
  if (command == 'help' || command == '--help' || command == '-h') {
    _printHelp(printLine);
    return 0;
  }

  final database = await openDatabase();
  try {
    final migrator = SqliteLoomMigrator(database, migrations: migrations);
    switch (command) {
      case 'migrate':
        final result = await migrator.migrate();
        if (result.applied.isEmpty) {
          printLine('Nothing to migrate.');
        } else {
          for (final migration in result.applied) {
            printLine('Migrated ${migration.version} ${migration.name}');
          }
        }
        return 0;
      case 'status':
        final statuses = await migrator.status();
        if (statuses.isEmpty) {
          printLine('No migrations.');
          return 0;
        }
        for (final status in statuses) {
          final state = status.isApplied ? 'Y' : 'N';
          final missing = status.isMissing ? ' missing-from-code' : '';
          final batch = status.applied == null
              ? '-'
              : '${status.applied!.batch}';
          printLine(
            '$state batch=$batch version=${status.version} ${status.name}$missing',
          );
        }
        return 0;
      case 'rollback':
        final result = await migrator.rollback(batches: _readBatches(args));
        if (result.rolledBack.isEmpty) {
          printLine('Nothing to rollback.');
        } else {
          for (final migration in result.rolledBack) {
            printLine('Rolled back ${migration.version} ${migration.name}');
          }
        }
        return 0;
      case 'reset':
        final result = await migrator.reset();
        if (result.rolledBack.isEmpty) {
          printLine('Nothing to reset.');
        } else {
          for (final migration in result.rolledBack) {
            printLine('Rolled back ${migration.version} ${migration.name}');
          }
        }
        return 0;
      case 'refresh':
        final result = await migrator.refresh();
        printLine(
          'Rolled back ${result.rollback.rolledBack.length} migrations.',
        );
        printLine('Migrated ${result.migration.applied.length} migrations.');
        return 0;
      case 'fresh':
        if (!allowDestructive) {
          printLine('fresh is destructive. Enable allowDestructive to run it.');
          return 73;
        }
        final result = await migrator.fresh(allowDestructive: true);
        printLine('Dropped ${result.droppedTables.length} tables.');
        printLine('Migrated ${result.migration.applied.length} migrations.');
        return 0;
      default:
        printLine('Unknown sqlite_loom command: $command');
        _printHelp(printLine);
        return 64;
    }
  } finally {
    await database.close();
  }
}

int _readBatches(List<String> args) {
  final index = args.indexOf('--batches');
  if (index == -1) {
    return 1;
  }
  if (index + 1 >= args.length) {
    throw ArgumentError('--batches requires a value');
  }
  final value = int.tryParse(args[index + 1]);
  if (value == null || value < 1) {
    throw ArgumentError.value(
      args[index + 1],
      '--batches',
      'Must be a positive integer',
    );
  }
  return value;
}

void _printHelp(SqliteLoomCliPrinter printLine) {
  printLine('sqlite_loom commands:');
  printLine('  migrate');
  printLine('  status');
  printLine('  rollback [--batches n]');
  printLine('  reset');
  printLine('  refresh');
  printLine('  fresh');
}
