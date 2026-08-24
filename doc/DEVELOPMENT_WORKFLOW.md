# Development workflow

SQLite Loom adapts the parts of the Egensolve Realtime Service (ERS) workflow that make changes
traceable and reproducible, while keeping the process proportional to a focused Dart package.
This document is the operational guide for humans and AI agents.

## Set up a clean checkout

Prerequisites:

- Git.
- Dart 3.12 or newer (the CI matrix checks 3.12.0 and current stable).
- GitHub CLI (`gh`) for issue, PR, label, and stack operations.
- The official `github/gh-stack` extension when using stacked PRs.

```bash
git clone https://github.com/OmarYacop/sqlite_loom.git
cd sqlite_loom
dart pub get
./tool/ci all
```

`./tool/ci` is the canonical local entry point. CI calls the same Dart implementation, so a local
command and its CI counterpart execute the same project checks.

| Command | Purpose |
|---|---|
| `./tool/ci policy` | Governance files, branch name, and immutable Action pins |
| `./tool/ci core` | Dart formatting, static analysis, and unit tests |
| `./tool/ci docs` | API documentation generation with link validation |
| `./tool/ci benchmark` | Standard bulk-write smoke benchmark |
| `./tool/ci publish-check` | `dart pub publish --dry-run` |
| `./tool/ci release-check` | Docs, benchmark, and publish validation |
| `./tool/ci all` | The complete local gate |

On Windows, use `dart run tool/ci.dart <suite>` when a POSIX shell is unavailable.

## Issues are outcome records

Open an issue for material features, bugs, compatibility changes, migration behavior, measured
performance work, security hardening, and architecture decisions. The issue defines the outcome
and acceptance criteria; it is not a checklist for every commit.

The forms are:

- **Feature** for a new capability or intentional behavior change.
- **Bug** for behavior that differs from the documented contract.
- **Performance regression** for a reproducible measured regression.
- **Architecture decision** for expensive-to-reverse decisions or established constraints that
  need to change.

Blank issues are disabled. Security vulnerabilities use the private process in `SECURITY.md`.

### Label taxonomy

Labels are orthogonal facets. Apply one type, one priority when triaged, and every relevant area.
Do not invent a near-duplicate label for a single issue.

- `type:*` says what kind of change it is: `bug`, `build`, `chore`, `ci`, `docs`, `feat`, `fix`,
  `hotfix`, `perf`, `refactor`, `release`, `security`, or `test`.
- `area:*` says which subsystem owns it: `core`, `queries`, `migrations`, `reactivity`, `cli`,
  `docs`, `ci`, `governance`, or `suite-integration`.
- `priority:p0` through `priority:p3` records urgency. P0 is reserved for security, data integrity,
  or a release blocker; P2 is the normal default after triage.
- `status:blocked`, `status:needs-decision`, and `status:needs-reproduction` record an actionable
  workflow state. Remove the status label when the condition ends.
- `breaking-change` flags source, behavior, or migration incompatibility and requires explicit
  release treatment.

`.github/labels.yml` is canonical. Preview or synchronize it with:

```bash
dart run tool/sync_labels.dart
dart run tool/sync_labels.dart --apply
```

Synchronization creates or updates managed labels but deliberately does not delete GitHub's useful
default collaboration labels.

## Architecture decisions

Use an ADR when a decision changes a public contract, package boundary, compatibility floor,
database ownership model, migration invariant, security boundary, or other choice that would be
costly to reverse.

1. Open an Architecture decision issue.
2. Copy `doc/decisions/0000-template.md` to the next four-digit number.
3. Compare at least two real options and record consequences.
4. Link the issue, ADR, and implementing PRs in both directions.
5. Do not implement a proposed ADR as if it were already accepted.

## Branch and commit conventions

Use `<type>/<issue>-<short-kebab-description>`:

```text
feat/42-batched-upserts
fix/87-watch-after-rollback
perf/103-keyset-benchmark
docs/stacked-pr-guide
```

The issue segment is optional only for small untracked maintenance. Allowed branch types match the
`type:*` taxonomy. Commit subjects use Conventional Commits (`feat:`, `fix:`, `docs:`, `ci:`, and
so on). A PR should make one reviewable argument even when it contains several commits.

Dependabot branches are the sole automation exception. Repository policy accepts its generated
`dependabot/pub/...` and `dependabot/github_actions/...` names only when GitHub identifies the
workflow actor as `dependabot[bot]`; human-authored branches still use the convention above.

## Pull requests

Open PRs as drafts until their own checks pass. The bottom PR normally targets `main`. Fill in the
repository PR template with:

- the single review argument;
- tracked issue and stack position;
- in-scope and explicitly excluded work;
- public API, migration, backend, suite, and rollback impact;
- dependency justification;
- exact command evidence actually observed.

Use `Part of #N` while an issue remains incomplete. Use `Closes #N` only in the final PR that makes
every acceptance criterion true. Review the entire diff before requesting review.

## GitHub stacked PRs

Stacked PRs are useful when one outcome has dependent layers that deserve separate review—for
example, `core contract → implementation → CLI exposure → documentation`. GitHub's implementation
is currently a public preview, so check `gh stack <command> --help` before relying on a flag.

Install or update the official extension if `gh stack --help` is unavailable:

```bash
gh extension install github/gh-stack
gh stack --help
```

All branches must live in the same repository; cross-fork stacks are not supported. For issue #42:

```bash
git switch main
git pull --ff-only
gh stack init feat/42-query-contract

# Implement, stage, and commit the bottom layer.
git add <paths>
git commit -m "feat: define query contract"

gh stack add feat/42-query-implementation
# Implement and commit the next layer, then repeat as needed.

gh stack view
gh stack submit --auto
```

`gh stack submit --auto` creates new PRs as drafts by default. Interactive `gh stack submit` lets
you edit every title and body; explicitly choose draft for new layers. The resulting chain is:

```text
main ← feat/42-query-contract ← feat/42-query-implementation ← feat/42-query-docs
```

The bottom PR targets `main`; every higher PR targets the branch immediately below. GitHub links the
PRs as one stack and evaluates stack merge requirements against the trunk. Keep the history linear.

When a lower layer changes:

```bash
gh stack bottom
# edit and commit the fix
gh stack rebase
gh stack submit
```

Use `gh stack sync` after remote updates or merges. Repair and review bottom-up. `gh stack push`
uses a lease for each branch; never replace it with an unconditional force-push. Merging an upper
stack layer also merges all unmerged layers beneath it, so verify the full order and checks before
merging. Stacked PRs are not managed by GitHub Desktop.

Manual fallback: create each branch from the tip of the previous branch, push each branch, and open
each PR with the branch below as its base. Put the full order in every PR body. GitHub can recognize
and link an existing linear PR chain from the web interface.

## CI and branch protection

`.github/workflows/ci-gate.yml` always runs for pull requests, pushes to `main`, and merge queue
candidates. Its final stable check context is **`gate`** from the **CI Gate** workflow. Configure
branch protection to require that exact context rather than an internal matrix job. The aggregate
fails when policy, Dart, package, or documentation validation fails and cannot become permanently
pending because of path filters.

Workflows use read-only repository permissions, explicit timeouts, concurrency cancellation, and
full commit SHA pins for third-party Actions. Pull-request workflows receive no publishing secret.

## Versions, tags, and publishing

Package release tags use `v<pubspec-version>`, for example `v0.4.1` or `v1.0.0-rc.1`. A release PR:

1. Updates `version` in `pubspec.yaml`.
2. Adds the matching level-two `CHANGELOG.md` entry.
3. Runs `./tool/ci all`.
4. Uses a `release/<issue>-v<major>-<minor>-<patch>` branch when tracked, or
   `release/v<major>-<minor>-<patch>` otherwise.
5. Is merged before an annotated tag is created from the exact `main` commit.

```bash
git switch main
git pull --ff-only
./tool/ci all
git tag -s v0.4.1 -m "sqlite_loom 0.4.1"  # use -a when signing is unavailable
git push origin v0.4.1
```

The Release Tag workflow verifies semantic tag syntax, exact `pubspec.yaml`/`CHANGELOG.md` agreement,
and the complete gate. It intentionally does not publish yet: publication remains explicit until
pub.dev is configured to trust this repository's GitHub OIDC identity and its protected `pub.dev`
environment. When that repository setting exists, add Dart's official reusable publishing workflow;
do not introduce a long-lived pub.dev token.

## Repository settings checklist

Committed files cannot configure every GitHub setting. A repository administrator should verify:

- default branch `main` is protected;
- pull requests and the `gate` check from the CI Gate workflow are required before merge;
- force pushes and branch deletion are blocked on `main`;
- stale approvals are dismissed after new changes when more than one reviewer is available;
- the merge queue is enabled if the account plan supports it;
- secret scanning and Dependabot alerts are enabled;
- tag protection or a protected `pub.dev` environment is configured before automated publishing;
- GitHub stacked PRs are enabled for the repository/account when the public preview requires it.

## Primary references

- [Creating stacked pull requests](https://docs.github.com/en/pull-requests/how-tos/create-pull-requests/creating-stacked-pull-requests)
- [Stacked pull request rules and requirements](https://docs.github.com/en/pull-requests/reference/stacked-pull-requests)
- [`github/gh-stack` command reference](https://github.com/github/gh-stack)
- [Automated publishing to pub.dev](https://dart.dev/tools/pub/automated-publishing)
