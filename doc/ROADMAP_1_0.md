# SQLite Loom 1.0 readiness

SQLite Loom will reach 1.0 only after its public API, storage semantics, and
supported runtime matrix have evidence-backed stability. A feature being
implemented is not by itself a stability guarantee.

## Compatibility contract

- The `0.4.x` public API is the candidate 1.0 surface. Breaking changes require
  a major pre-1.0 minor release, a changelog entry, and an updated executable
  compatibility fixture.
- Typed APIs bind values. APIs accepting SQL syntax use explicit trusted-SQL
  wrappers and must never receive end-user input.
- Version/build-dependent SQLite features are discoverable through
  `SqliteLoom.capabilities()` and guarded before execution.
- Mutations affecting every row require `allRows()`. Singular optimistic
  updates require an exact primary-key scope.

## Release gates

- Formatting, static analysis, documentation generation, and all unit,
  randomized, migration, failure-injection, and compatibility tests pass.
- CI passes on the minimum Dart SDK and stable Dart on Linux, macOS, and
  Windows.
- The mobile application migration fixture builds the complete production
  schema against the local package without analyzer errors.
- Bulk-write and typed-read throughput stay above the portable CI floors;
  meaningful baseline changes are reviewed with benchmark evidence.
- A repository-wide security scan has no unresolved critical or high findings,
  trusted SQL boundaries are documented, and the supported security branches
  are published in `SECURITY.md`.
- Released migration checksums are immutable, concurrent migration attempts are
  serialized, and rollback/failure behavior is covered by fixtures.

## Remaining before 1.0

- Accumulate real-world soak time across Android and iOS SQLite builds.
- Add device integration coverage for cancellation, process restart, database
  locking, disk-full behavior, corruption recovery, and backup restoration.
- Establish measured performance baselines per supported platform rather than
  relying only on the portable regression floor.
- Freeze the final support and deprecation policy after the `0.4.x` adoption
  window.

## Release discipline

Every release must update the changelog, executable API fixture, migration
fixtures, and capability documentation when their contracts change. No new raw
SQL string boundary, unchecked full-table mutation, or unguarded runtime feature
may be introduced during stabilization.
