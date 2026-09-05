# Native persistence validation

Run `flutter devices`, then `./tool/native-ci <device-id>` from this repository.
The script creates a temporary Flutter host app and uses this checkout through a
path dependency. Its location is printed for reruns or cleanup. It neither builds
nor modifies a branded consumer. The developer fixture uses Flutter's integration
and test SDKs and the existing sqflite backend; the Dart package adds no dependency.

The fixture covers a real database file, WAL configuration, row ID zero,
transaction chunking, savepoint and transaction rollback, correlated statements,
schema validation, merged pagination through ties, capability-gated RETURNING,
and close/reopen durability. It can run on iOS, Android or macOS devices supported
by Flutter. The host database uses a dedicated test filename and is removed after
the run.

`dart run benchmark/consumer_workflows.dart` measures 10,000 disk-backed cache rows
persisted with 20 atomic sync cursors, followed by composite pagination. It checks
row count and cursor correctness and reports statement counts and timings.
Timings depend on hardware and filesystem; compare repeated runs on the same host.

Record OS, backend, command and results with each review. Emulator/simulator smoke
coverage is not physical-device soak coverage. Before release, also test Android
and iOS hardware, app suspension/restart, prolonged contention, storage pressure
and real consumer workloads.
