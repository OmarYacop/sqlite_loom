# SQLite Loom agent instructions

This file is the operational contract for AI coding agents. Human contributors should also read
[CONTRIBUTING.md](CONTRIBUTING.md).

## Read before changing code

1. [doc/AI_CONTEXT.md](doc/AI_CONTEXT.md) for fixed package behavior and API boundaries.
2. [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md) for component ownership and design rationale.
3. [doc/ROADMAP_1_0.md](doc/ROADMAP_1_0.md) for current compatibility and release direction.
4. [doc/DEVELOPMENT_WORKFLOW.md](doc/DEVELOPMENT_WORKFLOW.md) for issues, labels, branches, PRs,
   stacks, CI, and releases.
5. Any record under [doc/decisions/](doc/decisions/) that touches the proposed change.

If these documents conflict, stop and report the conflict. Do not silently pick one.

## Product and compatibility boundaries

- SQLite Loom remains generator-free and wraps `sqflite_common`; do not introduce generated model
  or schema code as an incidental implementation choice.
- Callers may own the underlying database. Preserve the database lifecycle and raw-SQL boundaries
  documented in `doc/AI_CONTEXT.md`.
- Treat exported libraries (`lib/sqlite_loom.dart`, `lib/dev.dart`, and `lib/testing.dart`) as public
  contracts. Update public API tests and documentation with intentional changes.
- Never weaken safe-write guards, transaction invalidation semantics, parameter binding, migration
  history rules, or identifier quoting without a tracked architecture decision.
- Check `sqlite_loom_suite` impact when changing database ownership, file behavior, migrations,
  invalidation, or cross-process assumptions.

## Scope and issue discipline

Material behavior, public API, compatibility, migration, performance, security, or architecture
work requires a GitHub issue with acceptance criteria. Small documentation and repository
maintenance changes may omit an issue.

Use the issue as an allow-list. Do not add adjacent features, speculative abstractions, or cleanup
that is not required to satisfy its acceptance criteria. Open an Architecture decision issue and
record an ADR for expensive-to-reverse choices or deviations from established constraints.

## Branches, commits, and PRs

Branch names use `<type>/<issue>-<short-kebab-description>`, such as `feat/42-batched-upserts` or
`fix/87-watch-after-rollback`. Without an issue, omit only the number, for example
`docs/stacked-pr-guide`.

Allowed types are `feat`, `fix`, `hotfix`, `refactor`, `perf`, `security`, `docs`, `test`, `ci`,
`build`, `chore`, and `release`. Never use an agent, tool, or username as the prefix. Commit
subjects use Conventional Commits and should remain small and independently buildable.

Fill every applicable section of `.github/pull_request_template.md`. Include exact commands and
results actually observed. Use `Part of #N` for incomplete layers and `Closes #N` only on the PR
that fully completes the issue.

## Stacked PRs

Use GitHub stacked PRs through `gh stack` when one outcome has two or more dependent layers that
are independently reviewable. Before operating on a stack, run `gh stack --help` and the relevant
subcommand help because the feature is in public preview.

- The bottom layer targets `main`; each layer above depends on the branch immediately below.
- Every layer for one outcome carries the same issue number and a distinct description.
- Keep all stack branches in this repository; GitHub does not support cross-fork stacks.
- Start with `gh stack init <bottom-branch>`, add layers with `gh stack add <branch>`, and create or
  update the draft PR chain with `gh stack submit --auto` (omit `--auto` when interactively editing
  titles and bodies).
- After changing a lower layer, use `gh stack rebase`, then `gh stack push` or `gh stack submit`.
  Use `gh stack sync` after remote changes or merges.
- Review and repair bottom-up. Do not work around a lower-layer defect in an upper layer.
- Never use an unconditional force-push. Stack tooling uses per-branch `--force-with-lease`.
- Do not mark a PR ready or merge it unless the user explicitly requests that action and applicable
  checks have passed.

The full manual fallback and merge behavior are in `doc/DEVELOPMENT_WORKFLOW.md`.

## Required verification

Use the repository-owned entry point so local and CI commands stay aligned:

```bash
./tool/ci core          # formatting, analysis, tests
./tool/ci release-check # docs, benchmark, package dry-run
./tool/ci all           # complete local gate
```

Add focused tests for behavior changes. Update `CHANGELOG.md` for user-visible changes. Before a
PR, inspect the complete diff and confirm it contains no secrets, credentials, local databases,
generated API docs, `.dart_tool`, or `build` artifacts.

## Dependencies and workflows

Document every new dependency in the PR: need, maintenance status, license, security/supply-chain
impact, and alternatives. Prefer Dart's standard library and existing dependencies.

GitHub Actions must use minimum permissions, explicit timeouts, and full immutable commit SHAs for
third-party actions. PR workflows must not receive publishing or deployment credentials.
