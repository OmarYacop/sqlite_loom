import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Output callback used by the project CLI.
typedef LoomCliWriter = void Function(String message);

/// Runs a child process and returns its exit code.
typedef LoomProcessRunner =
    Future<int> Function(
      String executable,
      List<String> arguments, {
      required String workingDirectory,
    });

/// Time source used to create deterministic timestamp migration versions.
typedef LoomClock = DateTime Function();

/// Stable process exit codes emitted by the project CLI.
abstract final class LoomExitCode {
  static const success = 0;
  static const failure = 1;
  static const usage = 64;
  static const invalidProject = 65;
  static const missingInput = 66;
  static const refused = 73;
}

/// Parsed `sqlite_loom.yaml` project configuration.
final class LoomProjectConfig {
  const LoomProjectConfig._({
    required this.root,
    required this.configFile,
    required this.packageName,
    required this.migrationsDirectory,
    required this.indexFile,
    required this.lockFile,
    required this.runnerFile,
    required this.flavorOverridesDirectory,
    required this.defaultFlavor,
  });

  final Directory root;
  final File configFile;
  final String packageName;
  final Directory migrationsDirectory;
  final File indexFile;
  final File lockFile;
  final File runnerFile;
  final Directory flavorOverridesDirectory;
  final String defaultFlavor;

  /// Finds and parses project configuration, searching parent directories.
  static LoomProjectConfig discover(Directory start, {String? explicitPath}) {
    final configFile = explicitPath == null
        ? _findConfig(start)
        : File(p.normalize(p.absolute(start.path, explicitPath)));
    if (configFile == null || !configFile.existsSync()) {
      throw LoomCliException(
        'Could not find sqlite_loom.yaml. Run `dart run sqlite_loom init`.',
        LoomExitCode.missingInput,
      );
    }
    final root = configFile.parent;
    final document = loadYaml(configFile.readAsStringSync());
    if (document is! YamlMap) {
      throw LoomCliException(
        '${configFile.path} must contain a YAML map.',
        LoomExitCode.invalidProject,
      );
    }
    final version = document['version'];
    if (version != 1) {
      throw LoomCliException(
        'Unsupported sqlite_loom.yaml version: $version',
        LoomExitCode.invalidProject,
      );
    }
    final migrations = _yamlMap(document, 'migrations');
    final runner = _yamlMap(document, 'runner');
    final packageName = _readPackageName(root);
    final legacyRegistry = migrations['registry'];
    return LoomProjectConfig._(
      root: root,
      configFile: configFile,
      packageName: packageName,
      migrationsDirectory: Directory(
        _safeProjectPath(root, _yamlString(migrations, 'directory')),
      ),
      indexFile: File(
        _safeProjectPath(
          root,
          _yamlString(
            migrations,
            'index',
            fallback: legacyRegistry is String ? legacyRegistry : null,
          ),
        ),
      ),
      lockFile: File(
        _safeProjectPath(
          root,
          _yamlString(
            migrations,
            'lock',
            fallback: '.sqlite_loom/migrations.lock.json',
          ),
        ),
      ),
      runnerFile: File(_safeProjectPath(root, _yamlString(runner, 'path'))),
      flavorOverridesDirectory: Directory(
        _safeProjectPath(
          root,
          _yamlString(
            runner,
            'flavor_overrides_directory',
            fallback: 'config/sqlite_loom',
          ),
        ),
      ),
      defaultFlavor: _yamlString(
        runner,
        'default_flavor',
        fallback: 'development',
      ),
    );
  }
}

/// Runs SQLite Loom's project-aware developer CLI.
Future<int> runSqliteLoomProjectCli(
  List<String> arguments, {
  Directory? currentDirectory,
  LoomCliWriter out = print,
  LoomCliWriter error = _stderr,
  LoomClock clock = _utcNow,
  LoomProcessRunner processRunner = _inheritProcess,
}) async {
  final directory = currentDirectory ?? Directory.current;
  try {
    if (arguments.isEmpty || _isHelp(arguments.first)) {
      _printProjectHelp(out);
      return LoomExitCode.success;
    }
    if (arguments.first == '--version' || arguments.first == 'version') {
      out('sqlite_loom 0.3.0');
      return LoomExitCode.success;
    }
    final command = arguments.first;
    final tail = arguments.sublist(1);
    switch (command) {
      case 'init':
        return _init(directory, tail, out: out);
      case 'make:migration':
      case 'migration:create':
        return _makeMigration(directory, tail, clock: clock, out: out);
      case 'make:flavor':
      case 'flavor:create':
        return _makeFlavor(directory, tail, out: out);
      case 'migrate:sync':
      case 'migration:sync':
        return _syncCommand(directory, tail, out: out);
      case 'migrate:validate':
      case 'migration:validate':
        return _validateCommand(directory, tail, out: out);
      case 'migrate:list':
      case 'migration:list':
        return _listCommand(directory, tail, out: out);
      case 'migrate:finalize':
        return _finalizeCommand(directory, tail, out: out);
      case 'migrate:retire':
        return _retireCommand(directory, tail, out: out);
      case 'migrate:unretire':
        return _unretireCommand(directory, tail, out: out);
      case 'doctor':
        return _doctor(directory, tail, out: out, error: error);
      default:
        final runtimeCommand = _runnerAliases[command] ?? command;
        if (_runnerCommands.contains(runtimeCommand)) {
          return _delegate(directory, [
            runtimeCommand,
            ...tail,
          ], processRunner: processRunner);
        }
        throw LoomCliException(
          'Unknown sqlite_loom command: $command',
          LoomExitCode.usage,
        );
    }
  } on LoomCliException catch (exception) {
    error('Error: ${exception.message}');
    return exception.exitCode;
  } on FormatException catch (exception) {
    error('Error: ${exception.message}');
    return LoomExitCode.usage;
  }
}

final class LoomCliException implements Exception {
  const LoomCliException(this.message, this.exitCode);
  final String message;
  final int exitCode;
  @override
  String toString() => message;
}

const _runnerCommands = <String>{
  'migrate',
  'status',
  'rollback',
  'redo',
  'reset',
  'refresh',
  'fresh',
  'sandbox',
  'schema:dump',
  'schema:diff',
  'db:inspect',
  'db:tables',
  'db:describe',
  'db:browse',
  'db:query',
  'db:explain',
  'db:export',
  'db:insert',
  'db:update',
  'db:delete',
  'db:truncate',
  'db:execute',
  'db:import',
  'db:copy',
  'db:vacuum',
  'db:integrity',
  'db:optimize',
  'db:backup',
  'db:restore',
};

const _runnerAliases = <String, String>{
  'migrate:status': 'status',
  'migrate:rollback': 'rollback',
  'migrate:redo': 'redo',
  'migrate:reset': 'reset',
  'migrate:refresh': 'refresh',
  'migrate:fresh': 'fresh',
};

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

Set<int> _finalizedVersions(LoomProjectConfig project) {
  if (!project.lockFile.existsSync()) return const {};
  try {
    final lock = jsonDecode(project.lockFile.readAsStringSync());
    if (lock is! Map || lock['migrations'] is! Map) return const {};
    return (lock['migrations'] as Map).keys
        .map((key) => int.tryParse('$key'))
        .whereType<int>()
        .toSet();
  } on FormatException {
    return const {};
  }
}

Set<int> _retiredVersions(LoomProjectConfig project) {
  if (!project.lockFile.existsSync()) return const {};
  try {
    final lock = jsonDecode(project.lockFile.readAsStringSync());
    if (lock is! Map || lock['retired'] is! Map) return const {};
    return (lock['retired'] as Map).keys
        .map((key) => int.tryParse('$key'))
        .whereType<int>()
        .toSet();
  } on FormatException {
    return const {};
  }
}

int _doctor(
  Directory directory,
  List<String> arguments, {
  required LoomCliWriter out,
  required LoomCliWriter error,
}) {
  final parser = ArgParser()..addOption('config');
  final parsed = _parse(parser, arguments, 'doctor');
  _requireNoRest(parsed, 'doctor');
  final project = LoomProjectConfig.discover(
    directory,
    explicitPath: parsed.option('config'),
  );
  final issues = <String>[];
  if (!project.runnerFile.existsSync()) {
    issues.add('Runner is missing: ${project.runnerFile.path}');
  }
  if (!project.indexFile.existsSync()) {
    issues.add('Migration index is missing: ${project.indexFile.path}');
  }
  final projectYaml = loadYaml(project.configFile.readAsStringSync());
  final flavors = projectYaml is YamlMap ? projectYaml['flavors'] : null;
  if (flavors is! YamlMap || !flavors.containsKey(project.defaultFlavor)) {
    issues.add(
      'Default flavor is not defined inline: ${project.defaultFlavor}',
    );
  }
  final pubspec = File(
    p.join(project.root.path, 'pubspec.yaml'),
  ).readAsStringSync();
  if (!RegExp(
    r'^\s*sqflite_common_ffi\s*:',
    multiLine: true,
  ).hasMatch(pubspec)) {
    issues.add(
      'Add sqflite_common_ffi as a dev dependency for the generated runner.',
    );
  }
  final validation = _validateProject(project);
  issues.addAll(validation.issues);
  if (issues.isEmpty) {
    out('✓ Configuration: ${project.configFile.path}');
    out('✓ Runner: ${project.runnerFile.path}');
    out('✓ ${validation.migrationCount} migrations are synchronized');
    out('✓ SQLite Loom project is healthy');
    return LoomExitCode.success;
  }
  for (final issue in issues) {
    error('✗ $issue');
  }
  return LoomExitCode.failure;
}

Future<int> _delegate(
  Directory directory,
  List<String> arguments, {
  required LoomProcessRunner processRunner,
}) async {
  final configIndex = arguments.indexOf('--config');
  String? explicitConfig;
  if (configIndex != -1) {
    if (configIndex + 1 >= arguments.length) {
      throw const LoomCliException(
        '--config requires a path.',
        LoomExitCode.usage,
      );
    }
    explicitConfig = arguments[configIndex + 1];
  }
  final project = LoomProjectConfig.discover(
    directory,
    explicitPath: explicitConfig,
  );
  _syncProject(project);
  if (!project.runnerFile.existsSync()) {
    throw LoomCliException(
      'Runner is missing: ${project.runnerFile.path}. Run `dart run sqlite_loom init`.',
      LoomExitCode.missingInput,
    );
  }
  final forwarded = [...arguments];
  if (configIndex != -1) {
    forwarded.removeRange(configIndex, configIndex + 2);
  }
  return processRunner(Platform.resolvedExecutable, [
    'run',
    project.runnerFile.path,
    ...forwarded,
  ], workingDirectory: project.root.path);
}

List<_MigrationSource> _syncProject(LoomProjectConfig project) {
  final migrations = _discoverMigrations(project);
  if (project.lockFile.existsSync()) {
    final issues = _lockedSourceIssues(project, migrations);
    if (issues.isNotEmpty) {
      throw LoomCliException(
        '${issues.join(' ')} Finalized migrations are immutable; create a new migration.',
        LoomExitCode.refused,
      );
    }
  }
  project.indexFile.parent.createSync(recursive: true);
  project.lockFile.parent.createSync(recursive: true);
  project.indexFile.writeAsStringSync(_indexContents(project, migrations));
  if (!project.lockFile.existsSync()) {
    _writeMigrationLock(project, const []);
  }
  return migrations;
}

void _writeMigrationLock(
  LoomProjectConfig project,
  List<_MigrationSource> migrations,
) {
  final retired = project.lockFile.existsSync()
      ? _readMigrationLock(project)['retired']! as Map<String, dynamic>
      : <String, dynamic>{};
  _writeLockDocument(project, <String, dynamic>{
    'version': 1,
    'migrations': <String, dynamic>{
      for (final migration in migrations)
        '${migration.version}': _lockRecord(project, migration),
    },
    'retired': retired,
  });
}

Map<String, dynamic> _lockRecord(
  LoomProjectConfig project,
  _MigrationSource migration,
) => <String, dynamic>{
  'name': migration.name,
  'path': p.relative(migration.file.path, from: project.root.path),
  'sha256': migration.checksum,
};

Map<String, dynamic> _readMigrationLock(LoomProjectConfig project) {
  if (!project.lockFile.existsSync()) {
    throw LoomCliException(
      'Migration lock is missing. Run `migrate:finalize`.',
      LoomExitCode.missingInput,
    );
  }
  final decoded = jsonDecode(project.lockFile.readAsStringSync());
  if (decoded is! Map ||
      decoded['version'] != 1 ||
      decoded['migrations'] is! Map) {
    throw const LoomCliException(
      'Migration lock has an unsupported format.',
      LoomExitCode.invalidProject,
    );
  }
  final retired = decoded['retired'];
  if (retired != null && retired is! Map) {
    throw const LoomCliException(
      'Migration lock retired history has an unsupported format.',
      LoomExitCode.invalidProject,
    );
  }
  return <String, dynamic>{
    'version': 1,
    'migrations': Map<String, dynamic>.from(decoded['migrations'] as Map),
    'retired': retired == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(retired as Map),
  };
}

void _writeLockDocument(
  LoomProjectConfig project,
  Map<String, dynamic> document,
) {
  project.lockFile.parent.createSync(recursive: true);
  project.lockFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(document)}\n',
  );
}

_ValidationResult _validateProject(LoomProjectConfig project) {
  final migrations = _discoverMigrations(project);
  final issues = <String>[];
  var finalizedCount = 0;
  if (!project.lockFile.existsSync()) {
    issues.add('Migration lock is missing. Run `migrate:finalize`.');
  } else {
    try {
      final lock = jsonDecode(project.lockFile.readAsStringSync());
      if (lock is! Map ||
          lock['version'] != 1 ||
          lock['migrations'] is! Map ||
          (lock['retired'] != null && lock['retired'] is! Map)) {
        issues.add('Migration lock has an unsupported format.');
      } else {
        finalizedCount = (lock['migrations'] as Map).length;
        issues.addAll(_lockedSourceIssues(project, migrations, lock: lock));
      }
    } on FormatException {
      issues.add('Migration lock is not valid JSON.');
    }
  }
  final expectedIndex = _indexContents(project, migrations);
  if (!project.indexFile.existsSync()) {
    issues.add('Migration index is missing. Run `migrate:sync`.');
  } else if (project.indexFile.readAsStringSync() != expectedIndex) {
    issues.add('Migration index is out of date. Run `migrate:sync`.');
  }
  return _ValidationResult(
    migrations.length,
    finalizedCount,
    List.unmodifiable(issues),
  );
}

List<String> _lockedSourceIssues(
  LoomProjectConfig project,
  List<_MigrationSource> migrations, {
  Object? lock,
}) {
  final decoded = lock ?? jsonDecode(project.lockFile.readAsStringSync());
  if (decoded is! Map || decoded['migrations'] is! Map) {
    return const ['Migration lock has an unsupported format.'];
  }
  final locked = decoded['migrations'] as Map;
  final retired = decoded['retired'] is Map
      ? decoded['retired'] as Map
      : const <Object?, Object?>{};
  final lockedVersions = locked.keys.map((key) => '$key').toSet();
  final actualVersions = migrations
      .map((migration) => '${migration.version}')
      .toSet();
  final issues = <String>[];
  for (final key in retired.keys) {
    if (locked.containsKey(key)) {
      issues.add('Migration $key cannot be both active and retired.');
    }
    if (actualVersions.contains('$key')) {
      issues.add('Retired migration $key is still present in source.');
    }
    final record = retired[key];
    final replacement = record is Map ? record['replaced_by'] : null;
    if (record is! Map || replacement is! int || replacement <= 0) {
      issues.add('Retired migration $key has invalid lock metadata.');
    } else if (!actualVersions.contains('$replacement')) {
      issues.add(
        'Retired migration $key replacement $replacement is missing from source.',
      );
    }
  }
  // Source versions absent from the lock are editable drafts.
  for (final removed in lockedVersions.difference(actualVersions)) {
    issues.add('Locked migration $removed is missing from source.');
  }
  for (final migration in migrations) {
    final record = locked['${migration.version}'];
    if (record != null &&
        (record is! Map || record['sha256'] != migration.checksum)) {
      issues.add(
        'Migration ${migration.version}_${migration.name} changed after it was locked.',
      );
    }
  }
  return issues;
}

List<_MigrationSource> _discoverMigrations(LoomProjectConfig project) {
  if (!project.migrationsDirectory.existsSync()) return const [];
  final migrations = <_MigrationSource>[];
  final versions = <int>{};
  final pattern = RegExp(r'^(\d{14})_([a-z][a-z0-9_]*)\.dart$');
  for (final entity in project.migrationsDirectory.listSync()) {
    if (entity is! File) continue;
    final match = pattern.firstMatch(p.basename(entity.path));
    if (match == null) continue;
    final version = int.parse(match.group(1)!);
    final name = match.group(2)!;
    if (!versions.add(version)) {
      throw LoomCliException(
        'Duplicate migration version $version.',
        LoomExitCode.invalidProject,
      );
    }
    final source = entity.readAsStringSync().replaceAll('\r\n', '\n');
    final className = '${_pascalCase(name)}Migration';
    if (!RegExp(
      'class\\s+$className\\s+extends\\s+DbMigration',
    ).hasMatch(source)) {
      throw LoomCliException(
        '${entity.path} must declare $className extending DbMigration.',
        LoomExitCode.invalidProject,
      );
    }
    if (!RegExp(
          'int\\s+get\\s+version\\s*=>\\s*$version\\s*;',
        ).hasMatch(source) ||
        !RegExp(
          "String\\s+get\\s+name\\s*=>\\s*'$name'\\s*;",
        ).hasMatch(source)) {
      throw LoomCliException(
        '${entity.path} metadata must match its filename.',
        LoomExitCode.invalidProject,
      );
    }
    migrations.add(
      _MigrationSource(
        version: version,
        name: name,
        className: className,
        file: entity,
        checksum: 'sha256:${sha256.convert(utf8.encode(source))}',
      ),
    );
  }
  migrations.sort((left, right) => left.version.compareTo(right.version));
  return migrations;
}

String _indexContents(
  LoomProjectConfig project,
  List<_MigrationSource> migrations,
) {
  final buffer = StringBuffer()
    ..writeln('// SQLite Loom migration index.')
    ..writeln('// Maintained only when you run SQLite Loom commands.')
    ..writeln('// Edit migration implementations in the migrations directory.')
    ..writeln()
    ..writeln("import 'package:sqlite_loom/sqlite_loom.dart';");
  for (final migration in migrations) {
    final importPath = p
        .relative(migration.file.path, from: project.indexFile.parent.path)
        .replaceAll('\\', '/');
    buffer.writeln("import '$importPath';");
  }
  final retired = _retiredVersions(project).toList()..sort();
  buffer.writeln();
  if (retired.isEmpty) {
    buffer.writeln(
      'const sqliteLoomProject = SqliteLoomProject(<DbMigration>[',
    );
  } else {
    buffer
      ..writeln('const sqliteLoomProject = SqliteLoomProject(')
      ..writeln('  <DbMigration>[');
  }
  for (final migration in migrations) {
    buffer.writeln(
      '${retired.isEmpty ? '  ' : '    '}${migration.className}(),',
    );
  }
  if (retired.isEmpty) {
    buffer.writeln(']);');
  } else {
    buffer
      ..writeln('  ],')
      ..writeln('  retiredVersions: <int>{${retired.join(', ')}},')
      ..writeln(');');
  }
  return buffer.toString();
}

String _migrationTemplate(
  int version,
  String name, {
  String? createTable,
  String? alterTable,
}) {
  final className = '${_pascalCase(name)}Migration';
  final upBody = switch ((createTable, alterTable)) {
    (final String table, null) =>
      '''    await migration.schema.createTable('$table', (table) {
      table.id();
      table.timestamps();
    });''',
    (null, final String table) =>
      '''    // Change $table using migration.schema.
    // Example:
    // await migration.schema.addColumn(
    //   '$table',
    //   DbColumnDefinition.trusted('column_name', 'TEXT'),
    // );''',
    _ =>
      '''    // Define the forward migration with type-safe schema helpers.
    // Example:
    // await migration.schema.createTable('users', (table) { ... });''',
  };
  final downBody = switch ((createTable, alterTable)) {
    (final String table, null) =>
      "    await migration.schema.dropTable('$table');",
    (null, final String table) =>
      '''    // Reverse the change to $table when it is safe.
    throw UnsupportedError('Define the rollback for $name');''',
    _ =>
      '''    // Define a safe rollback, or throw UnsupportedError explicitly.
    // Example: await migration.schema.dropTable('users');''',
  };
  return '''// ignore_for_file: file_names

import 'package:sqlite_loom/sqlite_loom.dart';

final class $className extends DbMigration {
  const $className();

  @override
  int get version => $version;

  @override
  String get name => '$name';

  @override
  Future<void> up(DbMigrationContext migration) async {
$upBody
  }

  @override
  Future<void> down(DbMigrationContext migration) async {
$downBody
  }
}
''';
}

String _runnerTemplate(LoomProjectConfig project, String packageName) {
  final indexRelative = p
      .relative(project.indexFile.path, from: p.join(project.root.path, 'lib'))
      .replaceAll('\\', '/');
  final indexImport = 'package:$packageName/$indexRelative';
  return '''import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite_loom/dev.dart';
import 'package:sqlite_loom/sqlite_loom.dart';
import '$indexImport';

Future<void> main(List<String> arguments) async {
  sqfliteFfiInit();
  final flavor = LoomFlavorSelection.load(
    arguments,
    projectFile: File('sqlite_loom.yaml'),
  );
  final code = await runSqliteLoomCli(
    flavor.arguments,
    openDatabase: () async {
      final file = File(flavor.databasePath);
      await file.parent.create(recursive: true);
      return databaseFactoryFfi.openDatabase(file.path);
    },
    migrations: sqliteLoomProject.migrations,
    retiredVersions: sqliteLoomProject.retiredVersions,
    environment: flavor.environment,
    databaseDescription: flavor.databasePath,
    allowDestructive: flavor.allowDestructive,
    openSandbox: () async {
      final directory = await Directory.systemTemp.createTemp(
        'sqlite_loom_sandbox_',
      );
      final path = '\${directory.path}/sandbox.sqlite';
      final database = await databaseFactoryFfi.openDatabase(path);
      return SqliteLoomSandbox(
        database: database,
        cleanup: () async {
          await databaseFactoryFfi.deleteDatabase(path);
          if (directory.existsSync()) {
            await directory.delete(recursive: true);
          }
        },
      );
    },
    restoreDatabase: (inputPath) async {
      final input = File(inputPath);
      if (!input.existsSync()) {
        throw ArgumentError.value(inputPath, 'inputPath', 'File not found');
      }
      final destination = File(flavor.databasePath);
      await destination.parent.create(recursive: true);
      final temporary = File('\${destination.path}.restore.tmp');
      if (temporary.existsSync()) await temporary.delete();
      await input.copy(temporary.path);
      if (destination.existsSync()) await destination.delete();
      await temporary.rename(destination.path);
    },
    confirmDestructive: (command, databaseDescription) async {
      if (!stdin.hasTerminal) return false;
      stdout.write(
        'Type the database path to confirm \$command on '
        '\$databaseDescription: ',
      );
      return stdin.readLineSync() == databaseDescription;
    },
  );
  exitCode = code;
}
''';
}

const _configTemplate = '''version: 1

migrations:
  directory: lib/database/migrations
  index: lib/database/migrations.dart
  lock: .sqlite_loom/migrations.lock.json

runner:
  path: tool/database.dart
  default_flavor: development
  flavor_overrides_directory: config/sqlite_loom

flavors:
  development:
    environment: development
    database:
      path: .sqlite_loom/development.sqlite
    safety:
      allow_destructive: true
''';

String _inlineFlavorTemplate(String flavor) =>
    '''  $flavor:
    environment: $flavor
    database:
      path: .sqlite_loom/$flavor.sqlite
    safety:
      allow_destructive: false
''';

String _overrideTemplate(String flavor) =>
    '''# Optional overrides for $flavor.
database:
  path: .sqlite_loom/$flavor.local.sqlite

safety:
  allow_destructive: false
''';

void _insertInlineFlavor(File config, String flavor) {
  final source = config.readAsStringSync();
  final lines = source.split('\n');
  final flavorsIndex = lines.indexWhere(
    (line) => RegExp(r'^flavors:\s*$').hasMatch(line),
  );
  if (flavorsIndex == -1) {
    final separator = source.endsWith('\n') ? '' : '\n';
    config.writeAsStringSync(
      '$source${separator}flavors:\n${_inlineFlavorTemplate(flavor)}',
    );
    return;
  }
  var insertion = lines.length;
  for (var index = flavorsIndex + 1; index < lines.length; index += 1) {
    final line = lines[index];
    if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) {
      insertion = index;
      break;
    }
  }
  lines.insert(insertion, _inlineFlavorTemplate(flavor).trimRight());
  config.writeAsStringSync('${lines.join('\n').trimRight()}\n');
}

final class _MigrationSource {
  const _MigrationSource({
    required this.version,
    required this.name,
    required this.className,
    required this.file,
    required this.checksum,
  });
  final int version;
  final String name;
  final String className;
  final File file;
  final String checksum;
  Map<String, Object?> toJson({required bool finalized}) => {
    'version': version,
    'name': name,
    'path': file.path,
    'sha256': checksum,
    'state': finalized ? 'finalized' : 'draft',
  };
}

final class _ValidationResult {
  const _ValidationResult(
    this.migrationCount,
    this.finalizedCount,
    this.issues,
  );
  final int migrationCount;
  final int finalizedCount;
  int get draftCount => migrationCount - finalizedCount;
  final List<String> issues;
  bool get isValid => issues.isEmpty;
  Map<String, Object?> toJson() => {
    'valid': isValid,
    'migrationCount': migrationCount,
    'finalizedCount': finalizedCount,
    'draftCount': draftCount,
    'issues': issues,
  };
}

ArgResults _parse(ArgParser parser, List<String> arguments, String command) {
  if (arguments.any(_isHelp)) {
    throw LoomCliException(
      'Usage for $command:\n${parser.usage}',
      LoomExitCode.success,
    );
  }
  return parser.parse(arguments);
}

void _requireNoRest(ArgResults results, String command) {
  if (results.rest.isNotEmpty) {
    throw LoomCliException(
      '$command does not accept positional arguments.',
      LoomExitCode.usage,
    );
  }
}

String _normalizeMigrationName(String input) {
  final normalized = input
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '')
      .toLowerCase();
  if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(normalized)) {
    throw LoomCliException(
      'Invalid migration name: $input',
      LoomExitCode.usage,
    );
  }
  return normalized;
}

String _pascalCase(String name) => name
    .split('_')
    .where((part) => part.isNotEmpty)
    .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
    .join();

int _nextVersion(Directory directory, DateTime now) {
  var candidate = int.parse(
    '${now.year.toString().padLeft(4, '0')}'
    '${now.month.toString().padLeft(2, '0')}'
    '${now.day.toString().padLeft(2, '0')}'
    '${now.hour.toString().padLeft(2, '0')}'
    '${now.minute.toString().padLeft(2, '0')}'
    '${now.second.toString().padLeft(2, '0')}',
  );
  final used = <int>{};
  if (directory.existsSync()) {
    for (final entity in directory.listSync()) {
      final match = RegExp(r'^(\d{14})_').firstMatch(p.basename(entity.path));
      if (match != null) used.add(int.parse(match.group(1)!));
    }
  }
  while (used.contains(candidate)) {
    candidate += 1;
  }
  return candidate;
}

void _writeManaged(File file, String contents, {required bool force}) {
  if (file.existsSync() && !force) return;
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

void _ensureGitignore(File file, String line) {
  final existing = file.existsSync() ? file.readAsLinesSync() : <String>[];
  if (existing.contains(line)) return;
  final prefix = existing.isEmpty || existing.last.isEmpty ? '' : '\n';
  file.writeAsStringSync('$prefix$line\n', mode: FileMode.append);
}

File? _findConfig(Directory start) {
  var directory = Directory(p.normalize(p.absolute(start.path)));
  while (true) {
    final candidate = File(p.join(directory.path, 'sqlite_loom.yaml'));
    if (candidate.existsSync()) return candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) return null;
    directory = parent;
  }
}

String _readPackageName(Directory root) {
  final pubspec = File(p.join(root.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    throw LoomCliException(
      'Missing pubspec.yaml in ${root.path}.',
      LoomExitCode.invalidProject,
    );
  }
  final yaml = loadYaml(pubspec.readAsStringSync());
  if (yaml is! YamlMap || yaml['name'] is! String) {
    throw const LoomCliException(
      'pubspec.yaml must define a package name.',
      LoomExitCode.invalidProject,
    );
  }
  return yaml['name']! as String;
}

YamlMap _yamlMap(YamlMap parent, String key) {
  final value = parent[key];
  if (value is! YamlMap) {
    throw LoomCliException(
      'sqlite_loom.yaml must define `$key` as a map.',
      LoomExitCode.invalidProject,
    );
  }
  return value;
}

String _yamlString(YamlMap map, String key, {String? fallback}) {
  final value = map[key] ?? fallback;
  if (value is! String || value.trim().isEmpty) {
    throw LoomCliException(
      'sqlite_loom.yaml must define a non-empty `$key`.',
      LoomExitCode.invalidProject,
    );
  }
  return value;
}

String _safeProjectPath(Directory root, String relative) {
  if (p.isAbsolute(relative)) {
    throw LoomCliException(
      'Managed project paths must be relative: $relative',
      LoomExitCode.invalidProject,
    );
  }
  final rootPath = p.normalize(p.absolute(root.path));
  final resolved = p.normalize(p.absolute(rootPath, relative));
  if (resolved != rootPath && !p.isWithin(rootPath, resolved)) {
    throw LoomCliException(
      'Managed path escapes the project root: $relative',
      LoomExitCode.invalidProject,
    );
  }
  return resolved;
}

bool _isHelp(String value) =>
    value == 'help' || value == '--help' || value == '-h';
DateTime _utcNow() => DateTime.now().toUtc();
void _stderr(String message) => stderr.writeln(message);

Future<int> _inheritProcess(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

void _printProjectHelp(LoomCliWriter out) {
  out('SQLite Loom developer tools');
  out('');
  out('Project commands:');
  out('  init [--force]');
  out('  make:migration <name> [--create table | --table table]');
  out('  make:flavor <name> [--override]');
  out('  migrate:list [--json]');
  out('  migrate:sync');
  out('  migrate:validate [--json]');
  out('  migrate:finalize');
  out('  migrate:retire <version> --into <replacement-version>');
  out('  migrate:unretire <version>');
  out('  doctor');
  out('');
  out('Database commands (delegated to the project runner):');
  out('  migrate [--to version] [--flavor name]');
  out('  migrate:status [--json]');
  out('  migrate:rollback [--steps n]');
  out('  migrate:redo [--steps n]');
  out('  migrate:reset --force');
  out('  migrate:refresh --force');
  out('  migrate:fresh --force');
  out('  sandbox');
  out('  schema:dump [--json]');
  out('  schema:diff [--json]');
  out('  db:inspect | db:integrity | db:optimize');
  out('  db:tables | db:describe <table> | db:browse <table>');
  out('  db:query --sql <sql> | db:explain --sql <sql>');
  out('  db:export <table> --output <path> [--format csv|json] [--force]');
  out('  db:insert <table> (--values-json <object> | --value column=value)');
  out('  db:update | db:delete | db:truncate (guarded mutations)');
  out('  db:execute --sql <sql> --force | db:import | db:copy');
  out('  db:vacuum');
  out('  db:backup --output <path>');
  out('  db:restore --input <path> --force');
}
