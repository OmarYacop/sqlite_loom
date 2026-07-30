import 'column.dart';
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

/// Maps between a domain [Row] and one SQLite table with primary key [Key].
abstract class DbTable<Row, Key> {
  /// Creates a table mapping.
  const DbTable();

  /// The SQL table name.
  String get tableName;

  /// The column that uniquely identifies a row.
  DbColumn<Key> get primaryKey;

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
