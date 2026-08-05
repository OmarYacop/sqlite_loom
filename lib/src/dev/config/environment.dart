import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// A selected SQLite Loom flavor plus arguments for the database command.
final class LoomFlavorSelection {
  const LoomFlavorSelection({
    required this.name,
    required this.databasePath,
    required this.environment,
    required this.allowDestructive,
    required this.arguments,
  });

  final String name;
  final String databasePath;
  final String environment;
  final bool allowDestructive;
  final List<String> arguments;

  /// Loads inline flavor defaults from [projectFile] and an optional override.
  factory LoomFlavorSelection.load(
    List<String> arguments, {
    required File projectFile,
    Map<String, String>? environmentVariables,
  }) {
    final processEnvironment = environmentVariables ?? Platform.environment;
    final forwarded = [...arguments];
    final environmentOption = _takeOption(forwarded, '--env');
    final flavorOption = _takeOption(forwarded, '--flavor');
    if (environmentOption != null && flavorOption != null) {
      throw const FormatException('Use either --env or --flavor, not both.');
    }
    final explicit = flavorOption ?? environmentOption;
    final document = loadYaml(projectFile.readAsStringSync());
    if (document is! YamlMap || document['runner'] is! YamlMap) {
      throw FormatException('${projectFile.path} has no runner configuration.');
    }
    final runner = document['runner']! as YamlMap;
    final flavors = document['flavors'];
    if (flavors is! YamlMap || flavors.isEmpty) {
      throw FormatException('${projectFile.path} must define flavors.');
    }
    final fallback = runner['default_flavor'];
    final name =
        explicit ??
        processEnvironment['SQLITE_LOOM_FLAVOR'] ??
        processEnvironment['CLIENT'] ??
        processEnvironment['APP_FLAVOR'] ??
        (fallback is String ? fallback : 'development');
    _validateFlavorName(name);
    final inline = flavors[name];
    if (inline is! YamlMap) {
      throw FormatException('SQLite Loom flavor is not defined: $name');
    }
    final values = _stringMap(inline);
    final overrides = runner['flavor_overrides_directory'];
    if (overrides is String && overrides.trim().isNotEmpty) {
      final root = p.normalize(
        p.absolute(projectFile.parent.path, overrides.trim()),
      );
      final override = File(p.join(root, '$name.yaml'));
      if (!p.isWithin(root, p.normalize(p.absolute(override.path)))) {
        throw FormatException('Flavor override escapes its directory: $name');
      }
      if (override.existsSync()) {
        final overrideYaml = loadYaml(override.readAsStringSync());
        if (overrideYaml is! YamlMap) {
          throw FormatException('${override.path} must contain a YAML map.');
        }
        _merge(values, _stringMap(overrideYaml));
      }
    }
    final database = values['database'];
    final safety = values['safety'];
    if (database is! Map || database['path'] is! String) {
      throw FormatException('Flavor $name must define database.path.');
    }
    final configuredEnvironment = values['environment'];
    final configuredDestructive = safety is Map
        ? safety['allow_destructive']
        : null;
    return LoomFlavorSelection(
      name: name,
      databasePath: _environmentValue(
        'SQLITE_LOOM_DATABASE',
        database['path']! as String,
        processEnvironment,
      ),
      environment: _environmentValue(
        'SQLITE_LOOM_ENVIRONMENT',
        configuredEnvironment is String ? configuredEnvironment : name,
        processEnvironment,
      ),
      allowDestructive: _environmentBoolean(
        'SQLITE_LOOM_ALLOW_DESTRUCTIVE',
        configuredDestructive is bool ? configuredDestructive : false,
        processEnvironment,
      ),
      arguments: List.unmodifiable(forwarded),
    );
  }
}

String? _takeOption(List<String> arguments, String option) {
  final index = arguments.indexOf(option);
  if (index == -1) return null;
  if (index + 1 >= arguments.length || arguments[index + 1].startsWith('-')) {
    throw FormatException('$option requires a flavor name.');
  }
  final value = arguments[index + 1];
  arguments.removeRange(index, index + 2);
  return value;
}

void _validateFlavorName(String name) {
  if (!RegExp(r'^[a-z][a-z0-9_-]*$').hasMatch(name)) {
    throw FormatException('Invalid SQLite Loom flavor name: $name');
  }
}

Map<String, Object?> _stringMap(YamlMap yaml) => {
  for (final entry in yaml.entries)
    '${entry.key}': entry.value is YamlMap
        ? _stringMap(entry.value as YamlMap)
        : entry.value,
};

void _merge(Map<String, Object?> target, Map<String, Object?> override) {
  for (final entry in override.entries) {
    final existing = target[entry.key];
    if (existing is Map<String, Object?> &&
        entry.value is Map<String, Object?>) {
      _merge(existing, entry.value! as Map<String, Object?>);
    } else {
      target[entry.key] = entry.value;
    }
  }
}

String _environmentValue(
  String key,
  String configured,
  Map<String, String> environment,
) {
  final override = environment[key];
  if (override != null) return override;
  return configured.replaceAllMapped(RegExp(r'\$\{([A-Z][A-Z0-9_]*)\}'), (
    match,
  ) {
    final variable = match.group(1)!;
    final value = environment[variable];
    if (value == null) {
      throw FormatException(
        'Required environment variable is missing: $variable',
      );
    }
    return value;
  });
}

bool _environmentBoolean(
  String key,
  bool configured,
  Map<String, String> environment,
) {
  final value = environment[key];
  if (value == null) return configured;
  switch (value.trim().toLowerCase()) {
    case '1':
    case 'true':
    case 'yes':
    case 'on':
      return true;
    case '0':
    case 'false':
    case 'no':
    case 'off':
      return false;
    default:
      throw FormatException('$key must be a boolean.');
  }
}
