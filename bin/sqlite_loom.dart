import 'dart:io';

import 'package:sqlite_loom/dev.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runSqliteLoomProjectCli(arguments);
}
