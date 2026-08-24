import 'dart:io';

const _branchPattern =
    r'^(feat|fix|hotfix|refactor|perf|security|docs|test|ci|build|chore|release)/([0-9]+-)?[a-z0-9]+(-[a-z0-9]+)*$';

Future<void> main(List<String> arguments) async {
  try {
    await _dispatch(arguments);
  } on _CheckFailed catch (error) {
    exitCode = error.exitCode;
  }
}

Future<void> _dispatch(List<String> arguments) async {
  final suite = arguments.firstOrNull ?? 'all';

  switch (suite) {
    case 'policy':
      await _policy();
      return;
    case 'format':
      await _run('dart', [
        'format',
        '--output=none',
        '--set-exit-if-changed',
        'lib',
        'bin',
        'test',
        'example',
        'benchmark',
        'tool',
      ]);
      return;
    case 'analyze':
      await _run('dart', ['analyze']);
      return;
    case 'test':
      await _run('dart', ['test']);
      return;
    case 'core':
      await _runSuite(['format', 'analyze', 'test']);
      return;
    case 'docs':
      await _run('dart', ['doc', '--validate-links']);
      return;
    case 'benchmark':
      await _run('dart', [
        'run',
        'benchmark/bulk_writes.dart',
        '10000',
        '10000',
      ]);
      return;
    case 'publish-check':
      await _run('dart', ['pub', 'publish', '--dry-run']);
      return;
    case 'release-check':
      await _runSuite(['docs', 'benchmark', 'publish-check']);
      return;
    case 'tag':
      if (arguments.length != 2) {
        _fail('Usage: dart run tool/ci.dart tag v<pubspec-version>');
      }
      await _validateTag(arguments[1]);
      return;
    case 'all':
      await _runSuite(['policy', 'core', 'release-check']);
      return;
    default:
      _fail(
        'Unknown suite "$suite". Expected policy, format, analyze, test, '
        'core, docs, benchmark, publish-check, release-check, tag, or all.',
      );
  }
}

Future<void> _runSuite(List<String> suites) async {
  for (final suite in suites) {
    stdout.writeln('\n==> $suite');
    await _dispatch([suite]);
  }
}

Future<void> _policy() async {
  const requiredFiles = [
    'AGENTS.md',
    'CONTRIBUTING.md',
    'SECURITY.md',
    '.github/CODEOWNERS',
    '.github/labels.yml',
    '.github/pull_request_template.md',
    '.github/ISSUE_TEMPLATE/feature.yml',
    '.github/ISSUE_TEMPLATE/bug.yml',
    '.github/ISSUE_TEMPLATE/architecture_decision.yml',
    '.github/workflows/ci-gate.yml',
    'doc/DEVELOPMENT_WORKFLOW.md',
    'doc/decisions/0000-template.md',
  ];

  var failed = false;
  for (final path in requiredFiles) {
    if (!File(path).existsSync()) {
      stderr.writeln('Missing required governance file: $path');
      failed = true;
    }
  }

  final headRef = Platform.environment['HEAD_REF'];
  final branch = headRef != null && headRef.isNotEmpty
      ? headRef
      : await _capture('git', ['branch', '--show-current']);
  if (branch.isNotEmpty && branch != 'main') {
    if (!RegExp(_branchPattern).hasMatch(branch)) {
      stderr.writeln(
        'Branch "$branch" must match '
        '<type>/<issue>-<short-kebab-description>.',
      );
      failed = true;
    }
  }

  final workflowDirectory = Directory('.github/workflows');
  if (workflowDirectory.existsSync()) {
    final actionPattern = RegExp(r'^\s*uses:\s*([^\s#]+)', multiLine: true);
    final immutableAction = RegExp(r'^[^/\s]+/[^@\s]+@[0-9a-f]{40}$');
    for (final entity in workflowDirectory.listSync()) {
      if (entity is! File ||
          !(entity.path.endsWith('.yml') || entity.path.endsWith('.yaml'))) {
        continue;
      }
      final contents = entity.readAsStringSync();
      for (final match in actionPattern.allMatches(contents)) {
        final action = match.group(1)!;
        if (action.startsWith('./') || immutableAction.hasMatch(action)) {
          continue;
        }
        stderr.writeln(
          'Third-party action must use a full commit SHA in '
          '${entity.path}: $action',
        );
        failed = true;
      }
    }
  }

  if (failed) exitCode = 1;
  if (failed) throw const _CheckFailed();
  stdout.writeln('Repository policy OK');
}

Future<void> _validateTag(String tag) async {
  final tagMatch = RegExp(
    r'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    r'(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$',
  ).firstMatch(tag);
  if (tagMatch == null) _fail('Release tag "$tag" is not v<semver>.');

  final pubspec = File('pubspec.yaml').readAsStringSync();
  final versionMatch = RegExp(
    r'^version:\s*(\S+)\s*$',
    multiLine: true,
  ).firstMatch(pubspec);
  if (versionMatch == null) _fail('pubspec.yaml has no version field.');
  final version = versionMatch.group(1)!;
  if (tag.substring(1) != version) {
    _fail('Tag $tag does not match pubspec version $version.');
  }

  final changelog = File('CHANGELOG.md').readAsStringSync();
  final escapedVersion = RegExp.escape(version);
  if (!RegExp(
    '^## \\[?$escapedVersion\\]?',
    multiLine: true,
  ).hasMatch(changelog)) {
    _fail('CHANGELOG.md has no level-two entry for $version.');
  }
  stdout.writeln('Release tag $tag matches pubspec.yaml and CHANGELOG.md');
}

Future<void> _run(String executable, List<String> arguments) async {
  stdout.writeln(r'$ ' + [executable, ...arguments].join(' '));
  final process = await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
  );
  final result = await process.exitCode;
  if (result != 0) throw _CheckFailed(result);
}

Future<String> _capture(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    throw _CheckFailed(result.exitCode);
  }
  return (result.stdout as String).trim();
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}

final class _CheckFailed implements Exception {
  const _CheckFailed([this.exitCode = 1]);

  final int exitCode;
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
