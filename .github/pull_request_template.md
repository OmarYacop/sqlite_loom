<!-- Keep this PR to one independently reviewable argument. Use a stack for dependent layers. -->

## Summary

<!-- What does this change and why? -->

## Review argument

<!-- State the single behavior, contract, or structural claim this PR establishes. -->

## Issue and stack position

<!-- Use "Closes #N" only where the tracked outcome is fully complete. -->

- Issue: `Part of #N` / `Closes #N` / `No issue (explain)`
- Stack: `main` → `<bottom>` → `<this branch>` → `<top>`, or `Not stacked`
- This PR's base: `<base branch>`

## Scope

- In scope:
- Explicitly out of scope:

## Public API and compatibility

<!-- Cover source compatibility, runtime behavior, migrations, SQLite/backend support,
     sqlite_loom_suite/downstream consumers, and rollback. Write "No impact" where applicable. -->

## Dependencies introduced

<!-- For each dependency: why, license, maintenance status, supply-chain/security impact,
     and alternatives. Write "None" if there are none. -->

## Test evidence

<!-- Paste only commands actually run and concise results. -->

```text
$ ./tool/ci all
<result>
```

## Checklist

- [ ] Branch name follows `<type>/<issue>-<short-kebab-description>`
- [ ] Commits use Conventional Commits
- [ ] `./tool/ci all` passes, or omitted checks are explained above
- [ ] Behavior changes have tests
- [ ] Public/user-visible changes update docs and `CHANGELOG.md`
- [ ] Full diff reviewed; no secrets, credentials, or generated/build artifacts are included
- [ ] New dependencies are justified above
