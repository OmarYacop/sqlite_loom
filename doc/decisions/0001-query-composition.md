# ADR 0001: Consistent query composition and shared database sessions

- Status: Accepted
- Date: 2026-09-05
- Issue: https://github.com/OmarYacop/sqlite_loom/issues/7
- Authority: User instruction to implement the reviewed fixes and API improvements.

## Context

Consumer repositories repeat table access in root and transaction contexts, raw
flag encodings, and bulk loops. Query pagination silently changes meaning in
some compositions. Root ownership and transaction invalidation must remain intact.

## Options considered

1. Keep separate APIs and document ignored modifiers. This preserves accidental
behavior but leaves repositories duplicating adapters and permits oversized writes.
2. Share a small session interface, reject unsupported mutation modifiers, and
make cursor ordering explicit. This adds a public contract but makes read/write
composition predictable and allows application extensions to work in transactions.

## Decision

Choose option 2. `DbSession` exposes table queries, raw reads and raw watches;
transactions reject watches synchronously. Lifecycle, commit, and close remain
on their existing owners. Relations and joins consume the shared interface.
Mutation order/limit/offset are rejected, never silently ignored. Count and
exists continue to describe predicate matches independent of pagination.
Cursor pages honor the source limit and initial offset, require compatible
ordering and non-null cursor columns, and support lexicographic composite order.
The last cursor column must uniquely distinguish rows; this remains an explicit
caller responsibility, including for the existing single-column API.

Use generic column assignments for statically checked writes while retaining
DbValues(Map). Explicit batch sizes consume inputs incrementally, with each batch
atomic; use a transaction for all-batch atomicity. Existing unsized batches remain
one batch. Conservative invalidation is preferable when keys may change.

## Consequences

Tightened query behavior ships as 0.5.0 with migration guidance. Shared root and
transaction extensions reduce application boilerplate without implicit graph writes,
SQL generators, changed migration history, or changed database ownership.
Internal refactors preserve existing public exports. Device soak testing is a
release evidence requirement and cannot be substituted by host unit tests.

## Validation

Regression and composition tests cover cursor ties/order/limits, fail-fast writes,
transaction relation/join reads and watch rejection, typed assignments, chunk
consumption/rollback and key invalidation. Run core/release and consumer checks.

## Implementation

- [PR #8: query contracts and APIs](https://github.com/OmarYacop/sqlite_loom/pull/8)
- [PR #9: internal cleanup and consumer workflows](https://github.com/OmarYacop/sqlite_loom/pull/9)

The first layer targets main; the second targets the first layer.
