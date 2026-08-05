import 'package:sqflite_common/sqlite_api.dart';

/// SQLite features whose availability varies by runtime version/build.
enum DbFeature {
  returning('RETURNING'),
  dropColumn('ALTER TABLE DROP COLUMN'),
  strictTables('STRICT tables'),
  vacuumInto('VACUUM INTO'),
  fts5('FTS5'),
  json1('JSON1');

  const DbFeature(this.label);
  final String label;
}

/// Parsed SQLite semantic version.
final class DbSqliteVersion implements Comparable<DbSqliteVersion> {
  const DbSqliteVersion(this.major, this.minor, this.patch);

  factory DbSqliteVersion.parse(String value) {
    final parts = value.split('.');
    if (parts.length < 2) {
      throw FormatException('Invalid SQLite version: $value');
    }
    return DbSqliteVersion(
      int.parse(parts[0]),
      int.parse(parts[1]),
      parts.length > 2 ? int.parse(parts[2].split(RegExp(r'\D')).first) : 0,
    );
  }

  final int major;
  final int minor;
  final int patch;

  @override
  int compareTo(DbSqliteVersion other) {
    final majorResult = major.compareTo(other.major);
    if (majorResult != 0) return majorResult;
    final minorResult = minor.compareTo(other.minor);
    if (minorResult != 0) return minorResult;
    return patch.compareTo(other.patch);
  }

  bool atLeast(int major, int minor, [int patch = 0]) =>
      compareTo(DbSqliteVersion(major, minor, patch)) >= 0;

  @override
  String toString() => '$major.$minor.$patch';
}

/// Features supported by the active SQLite runtime.
final class DbCapabilities {
  const DbCapabilities({
    required this.version,
    required this.fts5,
    required this.json1,
  });

  final DbSqliteVersion version;
  final bool fts5;
  final bool json1;

  bool supports(DbFeature feature) => switch (feature) {
    DbFeature.returning || DbFeature.dropColumn => version.atLeast(3, 35),
    DbFeature.strictTables => version.atLeast(3, 37),
    DbFeature.vacuumInto => version.atLeast(3, 27),
    DbFeature.fts5 => fts5,
    DbFeature.json1 => json1,
  };

  void require(DbFeature feature) {
    if (!supports(feature)) {
      throw UnsupportedError(
        '${feature.label} is unavailable in SQLite $version',
      );
    }
  }
}

Future<DbCapabilities> loadDbCapabilities(DatabaseExecutor database) async {
  final versionRows = await database.rawQuery('SELECT sqlite_version() AS v');
  final version = DbSqliteVersion.parse(versionRows.single['v']! as String);
  final optionRows = await database.rawQuery('PRAGMA compile_options');
  final options = optionRows
      .expand((row) => row.values)
      .whereType<String>()
      .map((value) => value.toUpperCase())
      .toSet();
  return DbCapabilities(
    version: version,
    fts5: await _detectFts5(database, options),
    json1: await _detectJson(database, options),
  );
}

Future<bool> _detectFts5(DatabaseExecutor database, Set<String> options) async {
  if (options.any((option) => option.contains('ENABLE_FTS5'))) return true;
  try {
    final rows = await database.rawQuery(
      "SELECT 1 FROM pragma_module_list WHERE name = 'fts5' LIMIT 1",
    );
    return rows.isNotEmpty;
  } catch (_) {
    return false;
  }
}

Future<bool> _detectJson(DatabaseExecutor database, Set<String> options) async {
  if (options.any((option) => option.contains('OMIT_JSON'))) return false;
  try {
    final rows = await database.rawQuery("SELECT json_valid('null') AS value");
    return rows.single['value'] == 1;
  } catch (_) {
    return false;
  }
}

Future<void> requireDbFeature(
  DatabaseExecutor database,
  DbFeature feature,
) async {
  (await loadDbCapabilities(database)).require(feature);
}
