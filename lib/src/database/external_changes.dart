part of 'database.dart';

/// A lifecycle-owned monitor for writes committed by other connections.
final class DbExternalChangeMonitor {
  DbExternalChangeMonitor._(
    this._db,
    this.tables,
    this.interval,
    this._onError,
  );

  final SqliteLoom _db;
  final Set<DbTableId> tables;
  final Duration interval;
  final DbExternalChangeErrorHandler? _onError;
  Timer? _timer;
  int? _lastVersion;
  bool _checking = false;
  bool _closed = false;

  bool get isClosed => _closed;

  Future<void> _initialize() async {
    _lastVersion = await _readVersion();
    _timer = Timer.periodic(interval, (_) => unawaited(checkNow()));
  }

  /// Checks immediately instead of waiting for the next polling interval.
  Future<bool> checkNow() async {
    if (_closed || _checking) return false;
    _checking = true;
    try {
      final version = await _readVersion();
      final changed = _lastVersion != null && version != _lastVersion;
      _lastVersion = version;
      if (changed && !_closed) _db.invalidate(tables);
      return changed;
    } catch (error, stackTrace) {
      if (!_closed && _onError != null) {
        try {
          _onError(error, stackTrace);
        } catch (_) {
          // Diagnostics must not break or terminate the polling lifecycle.
        }
      }
      return false;
    } finally {
      _checking = false;
    }
  }

  Future<int> _readVersion() async {
    final rows = await _db.rawRead('PRAGMA data_version');
    final value = rows.single.values.single;
    if (value is! int) {
      throw StateError('PRAGMA data_version returned ${value.runtimeType}');
    }
    return value;
  }

  /// Stops polling. Calling this more than once is safe.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _timer = null;
    while (_checking) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}
