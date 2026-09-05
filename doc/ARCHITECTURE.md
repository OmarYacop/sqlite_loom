# Internal architecture

SQLite Loom exposes three stable entry points: `sqlite_loom.dart` for runtime
code, `dev.dart` for developer tooling, and `testing.dart` for test harnesses. Files below `lib/src` are private and
organized by responsibility:

- `model/`: typed columns, tables, rows, values, codecs, and expressions.
- `query/`: query construction, joins, and reactive change descriptions.
- `database/`: connection lifecycle, execution, and SQLite capabilities.
- `migration/`: migration execution and schema construction.
- `cli/`: application-owned database commands.
- `dev/config/`: flavor and environment resolution.
- `dev/project/`: project discovery, scaffolding, locks, and CLI delegation.
- `internal/`: shared SQL and executor implementation details that are not
  domain concepts.

Dependencies should point from higher-level features toward lower-level model
and internal primitives. Application code must not import `src/` paths; keeping
all public exports in the three package entry points allows internal files to move
without consumer changes.

When adding a feature, place it with the behavior it owns instead of creating a
generic helpers folder. Add public API deliberately through the appropriate
entry point and cover compatibility in `public_api_compatibility_test.dart`.

`DbSession` is the shared query interface for root and transaction handles.
Transaction sessions reject watches; lifecycle and commit ownership remain explicit.
Query SQL pagination/order and projected value equality are shared internal primitives.
Live query execution has its own library. Query projections/grouping, database
lifecycle/execution and CLI command families use private library parts to keep
responsibilities focused while preserving public imports and private invariants.
See ADR 0001 and `CONSUMER_WORKFLOWS.md` for the rationale and consumer examples.
