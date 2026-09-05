part of 'project_cli.dart';

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
