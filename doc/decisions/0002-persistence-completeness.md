# ADR 0002: Complete merged pages and observable persistence

- Status: Accepted
- Date: 2026-09-05
- Issue: https://github.com/OmarYacop/sqlite_loom/issues/11
- Authority: User approval to proceed with the reviewed persistence priorities.

## Options considered

1. Keep scalar merged boundaries and document that cursor values must be unique
   across every source. This is small, but cannot page through timestamp ties.
2. Add an opaque continuation returned with each page, retaining the existing
   scalar bounds. This adds API surface while preserving current callers.

## Decision

Choose option 2. `loadPage` orders by cursor, source position (always ascending),
then source primary key. Its opaque token captures all three SQL values and is
bound to the descriptor instance, parent key and direction. Null cursor values
follow SQLite ordering. A one-row lookahead determines whether another page
exists. Tokens are process-local, not serialized server cursors. Descriptor
filters and source ordering must remain stable; transforms must not introduce
an offset. Separate pages are not a snapshot unless read inside one transaction.
This is distinct from ADR 0001's non-nullable table-query composite cursors.

Transaction diagnostics use one forwarding implementation for root and nested
sessions. Every statement and its transaction summary share a database-local
transaction ID. Successful statements in a failed transaction are not evidence
of a commit; the transaction summary records its outcome. Bound argument lists
are never included; caller-supplied SQL and driver errors may contain literals.

Record successful writes before application decoding. ID zero is valid. If
IGNORE returns zero for an explicit zero key, conservatively invalidate because
its result cannot distinguish a stored zero from an ignored insert. Preserve
transaction accumulation and discard changes on rollback.

Complete schema validation is opt-in, preserving intentional partial mappings.
Use `table_xinfo` for generated/hidden columns, falling back to `table_info` on
older SQLite builds. No generated model code or migration rewrites are needed.

## Consequences and validation

LMS can share session scopes, typed assignments, batched hydration and atomic
rows/cursor persistence. Host regressions cover ties, nulls, zero IDs, decoder
failure, savepoints, correlation and schema completeness. A temporary Flutter
host runs the native fixture without adding Flutter dependencies to the package.
Disk-backed consumer benchmarks report timings and enforce result correctness,
without a hardware-specific speed threshold. Native smoke tests do not replace
physical-device soak and release testing.
