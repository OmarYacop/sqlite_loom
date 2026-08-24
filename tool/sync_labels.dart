import 'dart:io';

import 'package:yaml/yaml.dart';

Future<void> main(List<String> arguments) async {
  final apply = arguments.contains('--apply');
  if (arguments.any((argument) => argument != '--apply')) {
    stderr.writeln('Usage: dart run tool/sync_labels.dart [--apply]');
    exit(64);
  }

  final repository = await _capture('gh', [
    'repo',
    'view',
    '--json',
    'nameWithOwner',
    '--jq',
    '.nameWithOwner',
  ]);
  final document = loadYaml(File('.github/labels.yml').readAsStringSync());
  if (document is! YamlList) {
    stderr.writeln('.github/labels.yml must contain a YAML list.');
    exit(65);
  }

  stdout.writeln(
    apply
        ? 'Synchronizing ${document.length} labels to $repository...'
        : 'Dry run for ${document.length} labels in $repository:',
  );
  for (final item in document) {
    if (item is! YamlMap) {
      stderr.writeln('Every label entry must be a mapping.');
      exit(65);
    }
    final name = item['name']?.toString();
    final color = item['color']?.toString();
    final description = item['description']?.toString();
    if (name == null || color == null || description == null) {
      stderr.writeln('Every label needs name, color, and description: $item');
      exit(65);
    }

    if (!apply) {
      stdout.writeln('- $name (#$color): $description');
      continue;
    }
    await _run('gh', [
      'label',
      'create',
      name,
      '--repo',
      repository,
      '--color',
      color,
      '--description',
      description,
      '--force',
    ]);
  }
  stdout.writeln(
    apply ? 'Label synchronization complete.' : 'No changes made.',
  );
}

Future<String> _capture(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    exit(result.exitCode);
  }
  return (result.stdout as String).trim();
}

Future<void> _run(String executable, List<String> arguments) async {
  final process = await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
  );
  final result = await process.exitCode;
  if (result != 0) exit(result);
}
