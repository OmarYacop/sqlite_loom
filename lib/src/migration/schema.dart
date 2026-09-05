import 'package:sqflite_common/sqlite_api.dart';

import '../database/capabilities.dart';
import '../internal/sql.dart';
import '../model/table.dart';

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
  ///
  /// Set [requireAllColumns] to report live columns omitted from the mapping.
  /// Partial mappings remain supported by default.
  Future<DbSchemaValidation> validate(
    Iterable<DbTable<Object?, Object?>> tables, {
    bool requireAllColumns = false,
  }) async {
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
      final extendedRows = await database.rawQuery(
        'PRAGMA table_xinfo(${quoteIdentifier(table.tableName)})',
      );
      // Unknown pragmas return no rows on older SQLite builds.
      final rows = extendedRows.isNotEmpty
          ? extendedRows
          : await database.rawQuery(
              'PRAGMA table_info(${quoteIdentifier(table.tableName)})',
            );
      if (rows.isEmpty) {
        issues.add(DbSchemaIssue(table.tableName, 'table is missing'));
        continue;
      }
      final actual = {for (final row in rows) row['name']! as String: row};
      if (requireAllColumns) {
        for (final name in actual.keys.where(
          (name) => !declaredNames.contains(name),
        )) {
          issues.add(
            DbSchemaIssue(table.tableName, 'column $name is not mapped'),
          );
        }
      }
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
      await _validateTableOptions(table, issues);
      await _validateForeignKeys(table, issues);
      await _validateIndexes(table, issues);
    }
    return DbSchemaValidation(List.unmodifiable(issues));
  }

  Future<void> _validateTableOptions(
    DbTable<Object?, Object?> table,
    List<DbSchemaIssue> issues,
  ) async {
    final expected = table.schema;
    if (expected.strict == null && expected.withoutRowId == null) return;
    final rows = await database.rawQuery('PRAGMA table_list');
    final row = rows
        .cast<Map<String, Object?>>()
        .where((candidate) => candidate['name'] == table.tableName)
        .firstOrNull;
    if (row == null) return;
    final strict = (row['strict'] as num?)?.toInt() == 1;
    final withoutRowId = (row['wr'] as num?)?.toInt() == 1;
    if (expected.strict != null && expected.strict != strict) {
      issues.add(
        DbSchemaIssue(
          table.tableName,
          'expected strict=${expected.strict}, found strict=$strict',
        ),
      );
    }
    if (expected.withoutRowId != null &&
        expected.withoutRowId != withoutRowId) {
      issues.add(
        DbSchemaIssue(
          table.tableName,
          'expected withoutRowId=${expected.withoutRowId}, '
          'found withoutRowId=$withoutRowId',
        ),
      );
    }
  }

  Future<void> _validateForeignKeys(
    DbTable<Object?, Object?> table,
    List<DbSchemaIssue> issues,
  ) async {
    if (table.schema.foreignKeys.isEmpty) return;
    final rows = await database.rawQuery(
      'PRAGMA foreign_key_list(${quoteIdentifier(table.tableName)})',
    );
    final grouped = <int, List<Map<String, Object?>>>{};
    for (final row in rows) {
      final id = (row['id']! as num).toInt();
      grouped.putIfAbsent(id, () => []).add(row);
    }
    for (final expected in table.schema.foreignKeys) {
      final found = grouped.values.any((parts) {
        parts.sort(
          (left, right) =>
              (left['seq']! as num).compareTo(right['seq']! as num),
        );
        return parts.first['table'] == expected.referencesTable &&
            parts.map((part) => part['from']).toList().toString() ==
                expected.columns.toString() &&
            parts.map((part) => part['to']).toList().toString() ==
                expected.referencesColumns.toString() &&
            _normalizedSqlWord(parts.first['on_delete']) ==
                _normalizedSqlWord(expected.onDelete) &&
            _normalizedSqlWord(parts.first['on_update']) ==
                _normalizedSqlWord(expected.onUpdate);
      });
      if (!found) {
        issues.add(
          DbSchemaIssue(
            table.tableName,
            'foreign key ${expected.columns.join(', ')} -> '
            '${expected.referencesTable}(${expected.referencesColumns.join(', ')}) '
            'is missing or differs',
          ),
        );
      }
    }
  }

  Future<void> _validateIndexes(
    DbTable<Object?, Object?> table,
    List<DbSchemaIssue> issues,
  ) async {
    if (table.schema.indexes.isEmpty) return;
    final rows = await database.rawQuery(
      'PRAGMA index_list(${quoteIdentifier(table.tableName)})',
    );
    final indexes = {for (final row in rows) row['name']! as String: row};
    for (final expected in table.schema.indexes) {
      final row = indexes[expected.name];
      if (row == null) {
        issues.add(
          DbSchemaIssue(table.tableName, 'index ${expected.name} is missing'),
        );
        continue;
      }
      final unique = (row['unique']! as num).toInt() == 1;
      final partial = (row['partial'] as num?)?.toInt() == 1;
      final columns = (await database.rawQuery(
        'PRAGMA index_info(${quoteIdentifier(expected.name)})',
      )).toList();
      columns.sort(
        (left, right) =>
            (left['seqno']! as num).compareTo(right['seqno']! as num),
      );
      final names = columns.map((column) => column['name']).toList();
      if (unique != expected.unique ||
          partial != expected.partial ||
          names.toString() != expected.columns.toString()) {
        issues.add(
          DbSchemaIssue(
            table.tableName,
            'index ${expected.name} expected columns '
            '${expected.columns}, unique=${expected.unique}, '
            'partial=${expected.partial}; found columns $names, '
            'unique=$unique, partial=$partial',
          ),
        );
      }
    }
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

  /// Creates an index over trusted SQLite expressions.
  Future<void> createExpressionIndex(
    String name,
    String tableName,
    Iterable<DbSqlLiteral> expressions, {
    bool ifNotExists = true,
    bool unique = false,
    DbSqlLiteral? where,
  }) {
    final values = expressions.toList(growable: false);
    if (values.isEmpty || values.any((value) => value.sql.trim().isEmpty)) {
      throw ArgumentError.value(expressions, 'expressions', 'Cannot be empty');
    }
    final uniqueSql = unique ? 'UNIQUE ' : '';
    final guard = ifNotExists ? 'IF NOT EXISTS ' : '';
    final whereSql = where == null ? '' : ' WHERE ${where.sql}';
    return database.execute(
      'CREATE ${uniqueSql}INDEX $guard${quoteIdentifier(name)} ON '
      '${quoteIdentifier(tableName)} (${values.map((value) => value.sql).join(', ')})'
      '$whereSql',
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

  /// Creates a trigger from trusted trigger-body SQL.
  Future<void> createTrigger(
    String name,
    String tableName, {
    required DbTriggerTiming timing,
    required DbTriggerEvent event,
    required DbSqlLiteral body,
    DbSqlLiteral? when,
    bool ifNotExists = true,
  }) {
    if (body.sql.trim().isEmpty) {
      throw ArgumentError.value(body.sql, 'body', 'Cannot be empty');
    }
    final guard = ifNotExists ? 'IF NOT EXISTS ' : '';
    final whenSql = when == null ? '' : ' WHEN ${when.sql}';
    return database.execute(
      'CREATE TRIGGER $guard${quoteIdentifier(name)} ${timing.sql} '
      '${event.sql} ON ${quoteIdentifier(tableName)}$whenSql '
      'BEGIN ${body.sql}; END',
    );
  }

  /// Drops a trigger.
  Future<void> dropTrigger(String name, {bool ifExists = true}) {
    final guard = ifExists ? 'IF EXISTS ' : '';
    return database.execute('DROP TRIGGER $guard${quoteIdentifier(name)}');
  }
}

enum DbTriggerTiming {
  before('BEFORE'),
  after('AFTER'),
  insteadOf('INSTEAD OF');

  const DbTriggerTiming(this.sql);
  final String sql;
}

enum DbTriggerEvent {
  insert('INSERT'),
  update('UPDATE'),
  delete('DELETE');

  const DbTriggerEvent(this.sql);
  final String sql;
}

String _normalizedSqlWord(Object? value) =>
    value.toString().trim().toUpperCase();

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

  /// Adds a conventional auto-incrementing integer primary key.
  DbColumnDefinition id({String name = 'id', bool autoIncrement = true}) =>
      integer(name).primaryKey(autoIncrement: autoIncrement);

  /// Adds a conventional non-null integer foreign-key column.
  DbColumnDefinition foreignId(String name, {bool nullable = false}) {
    final column = integer(name);
    return nullable ? column.nullable() : column.notNull();
  }

  /// Adds a TEXT-backed JSON column.
  DbColumnDefinition json(String name) => _add(name, 'TEXT');

  /// Adds a real-number column.
  DbColumnDefinition real(String name) => _add(name, 'REAL');

  /// Adds a text column.
  DbColumnDefinition text(String name) => _add(name, 'TEXT');

  /// Adds conventional creation and update timestamp columns.
  void timestamps({
    String createdAt = 'created_at',
    String updatedAt = 'updated_at',
    bool nullable = false,
  }) {
    final created = dateTime(createdAt);
    final updated = dateTime(updatedAt);
    if (!nullable) {
      created.notNull();
      updated.notNull();
    }
  }

  /// Adds a nullable soft-deletion timestamp column.
  DbColumnDefinition softDeletes({String name = 'deleted_at'}) =>
      dateTime(name);

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
  String? _collation;
  DbSqlLiteral? _check;
  DbSqlLiteral? _generatedExpression;
  bool _generatedStored = false;

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

  /// Adds a supported SQLite collation to this column.
  DbColumnDefinition collate(String collation) {
    _collation = _indexCollation(collation);
    return this;
  }

  /// Adds a trusted column-level check expression.
  DbColumnDefinition check(DbSqlLiteral expression) {
    if (expression.sql.trim().isEmpty) {
      throw ArgumentError.value(
        expression.sql,
        'expression',
        'Cannot be empty',
      );
    }
    _check = expression;
    return this;
  }

  /// Defines a generated column using a trusted SQLite expression.
  DbColumnDefinition generatedAs(
    DbSqlLiteral expression, {
    bool stored = false,
  }) {
    if (expression.sql.trim().isEmpty) {
      throw ArgumentError.value(
        expression.sql,
        'expression',
        'Cannot be empty',
      );
    }
    _generatedExpression = expression;
    _generatedStored = stored;
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
    String table, {
    String column = 'id',
    String? onDelete,
    String? onUpdate,
  }) {
    _referencesTable = table;
    _referencesColumn = column;
    _onDelete = onDelete;
    _onUpdate = onUpdate;
    return this;
  }

  /// Uses cascading deletes for this foreign key.
  DbColumnDefinition cascadeOnDelete() {
    _onDelete = 'cascade';
    return this;
  }

  /// Uses cascading updates for this foreign key.
  DbColumnDefinition cascadeOnUpdate() {
    _onUpdate = 'cascade';
    return this;
  }

  /// Restricts deletion while referenced rows exist.
  DbColumnDefinition restrictOnDelete() {
    _onDelete = 'restrict';
    return this;
  }

  /// Sets the foreign key to null when its referenced row is deleted.
  DbColumnDefinition nullOnDelete() {
    _onDelete = 'set null';
    return this;
  }

  /// Adds a uniqueness constraint.
  DbColumnDefinition unique() {
    _unique = true;
    return this;
  }

  /// Compiles this definition into SQL.
  String toSql() {
    if (_generatedExpression != null && (_hasDefault || _primaryKey)) {
      throw StateError(
        'Generated column $name cannot have a default or primary key',
      );
    }
    final parts = <String>[
      quoteIdentifier(name),
      type,
      if (_primaryKey) 'PRIMARY KEY',
      if (_autoIncrement) 'AUTOINCREMENT',
      if (!_nullable && !_primaryKey) 'NOT NULL',
      if (_unique) 'UNIQUE',
      if (_collation != null) 'COLLATE $_collation',
      if (_check != null) 'CHECK (${_check!.sql})',
      if (_hasDefault) 'DEFAULT ${_literal(_defaultValue)}',
      if (_generatedExpression != null)
        'GENERATED ALWAYS AS (${_generatedExpression!.sql}) '
            '${_generatedStored ? 'STORED' : 'VIRTUAL'}',
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
