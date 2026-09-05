part of 'project_cli.dart';

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
