part of 'project_cli.dart';

int _init(
  Directory directory,
  List<String> arguments, {
  required LoomCliWriter out,
}) {
  final parser = ArgParser()..addFlag('force', negatable: false);
  final parsed = _parse(parser, arguments, 'init');
  final force = parsed.flag('force');
  final config = File(p.join(directory.path, 'sqlite_loom.yaml'));
  if (config.existsSync() && !force) {
    throw LoomCliException(
      '${config.path} already exists. Pass --force to replace managed files.',
      LoomExitCode.refused,
    );
  }
  final packageName = _readPackageName(directory);
  _writeManaged(config, _configTemplate, force: force);
  final project = LoomProjectConfig.discover(directory);
  project.migrationsDirectory.createSync(recursive: true);
  _syncProject(project);
  _writeManaged(
    project.runnerFile,
    _runnerTemplate(project, packageName),
    force: force,
  );
  final gitignore = File(p.join(directory.path, '.gitignore'));
  _ensureGitignore(gitignore, '.sqlite_loom/*.sqlite');
  _ensureGitignore(gitignore, '.sqlite_loom/*.sqlite-*');
  out('✓ Created ${p.relative(config.path, from: directory.path)}');
  out('✓ Created readable migration index and draft lock');
  out('✓ Created ${p.relative(project.runnerFile.path, from: directory.path)}');
  out('Next: dart pub add --dev sqflite_common_ffi');
  out('Then: dart run sqlite_loom make:migration create_users');
  return LoomExitCode.success;
}

int _makeMigration(
  Directory directory,
  List<String> arguments, {
  required LoomClock clock,
  required LoomCliWriter out,
}) {
  final parser = ArgParser()
    ..addOption('config')
    ..addOption('create', help: 'Scaffold creation of this table')
    ..addOption('table', help: 'Scaffold a change to this table')
    ..addFlag('force', negatable: false);
  final parsed = _parse(parser, arguments, 'make:migration');
  if (parsed.rest.length != 1) {
    throw const LoomCliException(
      'make:migration requires exactly one migration name.',
      LoomExitCode.usage,
    );
  }
  final project = LoomProjectConfig.discover(
    directory,
    explicitPath: parsed.option('config'),
  );
  final createTable = parsed.option('create');
  final alterTable = parsed.option('table');
  if (createTable != null && alterTable != null) {
    throw const LoomCliException(
      'Use either --create or --table, not both.',
      LoomExitCode.usage,
    );
  }
  final targetTable = createTable ?? alterTable;
  if (targetTable != null &&
      !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(targetTable)) {
    throw LoomCliException(
      'Invalid table name: $targetTable',
      LoomExitCode.usage,
    );
  }
  final name = _normalizeMigrationName(parsed.rest.single);
  project.migrationsDirectory.createSync(recursive: true);
  final version = _nextVersion(project.migrationsDirectory, clock().toUtc());
  final file = File(
    p.join(project.migrationsDirectory.path, '${version}_$name.dart'),
  );
  if (file.existsSync() && !parsed.flag('force')) {
    throw LoomCliException(
      '${file.path} already exists.',
      LoomExitCode.refused,
    );
  }
  file.writeAsStringSync(
    _migrationTemplate(
      version,
      name,
      createTable: createTable,
      alterTable: alterTable,
    ),
  );
  _syncProject(project);
  out('✓ Created ${p.relative(file.path, from: project.root.path)}');
  out(
    '✓ Updated ${p.relative(project.indexFile.path, from: project.root.path)}',
  );
  out('Migration remains a draft until `migrate:finalize`.');
  return LoomExitCode.success;
}

int _makeFlavor(
  Directory directory,
  List<String> arguments, {
  required LoomCliWriter out,
}) {
  final parser = ArgParser()
    ..addOption('config')
    ..addFlag('force', negatable: false)
    ..addFlag('override', negatable: false);
  final parsed = _parse(parser, arguments, 'make:flavor');
  if (parsed.rest.length != 1) {
    throw const LoomCliException(
      'make:flavor requires exactly one flavor name.',
      LoomExitCode.usage,
    );
  }
  final name = parsed.rest.single.trim().toLowerCase();
  if (!RegExp(r'^[a-z][a-z0-9_-]*$').hasMatch(name)) {
    throw LoomCliException(
      'Flavor names must start with a letter and contain lowercase letters, numbers, dashes, or underscores.',
      LoomExitCode.usage,
    );
  }
  final project = LoomProjectConfig.discover(
    directory,
    explicitPath: parsed.option('config'),
  );
  final document = loadYaml(project.configFile.readAsStringSync());
  final flavors = document is YamlMap ? document['flavors'] : null;
  final existsInline = flavors is YamlMap && flavors.containsKey(name);
  if (parsed.flag('override')) {
    if (!existsInline) {
      throw LoomCliException(
        'Define flavor $name in sqlite_loom.yaml before creating an override.',
        LoomExitCode.invalidProject,
      );
    }
    final file = File(
      p.join(project.flavorOverridesDirectory.path, '$name.yaml'),
    );
    if (file.existsSync() && !parsed.flag('force')) {
      throw LoomCliException(
        '${file.path} already exists. Pass --force to replace it.',
        LoomExitCode.refused,
      );
    }
    _writeManaged(file, _overrideTemplate(name), force: true);
    out('✓ Created ${p.relative(file.path, from: project.root.path)}');
  } else {
    if (existsInline && !parsed.flag('force')) {
      throw LoomCliException(
        'Flavor $name already exists in sqlite_loom.yaml.',
        LoomExitCode.refused,
      );
    }
    if (existsInline) {
      throw const LoomCliException(
        'Replacing inline flavors is not supported; edit sqlite_loom.yaml explicitly.',
        LoomExitCode.refused,
      );
    }
    _insertInlineFlavor(project.configFile, name);
    out('✓ Added flavor $name to sqlite_loom.yaml');
  }
  out('Run database commands with --flavor $name');
  return LoomExitCode.success;
}

int _syncCommand(
  Directory directory,
  List<String> arguments, {
  required LoomCliWriter out,
}) {
  final parser = ArgParser()..addOption('config');
  final parsed = _parse(parser, arguments, 'migrate:sync');
  _requireNoRest(parsed, 'migrate:sync');
  final project = LoomProjectConfig.discover(
    directory,
    explicitPath: parsed.option('config'),
  );
  final migrations = _syncProject(project);
  out('✓ Updated migration index for ${migrations.length} migrations');
  return LoomExitCode.success;
}

int _finalizeCommand(
  Directory directory,
  List<String> arguments, {
  required LoomCliWriter out,
}) {
  final parser = ArgParser()..addOption('config');
  final parsed = _parse(parser, arguments, 'migrate:finalize');
  _requireNoRest(parsed, 'migrate:finalize');
  final project = LoomProjectConfig.discover(
    directory,
    explicitPath: parsed.option('config'),
  );
  final migrations = _syncProject(project);
  _writeMigrationLock(project, migrations);
  out('✓ Finalized ${migrations.length} migrations');
  return LoomExitCode.success;
}

int _retireCommand(
  Directory directory,
  List<String> arguments, {
  required LoomCliWriter out,
}) {
  final parser = ArgParser()
    ..addOption('config')
    ..addOption('into', help: 'Active migration containing the merged schema.');
  final parsed = _parse(parser, arguments, 'migrate:retire');
  if (parsed.rest.length != 1 || parsed.option('into') == null) {
    throw const LoomCliException(
      'Usage: migrate:retire <version> --into <replacement-version>',
      LoomExitCode.usage,
    );
  }
  final version = _positiveVersion(parsed.rest.single, 'version');
  final replacement = _positiveVersion(parsed.option('into')!, '--into');
  if (version == replacement) {
    throw const LoomCliException(
      'A retired migration cannot replace itself.',
      LoomExitCode.usage,
    );
  }
  final project = LoomProjectConfig.discover(
    directory,
    explicitPath: parsed.option('config'),
  );
  final migrations = _discoverMigrations(project);
  if (migrations.any((item) => item.version == version)) {
    throw LoomCliException(
      'Migration $version still exists in source. Merge its behavior, then remove its source file before retiring it.',
      LoomExitCode.refused,
    );
  }
  if (!migrations.any((item) => item.version == replacement)) {
    throw LoomCliException(
      'Replacement migration $replacement does not exist in source.',
      LoomExitCode.missingInput,
    );
  }
  final lock = _readMigrationLock(project);
  final active = lock['migrations']! as Map<String, dynamic>;
  final retired = lock['retired']! as Map<String, dynamic>;
  final key = '$version';
  final existing = retired[key];
  if (existing is Map && existing['replaced_by'] == replacement) {
    _syncProject(project);
    out('✓ Migration $version is already retired into $replacement');
    return LoomExitCode.success;
  }
  final record = active.remove(key);
  if (record is! Map) {
    throw LoomCliException(
      'Finalized migration $version is not in the lock.',
      LoomExitCode.missingInput,
    );
  }
  if (!active.containsKey('$replacement')) {
    throw LoomCliException(
      'Replacement migration $replacement must be finalized first.',
      LoomExitCode.refused,
    );
  }
  final issues = _lockedSourceIssues(project, migrations, lock: lock)
      .where(
        (issue) => issue != 'Locked migration $version is missing from source.',
      )
      .toList();
  if (issues.isNotEmpty) {
    throw LoomCliException(issues.join(' '), LoomExitCode.refused);
  }
  retired[key] = <String, dynamic>{
    'name': record['name'],
    'sha256': record['sha256'],
    'replaced_by': replacement,
  };
  _writeLockDocument(project, lock);
  _syncProject(project);
  out('✓ Retired migration $version into $replacement');
  return LoomExitCode.success;
}

int _unretireCommand(
  Directory directory,
  List<String> arguments, {
  required LoomCliWriter out,
}) {
  final parser = ArgParser()..addOption('config');
  final parsed = _parse(parser, arguments, 'migrate:unretire');
  if (parsed.rest.length != 1) {
    throw const LoomCliException(
      'Usage: migrate:unretire <version>',
      LoomExitCode.usage,
    );
  }
  final version = _positiveVersion(parsed.rest.single, 'version');
  final project = LoomProjectConfig.discover(
    directory,
    explicitPath: parsed.option('config'),
  );
  final migrations = _discoverMigrations(project);
  final source = migrations
      .where((item) => item.version == version)
      .firstOrNull;
  if (source == null) {
    throw LoomCliException(
      'Restore migration $version source before unretiring it.',
      LoomExitCode.missingInput,
    );
  }
  final lock = _readMigrationLock(project);
  final active = lock['migrations']! as Map<String, dynamic>;
  final retired = lock['retired']! as Map<String, dynamic>;
  final record = retired.remove('$version');
  if (record is! Map) {
    throw LoomCliException(
      'Migration $version is not retired.',
      LoomExitCode.missingInput,
    );
  }
  if (record['sha256'] != source.checksum) {
    throw LoomCliException(
      'Restored migration $version does not match its retired checksum.',
      LoomExitCode.refused,
    );
  }
  final issues = _lockedSourceIssues(project, migrations, lock: lock)
      .where(
        (issue) =>
            issue != 'Retired migration $version is still present in source.',
      )
      .toList();
  if (issues.isNotEmpty) {
    throw LoomCliException(issues.join(' '), LoomExitCode.refused);
  }
  active['$version'] = _lockRecord(project, source);
  _writeLockDocument(project, lock);
  _syncProject(project);
  out('✓ Restored migration $version to active history');
  return LoomExitCode.success;
}

int _positiveVersion(String value, String label) {
  final parsed = int.tryParse(value);
  if (parsed == null || parsed <= 0) {
    throw LoomCliException(
      '$label must be a positive integer.',
      LoomExitCode.usage,
    );
  }
  return parsed;
}

int _validateCommand(
  Directory directory,
  List<String> arguments, {
  required LoomCliWriter out,
}) {
  final parser = ArgParser()
    ..addOption('config')
    ..addFlag('json', negatable: false);
  final parsed = _parse(parser, arguments, 'migrate:validate');
  _requireNoRest(parsed, 'migrate:validate');
  final project = LoomProjectConfig.discover(
    directory,
    explicitPath: parsed.option('config'),
  );
  final result = _validateProject(project);
  if (parsed.flag('json')) {
    out(jsonEncode(result.toJson()));
  } else if (result.isValid) {
    out(
      '✓ ${result.finalizedCount} finalized, ${result.draftCount} draft migrations are valid',
    );
  } else {
    for (final issue in result.issues) {
      out('✗ $issue');
    }
  }
  return result.isValid ? LoomExitCode.success : LoomExitCode.invalidProject;
}

int _listCommand(
  Directory directory,
  List<String> arguments, {
  required LoomCliWriter out,
}) {
  final parser = ArgParser()
    ..addOption('config')
    ..addFlag('json', negatable: false);
  final parsed = _parse(parser, arguments, 'migrate:list');
  _requireNoRest(parsed, 'migrate:list');
  final project = LoomProjectConfig.discover(
    directory,
    explicitPath: parsed.option('config'),
  );
  final migrations = _discoverMigrations(project);
  final finalizedVersions = _finalizedVersions(project);
  if (parsed.flag('json')) {
    out(
      jsonEncode({
        'migrations': migrations
            .map(
              (item) => item.toJson(
                finalized: finalizedVersions.contains(item.version),
              ),
            )
            .toList(),
      }),
    );
  } else if (migrations.isEmpty) {
    out('No migration source files.');
  } else {
    for (final migration in migrations) {
      final state = finalizedVersions.contains(migration.version)
          ? 'finalized'
          : 'draft';
      out('${migration.version} ${migration.name} [$state]');
    }
  }
  return LoomExitCode.success;
}
