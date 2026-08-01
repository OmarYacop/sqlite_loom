import 'package:sqflite_common/sqlite_api.dart';

import 'capabilities.dart';
import 'internal/sql.dart';
import 'table.dart';

/// One runtime schema mismatch.
final class DbSchemaIssue {
  const DbSchemaIssue(this.table, this.message);
  final String table;
  final String message;
}

/// Result of comparing mapped tables with the live SQLite schema.
final class DbSchemaValidation {
  const DbSchemaValidation(this.issues);
  final List<DbSchemaIssue> issues;
  bool get isValid => issues.isEmpty;

  void throwIfInvalid() {
    if (isValid) return;
    throw StateError(
      issues.map((issue) => '${issue.table}: ${issue.message}').join('; '),
    );
  }
}

/// Marks trusted SQL that should be used as a schema default verbatim.
final class DbSqlLiteral {
  /// Creates a trusted literal from [sql].
  const DbSqlLiteral(this.sql);

  /// The trusted SQL expression.
  final String sql;
}

/// Helpers for common SQLite schema operations.
final class DbSchema {
  /// Creates helpers that execute against [database].
  const DbSchema(this.database);

  /// The underlying executor, often a transaction.
  final DatabaseExecutor database;

  /// Validates declared table columns against SQLite's live schema.
  Future<DbSchemaValidation> validate(
    Iterable<DbTable<Object?, Object?>> tables,
  ) async {
    final issues = <DbSchemaIssue>[];
    for (final table in tables) {
      final declaredNames = table.columns.map((column) => column.name).toList();
      final duplicateNames =
          declaredNames.toSet().length != declaredNames.length;
      if (duplicateNames) {
        issues.add(
          DbSchemaIssue(table.tableName, 'mapped columns contain duplicates'),
        );
      }
      final rows = await database.rawQuery(
        'PRAGMA table_info(${quoteIdentifier(table.tableName)})',
      );
      if (rows.isEmpty) {
        issues.add(DbSchemaIssue(table.tableName, 'table is missing'));
        continue;
      }
      final actual = {for (final row in rows) row['name']! as String: row};
      final primaryKeyRow = actual[table.primaryKey.name];
      if (primaryKeyRow != null && (primaryKeyRow['pk'] as num).toInt() == 0) {
        issues.add(
          DbSchemaIssue(
            table.tableName,
            'column ${table.primaryKey.name} is not a primary key',
          ),
        );
      }
      for (final column in table.columns) {
        final row = actual[column.name];
        if (row == null) {
          issues.add(
            DbSchemaIssue(table.tableName, 'column ${column.name} is missing'),
          );
          continue;
        }
        final expectedAffinity = column.affinity;
        final actualType = (row['type'] as String).toUpperCase();
        if (expectedAffinity != null &&
            !_hasAffinity(actualType, expectedAffinity)) {
          issues.add(
            DbSchemaIssue(
              table.tableName,
              'column ${column.name} expected $expectedAffinity, found $actualType',
            ),
          );
        }
        final isPrimaryKey = (row['pk'] as num).toInt() > 0;
        final isNotNull = (row['notnull'] as num).toInt() == 1;
        if (!column.acceptsNull && !isNotNull && !isPrimaryKey) {
          issues.add(
            DbSchemaIssue(
              table.tableName,
              'column ${column.name} permits NULL but its Dart type does not',
            ),
          );
        }
      }
    }
    return DbSchemaValidation(List.unmodifiable(issues));
  }

  /// Adds [column] to [tableName].
  Future<void> addColumn(String tableName, DbColumnDefinition column) {
    return database.execute(
      'ALTER TABLE ${quoteIdentifier(tableName)} ADD COLUMN ${column.toSql()}',
    );
  }

  /// Creates an index over [columns].
  Future<void> createIndex(
    String name,
    String tableName,
    List<String> columns, {
    bool ifNotExists = true,
    bool unique = false,
    DbSqlLiteral? where,
    Map<String, String> orders = const {},
    Map<String, String> collations = const {},
  }) {
    if (columns.isEmpty) {
      throw ArgumentError.value(
        columns,
        'columns',
        'Index columns cannot be empty',
      );
    }
    final uniqueSql = unique ? 'UNIQUE ' : '';
    final ifNotExistsSql = ifNotExists ? 'IF NOT EXISTS ' : '';
    final columnSql = columns
        .map((column) {
          final collation = collations[column];
          final order = orders[column];
          final collationSql = collation == null
              ? ''
              : ' COLLATE ${_indexCollation(collation)}';
          final orderSql = order == null ? '' : ' ${_indexOrder(order)}';
          return '${quoteIdentifier(column)}$collationSql$orderSql';
        })
        .join(', ');
    final whereSql = where == null ? '' : ' WHERE ${where.sql}';
    return database.execute(
      'CREATE ${uniqueSql}INDEX $ifNotExistsSql${quoteIdentifier(name)} '
      'ON ${quoteIdentifier(tableName)} ($columnSql)$whereSql',
    );
  }

  /// Creates a table described by [define].
  Future<void> createTable(
    String name,
    void Function(DbCreateTable table) define, {
    bool ifNotExists = false,
    bool strict = false,
    bool withoutRowId = false,
  }) async {
    if (strict) {
      await requireDbFeature(database, DbFeature.strictTables);
    }
    final table = DbCreateTable();
    define(table);
    if (table.columns.isEmpty) {
      throw StateError('Table $name must define at least one column');
    }
    final ifNotExistsSql = ifNotExists ? 'IF NOT EXISTS ' : '';
    final definitions = [
      ...table.columns.map((column) => column.toSql()),
      ...table.constraints,
    ].join(', ');
    final options = [if (withoutRowId) 'WITHOUT ROWID', if (strict) 'STRICT'];
    final optionSql = options.isEmpty ? '' : ' ${options.join(', ')}';
    await database.execute(
      'CREATE TABLE $ifNotExistsSql${quoteIdentifier(name)} '
      '($definitions)$optionSql',
    );
  }

  /// Drops the index named [name].
  Future<void> dropIndex(String name, {bool ifExists = true}) {
    final ifExistsSql = ifExists ? 'IF EXISTS ' : '';
    return database.execute('DROP INDEX $ifExistsSql${quoteIdentifier(name)}');
  }

  /// Drops the table named [name].
  Future<void> dropTable(String name, {bool ifExists = true}) {
    final ifExistsSql = ifExists ? 'IF EXISTS ' : '';
    return database.execute('DROP TABLE $ifExistsSql${quoteIdentifier(name)}');
  }

  /// Renames a table.
  Future<void> renameTable(String from, String to) {
    return database.execute(
      'ALTER TABLE ${quoteIdentifier(from)} RENAME TO ${quoteIdentifier(to)}',
    );
  }

  /// Renames a column using SQLite's native `ALTER TABLE` support.
  Future<void> renameColumn(String tableName, String from, String to) {
    return database.execute(
      'ALTER TABLE ${quoteIdentifier(tableName)} '
      'RENAME COLUMN ${quoteIdentifier(from)} TO ${quoteIdentifier(to)}',
    );
  }

  /// Drops a column using SQLite's native `ALTER TABLE` support.
  Future<void> dropColumn(String tableName, String column) async {
    await requireDbFeature(database, DbFeature.dropColumn);
    await database.execute(
      'ALTER TABLE ${quoteIdentifier(tableName)} '
      'DROP COLUMN ${quoteIdentifier(column)}',
    );
  }

  /// Creates a view from a trusted SELECT [query].
  Future<void> createView(
    String name,
    DbSqlLiteral query, {
    bool ifNotExists = true,
  }) {
    final guard = ifNotExists ? 'IF NOT EXISTS ' : '';
    return database.execute(
      'CREATE VIEW $guard${quoteIdentifier(name)} AS ${query.sql}',
    );
  }

  /// Creates an FTS5 virtual table over quoted [columns].
  Future<void> createFts5Table(
    String name,
    Iterable<String> columns, {
    String? contentTable,
    String? tokenizer,
    bool ifNotExists = true,
  }) async {
    final materialized = columns.toList(growable: false);
    if (materialized.isEmpty) {
      throw ArgumentError.value(columns, 'columns', 'Cannot be empty');
    }
    await requireDbFeature(database, DbFeature.fts5);
    final options = <String>[
      ...materialized.map(quoteIdentifier),
      if (contentTable != null)
        "content='${contentTable.replaceAll("'", "''")}'",
      if (tokenizer != null) "tokenize='${tokenizer.replaceAll("'", "''")}'",
    ];
    final guard = ifNotExists ? 'IF NOT EXISTS ' : '';
    await database.execute(
      'CREATE VIRTUAL TABLE $guard${quoteIdentifier(name)} '
      'USING fts5(${options.join(', ')})',
    );
  }

  /// Drops a view.
  Future<void> dropView(String name, {bool ifExists = true}) {
    final guard = ifExists ? 'IF EXISTS ' : '';
    return database.execute('DROP VIEW $guard${quoteIdentifier(name)}');
  }
}

String _indexOrder(String order) {
  final normalized = order.trim().toUpperCase();
  if (normalized != 'ASC' && normalized != 'DESC') {
    throw ArgumentError.value(
      order,
      'order',
      'Index order must be ASC or DESC',
    );
  }
  return normalized;
}

String _indexCollation(String collation) {
  final normalized = collation.trim().toUpperCase();
  const allowed = {'BINARY', 'NOCASE', 'RTRIM'};
  if (!allowed.contains(normalized)) {
    throw ArgumentError.value(
      collation,
      'collation',
      'Unsupported SQLite index collation',
    );
  }
  return normalized;
}

bool _hasAffinity(String declaredType, String affinity) {
  final type = declaredType.toUpperCase();
  return switch (affinity) {
    'INTEGER' => type.contains('INT'),
    'TEXT' =>
      type.contains('CHAR') || type.contains('CLOB') || type.contains('TEXT'),
    'BLOB' => type.isEmpty || type.contains('BLOB'),
    'REAL' =>
      type.contains('REAL') || type.contains('FLOA') || type.contains('DOUB'),
    'NUMERIC' => true,
    _ => type == affinity,
  };
}

/// Collects column and table constraints for [DbSchema.createTable].
final class DbCreateTable {
  final List<DbColumnDefinition> _columns = <DbColumnDefinition>[];
  final List<String> _constraints = <String>[];

  List<DbColumnDefinition> get columns => List.unmodifiable(_columns);

  List<String> get constraints => List.unmodifiable(_constraints);

  /// Adds a BLOB column.
  DbColumnDefinition blob(String name) => _add(name, 'BLOB');

  /// Adds an INTEGER-backed boolean column.
  DbColumnDefinition boolean(String name) => _add(name, 'INTEGER');

  /// Adds an INTEGER-backed date-time column.
  DbColumnDefinition dateTime(String name) => _add(name, 'INTEGER');

  /// Adds an integer column.
  DbColumnDefinition integer(String name) => _add(name, 'INTEGER');

  /// Adds a TEXT-backed JSON column.
  DbColumnDefinition json(String name) => _add(name, 'TEXT');

  /// Adds a real-number column.
  DbColumnDefinition real(String name) => _add(name, 'REAL');

  /// Adds a text column.
  DbColumnDefinition text(String name) => _add(name, 'TEXT');

  /// Adds a column with a trusted custom SQLite [type].
  DbColumnDefinition custom(String name, String type) {
    if (type.trim().isEmpty) {
      throw ArgumentError.value(type, 'type', 'Column type cannot be empty');
    }
    return _add(name, type);
  }

  /// Adds a trusted table-level CHECK expression.
  void check(String expression) {
    if (expression.trim().isEmpty) {
      throw ArgumentError.value(expression, 'expression', 'Cannot be empty');
    }
    _constraints.add('CHECK ($expression)');
  }

  /// Adds a composite foreign-key constraint.
  void foreignKey(
    List<String> columns, {
    required String referencesTable,
    required List<String> referencesColumns,
    String? onDelete,
    String? onUpdate,
  }) {
    if (columns.isEmpty || referencesColumns.isEmpty) {
      throw ArgumentError('Foreign key columns cannot be empty');
    }
    final sourceSql = columns.map(quoteIdentifier).join(', ');
    final targetSql = referencesColumns.map(quoteIdentifier).join(', ');
    _constraints.add(
      'FOREIGN KEY ($sourceSql) REFERENCES ${quoteIdentifier(referencesTable)} '
      '($targetSql)${_referenceActions(onDelete: onDelete, onUpdate: onUpdate)}',
    );
  }

  /// Adds a composite unique constraint.
  void unique(List<String> columns) {
    if (columns.isEmpty) {
      throw ArgumentError.value(
        columns,
        'columns',
        'Unique columns cannot be empty',
      );
    }
    _constraints.add('UNIQUE (${columns.map(quoteIdentifier).join(', ')})');
  }

  DbColumnDefinition _add(String name, String type) {
    final column = DbColumnDefinition._(name, type);
    _columns.add(column);
    return column;
  }
}

/// A fluent SQLite column definition used by [DbCreateTable].
final class DbColumnDefinition {
  /// Creates a column definition with a trusted SQLite [type].
  DbColumnDefinition._(this.name, this.type);

  /// Creates a column with a developer-controlled trusted SQLite [type].
  factory DbColumnDefinition.trusted(String name, String type) {
    if (type.trim().isEmpty) {
      throw ArgumentError.value(type, 'type', 'Column type cannot be empty');
    }
    return DbColumnDefinition._(name, type);
  }

  final String name;
  final String type;
  bool _nullable = true;
  bool _primaryKey = false;
  bool _autoIncrement = false;
  bool _unique = false;
  bool _hasDefault = false;
  Object? _defaultValue;
  String? _referencesTable;
  String? _referencesColumn;
  String? _onDelete;
  String? _onUpdate;

  /// Marks this integer primary-key column as auto-incrementing.
  DbColumnDefinition autoIncrement() {
    _autoIncrement = true;
    return this;
  }

  /// Sets the SQL default, encoding Dart values safely.
  ///
  /// Pass [DbSqlLiteral] only for trusted expressions such as
  /// `CURRENT_TIMESTAMP`.
  DbColumnDefinition defaultValue(Object? value) {
    _hasDefault = true;
    _defaultValue = value;
    return this;
  }

  /// Marks this column nullable.
  DbColumnDefinition nullable() {
    _nullable = true;
    return this;
  }

  /// Adds a `NOT NULL` constraint.
  DbColumnDefinition notNull() {
    _nullable = false;
    return this;
  }

  /// Marks this column as the primary key.
  DbColumnDefinition primaryKey({bool autoIncrement = false}) {
    _primaryKey = true;
    _autoIncrement = autoIncrement;
    return this;
  }

  /// Adds a single-column foreign-key reference.
  DbColumnDefinition references(
    String table,
    String column, {
    String? onDelete,
    String? onUpdate,
  }) {
    _referencesTable = table;
    _referencesColumn = column;
    _onDelete = onDelete;
    _onUpdate = onUpdate;
    return this;
  }

  /// Adds a uniqueness constraint.
  DbColumnDefinition unique() {
    _unique = true;
    return this;
  }

  /// Compiles this definition into SQL.
  String toSql() {
    final parts = <String>[
      quoteIdentifier(name),
      type,
      if (_primaryKey) 'PRIMARY KEY',
      if (_autoIncrement) 'AUTOINCREMENT',
      if (!_nullable && !_primaryKey) 'NOT NULL',
      if (_unique) 'UNIQUE',
      if (_hasDefault) 'DEFAULT ${_literal(_defaultValue)}',
      if (_referencesTable != null && _referencesColumn != null)
        'REFERENCES ${quoteIdentifier(_referencesTable!)} '
            '(${quoteIdentifier(_referencesColumn!)})'
            '${_referenceActions(onDelete: _onDelete, onUpdate: _onUpdate)}',
    ];
    return parts.join(' ');
  }
}

String _referenceActions({String? onDelete, String? onUpdate}) {
  final parts = <String>[
    if (onDelete != null) ' ON DELETE ${_referenceAction(onDelete)}',
    if (onUpdate != null) ' ON UPDATE ${_referenceAction(onUpdate)}',
  ];
  return parts.join();
}

String _referenceAction(String action) {
  final normalized = action.trim().toUpperCase();
  const allowed = {
    'CASCADE',
    'RESTRICT',
    'SET NULL',
    'SET DEFAULT',
    'NO ACTION',
  };
  if (!allowed.contains(normalized)) {
    throw ArgumentError.value(action, 'action', 'Invalid foreign key action');
  }
  return normalized;
}

String _literal(Object? value) {
  return switch (value) {
    null => 'NULL',
    DbSqlLiteral(:final sql) => sql,
    bool() => value ? '1' : '0',
    int() || double() => '$value',
    DateTime() => '${value.toUtc().millisecondsSinceEpoch}',
    String() => "'${value.replaceAll("'", "''")}'",
    _ => throw ArgumentError.value(value, 'value', 'Unsupported SQL literal'),
  };
}
