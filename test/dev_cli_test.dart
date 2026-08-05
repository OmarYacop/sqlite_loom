import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite_loom/dev.dart';
import 'package:test/test.dart';

void main() {
  late Directory project;
  late List<String> output;
  late List<String> errors;

  setUp(() {
    project = Directory.systemTemp.createTempSync('sqlite_loom_cli_test_');
    File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: loom_fixture
environment:
  sdk: ^3.9.0
dependencies:
  sqlite_loom: ^0.3.0
dev_dependencies:
  sqflite_common_ffi: ^2.3.6
''');
    output = [];
    errors = [];
  });

  tearDown(() {
    project.deleteSync(recursive: true);
  });

  test(
    'init and make:migration generate a conventional migration project',
    () async {
      expect(
        await runSqliteLoomProjectCli(
          ['init'],
          currentDirectory: project,
          out: output.add,
          error: errors.add,
        ),
        LoomExitCode.success,
      );
      expect(
        File(p.join(project.path, 'sqlite_loom.yaml')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(project.path, 'tool/database.dart')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(project.path, 'sqlite_loom.yaml')).readAsStringSync(),
        contains('flavors:\n  development:'),
      );
      expect(
        File(p.join(project.path, '.gitignore')).readAsStringSync(),
        contains('.sqlite_loom/*.sqlite'),
      );

      DateTime clock() => DateTime.utc(2026, 8, 1, 12, 34, 56);
      for (final name in ['create_users', 'add_email_to_users']) {
        expect(
          await runSqliteLoomProjectCli(
            ['make:migration', name],
            currentDirectory: project,
            clock: clock,
            out: output.add,
            error: errors.add,
          ),
          LoomExitCode.success,
        );
      }

      final migrations =
          Directory(p.join(project.path, 'lib/database/migrations'))
              .listSync()
              .whereType<File>()
              .map((file) => p.basename(file.path))
              .toList()
            ..sort();
      expect(
        migrations,
        containsAll([
          '20260801123456_create_users.dart',
          '20260801123457_add_email_to_users.dart',
        ]),
      );
      final index = File(
        p.join(project.path, 'lib/database/migrations.dart'),
      ).readAsStringSync();
      expect(index, contains('SqliteLoomProject(<DbMigration>['));
      expect(index, isNot(contains('ChecksummedDbMigration(')));
      expect(index, isNot(contains('sha256:')));
      expect(index, isNot(contains('GENERATED CODE')));
      expect(index, contains('CreateUsersMigration()'));
      expect(index, isNot(contains('MigrationPlan')));

      output.clear();
      expect(
        await runSqliteLoomProjectCli(
          ['migrate:validate', '--json'],
          currentDirectory: project,
          out: output.add,
          error: errors.add,
        ),
        LoomExitCode.success,
      );
      final validation = jsonDecode(output.single) as Map<String, Object?>;
      expect(validation['valid'], isTrue);
      expect(validation['finalizedCount'], 0);
      expect(validation['draftCount'], 2);
    },
  );

  test('flavor selection loads YAML and removes --env arguments', () {
    final directory = Directory(p.join(project.path, 'config/sqlite_loom'))
      ..createSync(recursive: true);
    final projectFile = File(p.join(project.path, 'sqlite_loom.yaml'))
      ..writeAsStringSync('''
runner:
  default_flavor: development
  flavor_overrides_directory: config/sqlite_loom
flavors:
  development:
    database:
      path: .sqlite_loom/development.sqlite
    safety:
      allow_destructive: true
  staging:
    environment: staging
    database:
      path: .sqlite_loom/staging.sqlite
    safety:
      allow_destructive: false
''');
    File(p.join(directory.path, 'staging.yaml')).writeAsStringSync('''
database:
  path: .sqlite_loom/staging-override.sqlite
''');
    final flavor = LoomFlavorSelection.load(
      ['migrate', '--env', 'staging', '--json'],
      projectFile: projectFile,
      environmentVariables: {'CLIENT': 'development'},
    );
    expect(flavor.name, 'staging');
    expect(flavor.databasePath, '.sqlite_loom/staging-override.sqlite');
    expect(flavor.environment, 'staging');
    expect(flavor.allowDestructive, isFalse);
    expect(flavor.arguments, ['migrate', '--json']);
    final detected = LoomFlavorSelection.load(
      ['status'],
      projectFile: projectFile,
      environmentVariables: {'CLIENT': 'staging'},
    );
    expect(detected.name, 'staging');
    expect(detected.databasePath, '.sqlite_loom/staging-override.sqlite');
  });

  test('make:flavor creates a selectable flavor safely', () async {
    await runSqliteLoomProjectCli(
      ['init'],
      currentDirectory: project,
      out: output.add,
      error: errors.add,
    );
    expect(
      await runSqliteLoomProjectCli(
        ['make:flavor', 'qa'],
        currentDirectory: project,
        out: output.add,
        error: errors.add,
      ),
      LoomExitCode.success,
    );
    final config = File(p.join(project.path, 'sqlite_loom.yaml'));
    expect(config.readAsStringSync(), contains('  qa:'));
    expect(
      await runSqliteLoomProjectCli(
        ['make:flavor', 'qa', '--override'],
        currentDirectory: project,
        out: output.add,
        error: errors.add,
      ),
      LoomExitCode.success,
    );
    expect(
      File(p.join(project.path, 'config/sqlite_loom/qa.yaml')).existsSync(),
      isTrue,
    );
  });

  test('make:migration scaffolds create and alter-table intents', () async {
    await runSqliteLoomProjectCli(
      ['init'],
      currentDirectory: project,
      out: output.add,
      error: errors.add,
    );
    await runSqliteLoomProjectCli(
      ['make:migration', 'create_users', '--create', 'users'],
      currentDirectory: project,
      clock: () => DateTime.utc(2026, 8, 2),
      out: output.add,
      error: errors.add,
    );
    final create = File(
      p.join(
        project.path,
        'lib/database/migrations/20260802000000_create_users.dart',
      ),
    ).readAsStringSync();
    expect(create, contains("migration.schema.createTable('users'"));
    expect(create, contains('table.id();'));
    expect(create, contains('table.timestamps();'));
    expect(create, contains("migration.schema.dropTable('users')"));

    await runSqliteLoomProjectCli(
      ['make:migration', 'add_email_to_users', '--table', 'users'],
      currentDirectory: project,
      clock: () => DateTime.utc(2026, 8, 2),
      out: output.add,
      error: errors.add,
    );
    final alter = File(
      p.join(
        project.path,
        'lib/database/migrations/20260802000001_add_email_to_users.dart',
      ),
    ).readAsStringSync();
    expect(alter, contains('Change users using migration.schema'));
  });

  test('drafts are editable and finalized migrations are immutable', () async {
    await runSqliteLoomProjectCli(
      ['init'],
      currentDirectory: project,
      out: output.add,
      error: errors.add,
    );
    await runSqliteLoomProjectCli(
      ['make:migration', 'create_users'],
      currentDirectory: project,
      clock: () => DateTime.utc(2026, 8, 1),
      out: output.add,
      error: errors.add,
    );
    final migration = File(
      p.join(
        project.path,
        'lib/database/migrations/20260801000000_create_users.dart',
      ),
    );
    migration.writeAsStringSync(
      '${migration.readAsStringSync()}\n// intentional unreleased edit\n',
    );

    expect(
      await runSqliteLoomProjectCli(
        ['migrate:sync'],
        currentDirectory: project,
        out: output.add,
        error: errors.add,
      ),
      LoomExitCode.success,
    );
    expect(
      await runSqliteLoomProjectCli(
        ['migrate:finalize'],
        currentDirectory: project,
        out: output.add,
        error: errors.add,
      ),
      LoomExitCode.success,
    );
    migration.writeAsStringSync(
      '${migration.readAsStringSync()}\n// changed after release\n',
    );
    expect(
      await runSqliteLoomProjectCli(
        ['migrate:sync'],
        currentDirectory: project,
        out: output.add,
        error: errors.add,
      ),
      LoomExitCode.refused,
    );
    expect(errors.last, contains('changed after it was locked'));
  });

  test(
    'database commands delegate to the generated application runner',
    () async {
      await runSqliteLoomProjectCli(
        ['init'],
        currentDirectory: project,
        out: output.add,
        error: errors.add,
      );
      await runSqliteLoomProjectCli(
        ['make:migration', 'create_users'],
        currentDirectory: project,
        clock: () => DateTime.utc(2026, 8, 1),
        out: output.add,
        error: errors.add,
      );
      final index = File(p.join(project.path, 'lib/database/migrations.dart'))
        ..writeAsStringSync('// stale index\n');
      String? executable;
      List<String>? arguments;
      String? delegatedDirectory;
      final code = await runSqliteLoomProjectCli(
        ['migrate', '--to', '7', '--json'],
        currentDirectory: project,
        out: output.add,
        error: errors.add,
        processRunner:
            (value, values, {required String workingDirectory}) async {
              expect(
                index.readAsStringSync(),
                contains('CreateUsersMigration'),
              );
              executable = value;
              arguments = values;
              delegatedDirectory = workingDirectory;
              return 17;
            },
      );
      expect(code, 17);
      expect(executable, Platform.resolvedExecutable);
      expect(arguments, [
        'run',
        p.join(project.path, 'tool/database.dart'),
        'migrate',
        '--to',
        '7',
        '--json',
      ]);
      expect(delegatedDirectory, project.path);
    },
  );

  test('migrate command family aliases database control commands', () async {
    await runSqliteLoomProjectCli(
      ['init'],
      currentDirectory: project,
      out: output.add,
      error: errors.add,
    );
    List<String>? arguments;
    expect(
      await runSqliteLoomProjectCli(
        ['migrate:status', '--json'],
        currentDirectory: project,
        processRunner:
            (executable, values, {required String workingDirectory}) async {
              arguments = values;
              return 0;
            },
      ),
      LoomExitCode.success,
    );
    expect(arguments, [
      'run',
      p.join(project.path, 'tool/database.dart'),
      'status',
      '--json',
    ]);
  });

  test('native database overlook commands delegate unchanged', () async {
    await runSqliteLoomProjectCli(
      ['init'],
      currentDirectory: project,
      out: output.add,
      error: errors.add,
    );
    List<String>? arguments;
    expect(
      await runSqliteLoomProjectCli(
        ['db:browse', 'users', '--limit', '20', '--json'],
        currentDirectory: project,
        processRunner:
            (executable, values, {required String workingDirectory}) async {
              arguments = values;
              return 0;
            },
      ),
      LoomExitCode.success,
    );
    expect(arguments, [
      'run',
      p.join(project.path, 'tool/database.dart'),
      'db:browse',
      'users',
      '--limit',
      '20',
      '--json',
    ]);
  });

  test('retire and unretire move finalized history through the lock', () async {
    await runSqliteLoomProjectCli(
      ['init'],
      currentDirectory: project,
      out: output.add,
      error: errors.add,
    );
    for (final entry in <(String, DateTime)>[
      ('create_users', DateTime.utc(2026, 8, 1)),
      ('add_profiles', DateTime.utc(2026, 8, 2)),
    ]) {
      await runSqliteLoomProjectCli(
        ['make:migration', entry.$1],
        currentDirectory: project,
        clock: () => entry.$2,
        out: output.add,
        error: errors.add,
      );
    }
    await runSqliteLoomProjectCli(
      ['migrate:finalize'],
      currentDirectory: project,
      out: output.add,
      error: errors.add,
    );
    final retiredSource = File(
      p.join(
        project.path,
        'lib/database/migrations/20260802000000_add_profiles.dart',
      ),
    );
    final original = retiredSource.readAsStringSync();
    retiredSource.deleteSync();

    expect(
      await runSqliteLoomProjectCli(
        ['migrate:retire', '20260802000000', '--into', '20260801000000'],
        currentDirectory: project,
        out: output.add,
        error: errors.add,
      ),
      LoomExitCode.success,
    );
    var lock =
        jsonDecode(
              File(
                p.join(project.path, '.sqlite_loom/migrations.lock.json'),
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect((lock['migrations'] as Map).containsKey('20260802000000'), isFalse);
    final retiredRecord = Map<String, dynamic>.from(
      (lock['retired'] as Map)['20260802000000'] as Map,
    );
    expect(retiredRecord['replaced_by'], 20260801000000);
    expect(
      File(
        p.join(project.path, 'lib/database/migrations.dart'),
      ).readAsStringSync(),
      contains('retiredVersions: <int>{20260802000000}'),
    );

    retiredSource.writeAsStringSync(original);
    expect(
      await runSqliteLoomProjectCli(
        ['migrate:unretire', '20260802000000'],
        currentDirectory: project,
        out: output.add,
        error: errors.add,
      ),
      LoomExitCode.success,
    );
    lock =
        jsonDecode(
              File(
                p.join(project.path, '.sqlite_loom/migrations.lock.json'),
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect((lock['migrations'] as Map).containsKey('20260802000000'), isTrue);
    expect((lock['retired'] as Map), isEmpty);
  });
}
