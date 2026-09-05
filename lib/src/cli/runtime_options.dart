part of 'runtime_cli.dart';

int _readSteps(List<String> args) {
  return _readPositiveInt(args, '--steps', required: false) ??
      _readPositiveInt(args, '--batches', required: false) ??
      1;
}

int? _readPositiveInt(
  List<String> args,
  String option, {
  required bool required,
}) {
  final value = _readString(args, option, required: required);
  if (value == null) return null;
  final parsed = int.tryParse(value);
  if (parsed == null || parsed < 1) {
    throw ArgumentError.value(value, option, 'Must be a positive integer');
  }
  return parsed;
}

String? _readString(
  List<String> args,
  String option, {
  required bool required,
}) {
  final index = args.indexOf(option);
  if (index == -1) {
    if (required) throw ArgumentError('$option requires a value');
    return null;
  }
  if (index + 1 >= args.length || args[index + 1].startsWith('--')) {
    throw ArgumentError('$option requires a value');
  }
  return args[index + 1];
}

String _readPositional(List<String> args, String command) {
  final values = _readPositionals(args);
  if (values.isNotEmpty) return values.first;
  throw ArgumentError('$command requires a table or view name');
}

List<String> _readPositionals(List<String> args) {
  final values = <String>[];
  for (var index = 1; index < args.length; index++) {
    final value = args[index];
    if (value.startsWith('--')) {
      if (_optionsWithValues.contains(value)) index++;
      continue;
    }
    values.add(value);
  }
  return values;
}

const _optionsWithValues = {
  '--to',
  '--steps',
  '--batches',
  '--output',
  '--input',
  '--limit',
  '--offset',
  '--order',
  '--sql',
  '--file',
  '--format',
  '--values-json',
  '--set-json',
  '--where-json',
  '--value',
  '--set',
  '--where',
};

int _readBoundedInt(
  List<String> args,
  String option, {
  required int fallback,
  required int minimum,
  required int maximum,
}) {
  final value = _readString(args, option, required: false);
  if (value == null) return fallback;
  final parsed = int.tryParse(value);
  if (parsed == null || parsed < minimum || parsed > maximum) {
    throw ArgumentError.value(
      value,
      option,
      'Must be between $minimum and $maximum',
    );
  }
  return parsed;
}

Future<String> _readSql(List<String> args) async {
  final inline = _readString(args, '--sql', required: false);
  final path = _readString(args, '--file', required: false);
  if (inline != null && path != null) {
    throw ArgumentError('Pass either --sql or --file, not both');
  }
  if (inline != null) return inline;
  if (path != null) return File(path).readAsString();
  throw ArgumentError('Pass SQL using --sql or --file');
}

Map<String, Object?>? _readJsonMap(
  List<String> args,
  String option, {
  required bool required,
}) {
  final value = _readString(args, option, required: required);
  if (value == null) return null;
  final decoded = jsonDecode(value);
  if (decoded is! Map<String, Object?>) {
    throw FormatException('$option must contain a JSON object.');
  }
  return Map<String, Object?>.unmodifiable(decoded);
}

Map<String, Object?>? _readValueMap(
  List<String> args, {
  required String jsonOption,
  required String assignmentOption,
  required bool required,
}) {
  final jsonValues = _readJsonMap(args, jsonOption, required: false);
  final assignments = _readAssignments(args, assignmentOption);
  if (jsonValues != null && assignments.isNotEmpty) {
    throw ArgumentError(
      'Pass either $jsonOption or repeated $assignmentOption values, not both.',
    );
  }
  final result = jsonValues ?? (assignments.isEmpty ? null : assignments);
  if (required && result == null) {
    throw ArgumentError(
      '$jsonOption or at least one $assignmentOption is required.',
    );
  }
  return result;
}

Map<String, Object?> _readAssignments(List<String> args, String option) {
  final values = <String, Object?>{};
  for (var index = 0; index < args.length; index++) {
    if (args[index] != option) continue;
    if (index + 1 >= args.length || args[index + 1].startsWith('--')) {
      throw ArgumentError('$option requires column=value');
    }
    final assignment = args[++index];
    final separator = assignment.indexOf('=');
    if (separator < 1) {
      throw ArgumentError.value(assignment, option, 'Must use column=value');
    }
    final column = assignment.substring(0, separator);
    if (values.containsKey(column)) {
      throw ArgumentError.value(column, option, 'Column is repeated');
    }
    final rawValue = assignment.substring(separator + 1);
    Object? value;
    try {
      value = jsonDecode(rawValue);
    } on FormatException {
      value = rawValue;
    }
    values[column] = value;
  }
  return values;
}

Map<String, Object?> _readMutationScope(List<String> args) {
  final all = args.contains('--all');
  final where = _readValueMap(
    args,
    jsonOption: '--where-json',
    assignmentOption: '--where',
    required: false,
  );
  if (all && where != null) {
    throw ArgumentError('Pass either --where-json or --all, not both.');
  }
  if (!all && (where == null || where.isEmpty)) {
    throw ArgumentError(
      'A non-empty --where-json object is required, or pass --all explicitly.',
    );
  }
  return where ?? const {};
}
