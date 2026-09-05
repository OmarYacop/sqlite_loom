import '../model/table.dart';
import '../query/query.dart';

/// Shared query surface for a root database and a transaction.
///
/// Define application table extensions on this type to reuse them in both
/// contexts. Lifecycle and transaction ownership stay with SqliteLoom.
abstract interface class DbSession {
  DbTableQuery<Row, Key> table<Row, Key>(DbTable<Row, Key> table);

  Future<List<Map<String, Object?>>> rawRead(
    String sql, {
    List<Object?> arguments = const [],
  });

  /// Watches an explicitly declared dependency set.
  /// Transaction sessions throw synchronously; reads still run in the transaction.
  Stream<List<Map<String, Object?>>> watchRaw(
    String sql, {
    List<Object?> arguments = const [],
    required Set<DbTableId> dependsOn,
  });
}
