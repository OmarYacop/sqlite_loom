# Public API contract

This document freezes the candidate `0.4.x` API categories ahead of 1.0. The
compile-time fixture in `test/public_api_compatibility_test.dart` protects the
most compatibility-sensitive generic signatures; dartdoc generation audits the
complete exported surface.

## Stable typed surface

- `SqliteLoom`, `SqliteLoomTransaction`, `DbTable`, `DbColumn`, `DbRow`, and
  `DbValues`
- immutable `DbTableQuery`, `DbColumnSelection`, `DbRowSelection`, and joined
  projection builders
- typed predicates, ordering, aggregates, keyset pagination, returning writes,
  optimistic updates, batches, transactions, savepoints, and live queries
- typed grouped aggregates, full joined-selection operations, and explicit
  has-many, has-one, and belongs-to relationship descriptors with bind-safe
  batching and independently limited child pages per parent
- typed heterogeneous merged relationships with cross-table cursor ordering,
  deterministic tie-breaking, per-parent limits, and cursor pagination
- migrations, schema definitions, runtime schema validation, capability
  detection, testing harnesses, and the application-owned migration CLI
- explicit invalidation, external-connection monitoring, and structured
  observation metadata

Changing a public name, generic parameter, return type, required parameter, or
behavioral invariant in this surface is breaking. During pre-1.0 development it
requires a new minor release and migration guidance. After 1.0 it requires a
major release unless the change is source- and behavior-compatible.

## Explicit trust boundaries

The following APIs intentionally execute developer-authored SQL:

- `DbSqlLiteral`
- `DbPredicate.trusted`
- `DbOrdering.trusted`
- `DbColumnDefinition.trusted`
- `rawRead`, `rawWrite`, and their transaction/watch variants

SQL syntax cannot be parameter-bound. These APIs must receive static,
developer-controlled SQL; every data value must use the accompanying argument
list or a typed column predicate. Adding another raw SQL string boundary is an
API and security review event.

## Behavioral invariants

- Whole-table update/delete requires an explicit `allRows()` opt-in.
- Singular optimistic updates require exact primary-key scope.
- Transactions publish one committed change set and publish nothing on
  rollback.
- Observer failures never change database operation results.
- `close()` is awaitable and idempotent.
- When application code supplies a checksum, a differing stored non-null
  checksum is rejected. Unchecked migrations remain compatible with history
  created by checksum-enabled releases.
- Concurrent migrators re-check history inside the write transaction and retry
  bounded `SQLITE_BUSY` failures.
- Unsupported SQLite features fail before feature SQL is executed.
- Bound values are excluded from observations and diagnostic stringification.

## Review gate

Every intentional public API change must update the changelog, this contract,
the compatibility fixture, relevant consumer migrations, and the 1.0 roadmap.
