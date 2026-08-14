# Foundation hardening audit

Audit date: 2026-08-01

This is the completion ledger for the `0.2.0` foundation pass. “Verified” means
the named repository artifact and an executable check exist; it does not imply
the additional soak/device work listed in the 1.0 roadmap is complete.

| Requirement | Status | Evidence |
| --- | --- | --- |
| Public API freeze and audit | Verified | `PUBLIC_API.md`, executable compatibility fixture, clean analyzer and dartdoc build |
| Typed multi-column selection | Verified | iterable `select`, typed `DbRow` projections, mobile consumer analysis |
| Mutation and semantic safety | Verified | explicit whole-table opt-in, key-scoped optimistic updates, native UPSERT, rollback tests |
| Concurrency and lifecycle | Verified | idempotent close, cancellation test, savepoints, transaction invalidation tests |
| Migration stability | Verified | immutable checksums, failure rollback, same- and cross-connection race tests, bounded `SQLITE_BUSY` retries |
| Instrumentation | Verified | success/failure/transaction/batch observations; observer failures are isolated and values excluded |
| Trusted SQL boundaries | Verified | explicit trusted wrappers, identifier validation, hostile-value and identifier fuzz tests |
| Security scan | Verified | complete 555-file inventory; seven findings found and fixed; sealed scan contract validates; no deferred findings |
| Security policy | Verified | `SECURITY.md` supports 0.2.x and requires private GitHub advisory reporting |
| Schema/capability validation | Verified | affinity, primary-key and nullability checks; cached runtime/version/JSON/FTS probes and guarded features |
| Property, fuzz and failure injection | Verified | seeded predicate oracle, identifier/value fuzzing, failed migration and failed batch tests |
| Cross-platform integration definition | Verified | six-cell Linux/macOS/Windows × minimum/stable Dart CI matrix |
| Migration fixtures | Verified | package fixtures and complete mobile production-schema migration test |
| Performance regression coverage | Verified | JSON write/read benchmark with 10,000 rows/sec CI floors |
| Mobile consumer | Verified | scoped Flutter analysis and production migration integration test pass against local package |
| Compatibility roadmap | Verified | `ROADMAP_1_0.md` release gates, remaining device/soak work, and release discipline |

## Latest executable evidence

- `dart analyze`: no issues.
- `dart test`: 81 tests passed.
- `dart doc`: zero warnings and zero errors.
- Bulk round trip: approximately 120,482 write rows/sec and 909,091 typed
  read rows/sec on the audit machine; both exceed the portable CI floors.
- Line coverage: 69.0%; high-risk additions have direct integration coverage,
  while increasing broad CLI/schema branch coverage remains ongoing 1.0 work.
- Mobile: scoped analysis reports no issues; the complete application migration
  fixture passes.
- `git diff --check`: clean.

The CI matrix is configured but can only be proven green after the branch is
run by GitHub Actions. Physical Android/iOS failure injection and long-running
soak evidence remain explicit pre-1.0 roadmap items, not hidden claims of this
foundation pass.
