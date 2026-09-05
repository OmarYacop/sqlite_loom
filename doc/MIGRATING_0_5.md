# Migrating to 0.5

This release preserves models, column codecs, schema, migration history and
connection ownership. No database migration is required. Update package constraints
to `^0.5.0` after checking these query behavior changes.

## Bounded mutations

`where(...).limit(1).delete()` previously deleted every matching row. All update
and delete variants now reject `orderBy`, `limit`, and `offset`, including offset
zero. For a bounded write, select keys in a transaction and update a new query:

```dart
await db.transaction((tx) async {
  final users = tx.table(const UsersTable());
  final ids = await users.orderBy(UsersTable.id.ascending())
      .limit(10).pluck(UsersTable.id).get();
  await users.where(UsersTable.id.inValues(ids)).delete();
});
```

Empty key sets remain safe. Use an explicit batch strategy for very large key sets.
`count`, `exists`, and aggregates still count predicate matches, independently of
pagination. Inserts/upserts do not consume read filters or pagination.

## Pagination

`pages` and `keysetPages` now honor the total source limit and initial offset.
`keysetPages` rejects a preexisting sort that differs from its cursor order.
For a non-unique timestamp, use a unique tie-breaker:

```dart
final created = DbCursorColumn(EventsTable.createdAt, descending: true);
final id = DbCursorColumn(EventsTable.id, descending: true);
final pages = events.keysetPagesBy([created, id], size: 100);
final older = await events.afterCursor([
  created.at(last.createdAt), id.at(last.id),
]).limit(100).get();
```

Cursor columns must be non-nullable, use the declared default SQL ordering, and
jointly distinguish every row. Custom collation/null ordering is not supported
by this cursor API. Page streams do not promise a snapshot across concurrent
writes; use a transaction when snapshot consistency is required.

## Shared application extensions

Change `extension AppTables on SqliteLoom` to `extension AppTables on DbSession`
to use the same getters in transaction and savepoint callbacks. Relationship
loading and joins accept either context. Creating watches in transactions still
throws; create live queries on the root handle after commit.

## Typed writes and batches

Prefer `DbValues.fromAssignments([UsersTable.name.set('Ada')])`; the old map
constructor still works. Typed assignments reject wrong value types during
analysis and reject duplicate columns at construction.

With `batchSize`, bulk calls now consume iterables one chunk at a time. Earlier
chunks remain committed if a later chunk or iterator fails outside a transaction.
Wrap the whole operation in `db.transaction` for all-or-nothing persistence.
Omitting batchSize preserves a single atomic batch and materializes all input.
