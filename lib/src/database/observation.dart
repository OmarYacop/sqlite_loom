part of 'database.dart';

/// A completed database operation reported to [DbObserver].
final class DbObservation {
  const DbObservation({
    required this.operation,
    required this.duration,
    this.table,
    this.sql,
    this.resultCount,
    this.error,
    this.transactionId,
    this.sequence = 0,
    this.startedAt,
    this.isSlow = false,
    this.context = const {},
  });

  final String operation;
  final Duration duration;
  final String? table;
  final String? sql;
  final int? resultCount;

  /// Correlates a transaction summary, its statements and nested savepoints.
  /// Null for operations outside a transaction. IDs are local to one database.
  final int? transactionId;

  final int sequence;
  final DateTime? startedAt;
  final bool isSlow;
  final Map<String, String> context;

  /// The driver error, when the operation failed. Its text may contain literals.
  final Object? error;

  /// Whether the database operation completed successfully.
  bool get succeeded => error == null;

  /// Normalized SQL with inline literals removed for metric grouping.
  String? get sqlFingerprint => _fingerprintSql(sql);
}

/// Receives timing metadata. Bound values are deliberately never included.
typedef DbObserver = void Function(DbObservation observation);

/// Receives errors thrown by [DbObserver] callbacks.
typedef DbObserverErrorHandler =
    void Function(Object error, StackTrace stackTrace);

/// Receives failures encountered while polling for external database writes.
typedef DbExternalChangeErrorHandler =
    void Function(Object error, StackTrace stackTrace);

String? _fingerprintSql(String? sql) {
  if (sql == null) return null;
  return sql
      .replaceAll(RegExp("'(?:''|[^'])*'"), "'?'")
      .replaceAll(RegExp(r'\b\d+(?:\.\d+)?\b'), '?')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
