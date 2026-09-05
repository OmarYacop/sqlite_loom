import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

part 'project_commands.dart';
part 'migration_sources.dart';
part 'project_templates.dart';

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
      out('sqlite_loom 0.4.0');
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
          return await _delegate(directory, [
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
