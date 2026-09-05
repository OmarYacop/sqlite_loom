part of 'database.dart';

/// Application initialization helpers for a migration project.
extension SqliteLoomProjectInitialization on SqliteLoomProject {
  /// Configures [database], applies pending migrations, and returns its Loom
  /// wrapper ready for repositories and queries.
  Future<SqliteLoom> initialize(
    Database database, {
    bool foreignKeys = true,
    bool? writeAheadLogging,
    Duration? busyTimeout,
    DbSynchronous? synchronous,
    DbObserver? observer,
    DbObserverErrorHandler? onObserverError,
    Duration? slowQueryThreshold,
    Map<String, String> observerContext = const {},
  }) async {
    await configureSqliteLoomConnection(
      database,
      foreignKeys: foreignKeys,
      writeAheadLogging: writeAheadLogging,
      busyTimeout: busyTimeout,
      synchronous: synchronous,
    );
    await migrate(database);
    return SqliteLoom(
      database,
      observer: observer,
      onObserverError: onObserverError,
      slowQueryThreshold: slowQueryThreshold,
      observerContext: observerContext,
    );
  }

  /// Creates a package-owned database lifecycle from application settings.
  SqliteLoomDatabase database({
    DatabaseFactory? factory,
    DbFactoryResolver? factoryResolver,
    String? name,
    String? path,
    DbPathResolver? pathResolver,
    DbConnectionOptions connection = const DbConnectionOptions(),
    DbObserver? observer,
    DbObserverErrorHandler? onObserverError,
    Duration? slowQueryThreshold,
    Map<String, String> observerContext = const {},
  }) => SqliteLoomDatabase._(
    project: this,
    factory: factory,
    factoryResolver: factoryResolver,
    name: name,
    path: path,
    pathResolver: pathResolver,
    connection: connection,
    observer: observer,
    onObserverError: onObserverError,
    slowQueryThreshold: slowQueryThreshold,
    observerContext: observerContext,
  );
}

/// Owns opening, configuring, migrating, accessing, and closing one database.
final class SqliteLoomDatabase {
  SqliteLoomDatabase._({
    required SqliteLoomProject project,
    required DatabaseFactory? factory,
    required DbFactoryResolver? factoryResolver,
    required String? name,
    required String? path,
    required DbPathResolver? pathResolver,
    required DbConnectionOptions connection,
    required DbObserver? observer,
    required DbObserverErrorHandler? onObserverError,
    required Duration? slowQueryThreshold,
    required Map<String, String> observerContext,
  }) : _project = project,
       _factory = factory,
       _factoryResolver = factoryResolver,
       _name = name,
       _path = path,
       _pathResolver = pathResolver,
       _connection = connection,
       _observer = observer,
       _onObserverError = onObserverError,
       _slowQueryThreshold = slowQueryThreshold,
       _observerContext = Map.unmodifiable(observerContext) {
    if ((factory == null) == (factoryResolver == null)) {
      throw ArgumentError('Provide exactly one of factory or factoryResolver');
    }
    final choices = [name, path, pathResolver].where((value) => value != null);
    if (choices.length != 1) {
      throw ArgumentError('Provide exactly one of name, path, or pathResolver');
    }
    if (name != null &&
        (name.trim().isEmpty ||
            p.basename(name) != name ||
            p.isAbsolute(name))) {
      throw ArgumentError.value(
        name,
        'name',
        'Must be a non-empty file name without path separators',
      );
    }
    if (path != null && path.trim().isEmpty) {
      throw ArgumentError.value(path, 'path', 'Cannot be empty');
    }
  }

  final SqliteLoomProject _project;
  final DatabaseFactory? _factory;
  final DbFactoryResolver? _factoryResolver;
  final String? _name;
  final String? _path;
  final DbPathResolver? _pathResolver;
  final DbConnectionOptions _connection;
  final DbObserver? _observer;
  final DbObserverErrorHandler? _onObserverError;
  final Duration? _slowQueryThreshold;
  final Map<String, String> _observerContext;

  SqliteLoom? _loom;
  Future<SqliteLoom>? _opening;
  Future<void>? _closing;
  bool _closed = false;

  /// Opens and initializes the database once, sharing concurrent callers.
  Future<SqliteLoom> get ready => open();

  /// Opens normally, or initializes a caller-supplied database for tests.
  Future<SqliteLoom> open({Database? database}) {
    final current = _loom;
    if (current != null) {
      if (database != null && !identical(database, current.database)) {
        throw StateError('SQLite Loom database is already open');
      }
      return Future.value(current);
    }
    if (_closed) {
      throw StateError('SQLite Loom database has been closed');
    }
    final pending = _opening;
    if (pending != null) {
      if (database != null) {
        throw StateError('SQLite Loom database is already opening');
      }
      return pending;
    }
    final opening = _open(database);
    _opening = opening;
    return opening;
  }

  /// Ready typed database access.
  SqliteLoom get loom =>
      _loom ?? (throw StateError('Await appDatabase.ready before access'));

  /// Ready low-level sqflite access for advanced integrations.
  Database get raw => loom.database;

  /// Whether initialization completed and the database is open.
  bool get isOpen => _loom != null && !_closed;

  Future<SqliteLoom> _open(Database? supplied) async {
    Database? database = supplied;
    final ownsDatabase = supplied == null;
    try {
      if (database == null) {
        final factory = _factory ?? _factoryResolver!();
        database = await factory.openDatabase(await _resolvePath(factory));
      }
      final options = _connection;
      final loom = await _project.initialize(
        database,
        foreignKeys: options.foreignKeys,
        writeAheadLogging: options.writeAheadLogging,
        busyTimeout: options.busyTimeout,
        synchronous: options.synchronous,
        observer: _observer,
        onObserverError: _onObserverError,
        slowQueryThreshold: _slowQueryThreshold,
        observerContext: _observerContext,
      );
      _loom = loom;
      return loom;
    } catch (_) {
      if (ownsDatabase && database != null && database.isOpen) {
        await database.close();
      }
      rethrow;
    } finally {
      _opening = null;
    }
  }

  Future<String> _resolvePath(DatabaseFactory factory) async {
    final explicit = _path;
    if (explicit != null) return explicit;
    final resolver = _pathResolver;
    if (resolver != null) {
      final resolved = await resolver();
      if (resolved.trim().isEmpty) {
        throw StateError('Database path resolver returned an empty path');
      }
      return resolved;
    }
    return p.join(await factory.getDatabasesPath(), _name!);
  }

  /// Closes the lifecycle permanently. Repeated calls share one operation.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    final opening = _opening;
    if (opening != null) {
      try {
        await opening;
      } catch (_) {
        return;
      }
    }
    final loom = _loom;
    _loom = null;
    if (loom != null) await loom.close();
  }
}
