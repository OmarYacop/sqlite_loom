import 'column.dart';
import 'expression.dart';
import 'row.dart';
import 'values.dart';

/// A stable table identity used by the reactive invalidation system.
final class DbTableId {
  /// Creates an identity for the SQL table [name].
  const DbTableId(this.name);

  /// The SQL table name.
  final String name;

  @override
  bool operator ==(Object other) {
    return other is DbTableId && other.name == name;
  }

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => name;
}

/// One typed component of a composite key.
abstract interface class AnyDbKeyPart {
  DbPredicate get predicate;
}

final class DbKeyPart<T> implements AnyDbKeyPart {
  const DbKeyPart(this.column, this.value);
  final DbColumn<T> column;
  final T value;

  @override
  DbPredicate get predicate => column.equals(value);
}

/// A non-empty collection of column values forming a composite key.
final class DbCompositeKey {
  DbCompositeKey(Iterable<AnyDbKeyPart> parts)
    : parts = List.unmodifiable(parts) {
    if (this.parts.isEmpty) {
      throw ArgumentError.value(parts, 'parts', 'Cannot be empty');
    }
  }

  final List<AnyDbKeyPart> parts;

  DbPredicate get predicate => parts
      .map((part) => part.predicate)
      .reduce((left, right) => left.and(right));
}

/// Optional live-schema expectations declared by a mapped table.
final class DbTableSchema {
  const DbTableSchema({
    this.foreignKeys = const [],
    this.indexes = const [],
    this.strict,
    this.withoutRowId,
  });

  final List<DbForeignKeyExpectation> foreignKeys;
  final List<DbIndexExpectation> indexes;

  /// Expected STRICT flag, or null when it should not be validated.
  final bool? strict;

  /// Expected WITHOUT ROWID flag, or null when it should not be validated.
  final bool? withoutRowId;
}

/// Expected foreign-key shape for runtime schema validation.
final class DbForeignKeyExpectation {
  const DbForeignKeyExpectation({
    required this.columns,
    required this.referencesTable,
    required this.referencesColumns,
    this.onDelete = 'NO ACTION',
    this.onUpdate = 'NO ACTION',
  });

  final List<String> columns;
  final String referencesTable;
  final List<String> referencesColumns;
  final String onDelete;
  final String onUpdate;
}

/// Expected index shape for runtime schema validation.
final class DbIndexExpectation {
  const DbIndexExpectation({
    required this.name,
    required this.columns,
    this.unique = false,
    this.partial = false,
  });

  final String name;
  final List<String> columns;
  final bool unique;
  final bool partial;
}

/// Maps between a domain [Row] and one SQLite table with primary key [Key].
abstract class DbTable<Row, Key> {
  /// Creates a table mapping.
  const DbTable();

  /// The SQL table name.
  String get tableName;

  /// The column that uniquely identifies a row.
  DbColumn<Key> get primaryKey;

  /// Columns declared for runtime schema validation.
  ///
  /// Override with every mapped column for complete validation.
  Iterable<AnyDbColumn> get columns => [primaryKey];

  /// Optional indexes, foreign keys, and table flags to validate at runtime.
  DbTableSchema get schema => const DbTableSchema();

  /// The identity used for change invalidation.
  DbTableId get tableId => DbTableId(tableName);

  /// Decodes a database [row] into a domain object.
  Row decode(DbRow row);

  /// Encodes [row] for insertion or replacement.
  DbValues encode(Row row);

  /// Reads the primary key from [row].
  Key keyOf(Row row);

  /// Compares rows when suppressing duplicate live-query emissions.
  bool equals(Row left, Row right) => left == right;
}
