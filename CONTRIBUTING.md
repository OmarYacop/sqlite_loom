# Contributing to SQLite Loom

Issues and pull requests are welcome. Start with the
[development workflow](doc/DEVELOPMENT_WORKFLOW.md); AI coding agents must also read
[AGENTS.md](AGENTS.md).

Use a structured issue for material features, bugs, performance regressions, and architecture
decisions. Branches follow `<type>/<issue>-<short-kebab-description>` and commits use Conventional
Commits. Keep each PR to one independently reviewable argument; use GitHub stacked PRs for dependent
layers.

Set up and run the complete local gate with:

```bash
dart pub get
./tool/ci all
```

Add tests for behavior changes and update `CHANGELOG.md` for user-visible changes. Keep public APIs
documented, preserve the generator-free design, and avoid committing generated or build artifacts.

PR descriptions must include exact checks actually run, public API and compatibility impact,
dependency justification, issue closure status, and stack position when applicable.
