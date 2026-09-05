part of 'runtime_cli.dart';

Future<int> _runRestore(
  List<String> args, {
  required SqliteLoomRestoreHandler? handler,
  required bool allowDestructive,
  required bool allowProductionDestructive,
  required String environment,
  required String databaseDescription,
  required SqliteLoomCliConfirmation? confirmation,
  required bool json,
  required SqliteLoomCliPrinter printLine,
}) async {
  if (handler == null) {
    _printFailure(
      'db:restore',
      'The project runner does not configure database restoration.',
      json,
      printLine,
    );
    return 78;
  }
  try {
    final input = _readString(args, '--input', required: true)!;
    final permitted = await _confirmDestructive(
      'db:restore',
      args,
      allowDestructive: allowDestructive,
      allowProductionDestructive: allowProductionDestructive,
      environment: environment,
      databaseDescription: databaseDescription,
      confirmation: confirmation,
      printLine: printLine,
      json: json,
    );
    if (!permitted) return 73;
    await handler(input);
    if (json) {
      _printJson(printLine, {
        'command': 'db:restore',
        'success': true,
        'input': input,
      });
    } else {
      printLine('Database restored from $input');
    }
    return 0;
  } on ArgumentError catch (error) {
    _printFailure('db:restore', '${error.message}', json, printLine);
    return 64;
  } catch (error) {
    _printFailure('db:restore', '$error', json, printLine);
    return 70;
  }
}

Future<int> _runSandbox(
  List<String> args, {
  required Iterable<DbMigration> migrations,
  required SqliteLoomSandboxOpener? opener,
  required bool json,
  required SqliteLoomCliPrinter printLine,
}) async {
  if (opener == null) {
    _printFailure(
      'sandbox',
      'The project runner does not configure a sandbox opener.',
      json,
      printLine,
    );
    return 78;
  }
  SqliteLoomSandbox? sandbox;
  try {
    sandbox = await opener();
    final result = await SqliteLoomMigrator(
      sandbox.database,
      migrations: migrations,
    ).migrate(through: _readPositiveInt(args, '--to', required: false));
    final check = await sandbox.database.rawQuery('PRAGMA integrity_check');
    final diagnostics = check
        .expand((row) => row.values)
        .whereType<String>()
        .toList(growable: false);
    final healthy = diagnostics.length == 1 && diagnostics.single == 'ok';
    if (json) {
      _printJson(printLine, {
        'command': 'sandbox',
        'success': healthy,
        'applied': result.applied.map(_migrationJson).toList(),
        'diagnostics': diagnostics,
      });
    } else {
      printLine(
        'Applied ${result.applied.length} migrations in an isolated database.',
      );
      printLine(
        healthy ? '✓ Sandbox integrity check passed.' : '✗ Sandbox failed.',
      );
    }
    return healthy ? 0 : 1;
  } catch (error) {
    _printFailure('sandbox', '$error', json, printLine);
    return 70;
  } finally {
    if (sandbox != null) {
      await sandbox.database.close();
      await sandbox.cleanup();
    }
  }
}

Future<int> _runSchemaDiff(
  Database database, {
  required Iterable<DbMigration> migrations,
  required SqliteLoomSandboxOpener? opener,
  required bool json,
  required SqliteLoomCliPrinter printLine,
}) async {
  if (opener == null) {
    _printFailure(
      'schema:diff',
      'The project runner does not configure a sandbox opener.',
      json,
      printLine,
    );
    return 78;
  }
  SqliteLoomSandbox? sandbox;
  var stage = 'opening sandbox';
  try {
    sandbox = await opener();
    stage = 'running migrations';
    await SqliteLoomMigrator(
      sandbox.database,
      migrations: migrations,
    ).migrate();
    stage = 'reading current schema';
    final current = await _schemaDump(database);
    stage = 'reading expected schema';
    final expected = await _schemaDump(sandbox.database);
    final currentByKey = {
      for (final object in current) _schemaKey(object): object['sql'],
    };
    final expectedByKey = {
      for (final object in expected) _schemaKey(object): object['sql'],
    };
    final added =
        expectedByKey.keys
            .toSet()
            .difference(currentByKey.keys.toSet())
            .toList()
          ..sort();
    final removed =
        currentByKey.keys
            .toSet()
            .difference(expectedByKey.keys.toSet())
            .toList()
          ..sort();
    final changed =
        expectedByKey.keys
            .where(
              (key) =>
                  currentByKey.containsKey(key) &&
                  currentByKey[key] != expectedByKey[key],
            )
            .toList()
          ..sort();
    final matches = added.isEmpty && removed.isEmpty && changed.isEmpty;
    if (json) {
      _printJson(printLine, {
        'command': 'schema:diff',
        'success': true,
        'matches': matches,
        'added': added,
        'removed': removed,
        'changed': changed,
      });
    } else if (matches) {
      printLine('✓ Database schema matches a clean migration run.');
    } else {
      for (final key in added) {
        printLine('+ $key');
      }
      for (final key in removed) {
        printLine('- $key');
      }
      for (final key in changed) {
        printLine('~ $key');
      }
    }
    return matches ? 0 : 1;
  } catch (error) {
    _printFailure(
      'schema:diff',
      'Failed while $stage: $error',
      json,
      printLine,
    );
    return 70;
  } finally {
    if (sandbox != null) {
      await sandbox.database.close();
      await sandbox.cleanup();
    }
  }
}

String _schemaKey(Map<String, Object?> object) =>
    '${object['type']}:${object['name']}';
