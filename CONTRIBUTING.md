# Contributing

Issues and pull requests are welcome.

Before opening a pull request:

```bash
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze
dart test
dart doc
dart pub publish --dry-run
```

Add tests for behavior changes and update `CHANGELOG.md` for user-visible
changes. Keep public APIs documented and avoid adding generated source files.
