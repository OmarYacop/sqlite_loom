# Reducing application persistence boilerplate

The LMS consumer review covered database bootstrap, chat writes and history,
reminder caching, table declarations, and the production migration fixture.
Its repeating persistence patterns informed 0.5's shared sessions, typed
assignments and incremental batches. No consumer migration history is rewritten.

| Repeated application work | Package-supported simplification |
| --- | --- |
| Root getters plus `tx.table(const ...())` for the same tables | Define the getters once on `DbSession`; reuse them in transactions and savepoints. |
| Raw maps for boolean flags and nullable timestamps | `DbValues.fromAssignments([column.set(value)])` reuses codecs and checks value types. |
| Per-row upserts of downloaded chats and members | `upsertAll(iterable, batchSize: 400)` inside one transaction; write parents before children. |
| Persisting cached rows and then their server cursor in separate commits | One transaction commits both; the executable cache example tests rollback after an iterator fails beyond the first batch. |
| Fetching related children once per parent | Existing `loadAllBatched` groups reads; use `loadAllLimited` when the limit applies per parent. Both now work in transactions. |
| Repeated manual cursor predicates and sort tie handling | Declare `DbCursorColumn` components once; use `afterCursor` or `keysetPagesBy`. |
| Hand-escaped LIKE patterns | Existing `contains`, `startsWith`, and `endsWith` bind and escape text. |
| Rebuilding migration lists/checksums during app bootstrap | Consume the CLI-maintained `sqliteLoomProject` and await its lifecycle handle once. |

## Transactional synchronization

`example/transactional_cache.dart` is a runnable application-owned persistence
example, covered by `test/consumer_workflows_test.dart`:

```sh
dart run example/transactional_cache.dart
```

The example's `persistPage` writes incremental batches and the sync cursor in one
transaction. A later iterator failure rolls back already executed chunks and
publishes no change event. Successful writes publish one change set for both tables.
The same extension getters work on the root database and the transaction view.

In a chat repository, keep the domain-specific parent/child order explicit:

```dart
await db.transaction((tx) async {
  await tx.chats.upsertAll(chats, batchSize: 400);
  await tx.members.upsertAll(chats.expand((chat) => chat.members), batchSize: 400);
  await tx.messages.upsertAll(messages, batchSize: 400);
  await tx.receipts.upsertAll(receipts, batchSize: 400);
  await tx.syncState.upsert(nextState);
});
```

These getters are application extensions on `DbSession`. Choose insert-ignore,
upsert or replacement deliberately: replacing a row can trigger foreign-key
cascades. Bulk writes do not infer relationship ownership or cascade application
objects. Keep network requests outside the transaction.

## Work that remains application-owned

Receipt deduplication, reply hydration, server identity reconciliation, retry
backoff, cache retention, and account boundaries depend on application semantics.
Putting those rules in the persistence package would couple unrelated applications.
Within LMS, consolidate repeated receipt/member/reply assembly in a shared
application collaborator and reuse it for initial and older history pages.

LMS's typed table column lists are incomplete in some mappings. Declare every
mapped column to enable complete validation; a generator-free package cannot
inspect static Dart fields to discover them. The canonical examples now do this.
Legacy cache deletion also stays application-owned because the package cannot
know whether a database contains disposable cache or irreplaceable user data.

## Internal duplication removed

SQL LIMIT/OFFSET generation, supported collation/null ordering, and projected
value equality have one implementation each. Live query execution is independent
of table queries. Grouped queries and projections have focused library parts.
Database connection policy, lifecycle, external monitoring and observers/executors
are separated; CLI dispatch, options, output, workflows, source validation and
scaffolding templates are separated by responsibility. Library parts preserve
private collaboration without widening the public API or consumer import paths.

## Adoption and verification

See `MIGRATING_0_5.md` for intentional behavior changes and `FLUTTER_LIFECYCLE.md`
for bootstrap/shutdown. Update a consumer's constraint to `^0.5.0` when adopting
the release. Compatibility checks can use a local package override first.
The review used isolated consumer copies with the local Loom package override;
application working files and version constraints were not changed.

Host tests do not establish Android/iOS process-death, disk-full, corruption,
backup-restoration or long-running soak behavior. Those remain the explicitly
tracked release evidence in `ROADMAP_1_0.md`, rather than a reason to add a generic
recovery engine or claim device readiness from FFI tests.
