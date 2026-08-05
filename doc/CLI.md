# Developer CLI and migrations

SQLite Loom uses Laravel-style migration ergonomics without copying Laravel's
runtime model. Each migration is an ordinary Dart `DbMigration` containing
`up()` and `down()` methods. `DbSchema` is the type-safe schema helper used
inside those methods. The CLI scaffolds and discovers this code; it does not
replace it with a `MigrationPlan` DSL.

## Setup

From an application package:

```shell
dart pub add --dev sqflite_common_ffi
dart run sqlite_loom init
```

`init` creates:

- `sqlite_loom.yaml`, containing project-local paths;
- `tool/database.dart`, the application-owned database runner;
- `lib/database/migrations.dart`, the readable CLI-maintained migration index;
- `.sqlite_loom/migrations.lock.json`, the finalized source-integrity lock;
- an inline `flavors` map in `sqlite_loom.yaml` containing authoritative
  defaults;
- development database entries in `.gitignore`.

Selection precedence is `--flavor`/`--env`, `SQLITE_LOOM_FLAVOR`, `CLIENT`,
`APP_FLAVOR`, then `runner.default_flavor`. This lets client-flavored Flutter
apps reuse their existing `CLIENT` environment automatically. Add an inline
flavor with `dart run sqlite_loom make:flavor qa`. Generate an optional partial
override with `dart run sqlite_loom make:flavor qa --override`; its location is
controlled by `runner.flavor_overrides_directory`.

Inline YAML stores non-secret database and safety defaults. Override YAML is
merged over the selected inline flavor. `SQLITE_LOOM_DATABASE`,
`SQLITE_LOOM_ENVIRONMENT`, and `SQLITE_LOOM_ALLOW_DESTRUCTIVE` process variables
have final precedence, allowing CI and production secrets to remain outside the
repository. Application runtime configuration remains application-owned.

All configured managed paths must remain inside the project root. The CLI finds
`sqlite_loom.yaml` while walking upward, so commands also work from subfolders.

## Create and manage migrations

```shell
dart run sqlite_loom make:migration create_users --create users
dart run sqlite_loom make:migration add_email_to_users --table users
dart run sqlite_loom migrate:list
dart run sqlite_loom migrate:validate
dart run sqlite_loom migrate:sync
dart run sqlite_loom migrate:finalize
dart run sqlite_loom migrate:retire <version> --into <replacement-version>
dart run sqlite_loom migrate:unretire <version>
```

Migration filenames use sortable UTC timestamps. If two are created during the
same second, the second version is incremented deterministically. The class,
version, and name declared in source must match the filename.

When an unreleased migration was applied to development databases and is later
consolidated, merge its behavior into another finalized migration, remove the
old source, then run `migrate:retire`. The CLI preserves its name, checksum, and
replacement in the lock and refreshes the index. Existing databases recognize
the intentional history, while fresh databases never execute or record it.
Restore the exact source before using `migrate:unretire`.

`--create <table>` scaffolds `createTable`, `id`, `timestamps`, and a matching
rollback. `--table <table>` scaffolds an intentional alteration with an explicit
rollback placeholder. Both use the transaction-bound `DbMigrationContext`.

`make:migration` creates an editable draft and refreshes the readable index.
Ordinary database commands refresh that index after explicit invocation, so selecting a
specific migration file is never part of the workflow. Run `migrate:finalize`
before a release to lock every current draft. Finalized migrations are immutable:
create a new migration instead of changing one. The committed lock lets local
tools and CI refuse changed or missing finalized source history.

## Database commands

Every database command accepts `--flavor <name>` or its `--env <name>` alias.

```text
migrate [--to version] [--json]
migrate:status [--json]
migrate:rollback [--steps n] [--json]
migrate:redo [--steps n] [--json]
migrate:reset --force [--json]
migrate:refresh --force [--json]
migrate:fresh --force [--json]
sandbox [--to version] [--json]
schema:dump [--json]
schema:diff [--json]
db:inspect [--json]
db:tables [--json]
db:describe <table> [--json]
db:browse <table> [--limit n] [--offset n] [--order column] [--desc] [--json]
db:query (--sql SQL | --file path) [--json | --csv]
db:explain (--sql SQL | --file path) [--json]
db:export <table> --output path [--format csv|json] [--force] [--json]
db:insert <table> (--values-json object | --value column=value...) [--dry-run] [--json]
db:update <table> (--set-json object | --set column=value...) (--where-json object | --where column=value... | --all) --force [--dry-run] [--json]
db:delete <table> (--where-json object | --where column=value... | --all) --force [--dry-run] [--json]
db:truncate <table> --force [--dry-run] [--json]
db:execute (--sql SQL | --file path) --force [--dry-run] [--json]
db:import <table> --input path [--format csv|json] [--dry-run] [--json]
db:copy <source> <destination> [--dry-run] [--json]
db:vacuum [--json]
db:integrity [--quick] [--json]
db:optimize [--json]
db:backup --output path [--json]
db:restore --input path --force [--json]
```

The package-level CLI delegates these commands to the generated application
runner. This keeps the database path, migration index, SQLite initialization,
and environment policy in application code.

`sandbox` creates a temporary database, applies migrations, runs an integrity
check, and deletes it. `schema:diff` compares the configured database against a
clean sandbox migration run and reports added, removed, or changed objects.

`db:tables`, `db:describe`, and `db:browse` provide bounded database
exploration without requiring the platform `sqlite3` executable. Browse output
defaults to 50 rows and accepts at most 1000 rows per invocation. `db:query`
executes only read-only SQL from `--sql` or `--file`; SQLite's `query_only`
connection guard remains enabled during execution. Use `db:explain` to show an
`EXPLAIN QUERY PLAN` result for the same class of statement.

`db:export` writes a complete table or view as RFC 4180-style CSV or JSON.
The format defaults from a `.json` output extension and otherwise defaults to
CSV. BLOB values are emitted as base64 (as a `{ "base64": "..." }` object in
JSON). Exports stream in bounded pages and write through a temporary file so a
failed export does not leave a partial destination. Existing files are refused
unless `--force` is present. Paths are resolved by the application runner
process.

## Data manipulation

`db:insert` accepts a JSON object or repeated `--value column=value` options and
binds every value as a SQL parameter. Update values likewise accept `--set-json`
or repeated `--set`. Assignment values recognize JSON scalars (`null`, booleans,
and numbers) and otherwise remain text.

`db:update` and `db:delete` require a non-empty `--where-json` equality map,
repeated `--where column=value` options, or an explicit `--all`; an omitted or
empty scope is refused. Their `--dry-run` mode reports the matching count and
up to 20 sample rows without
requiring destructive-operation permission.

```shell
dart run sqlite_loom db:insert users \
  --value name=Omar --value active=true
dart run sqlite_loom db:update users \
  --set active=false --where id=42 --dry-run
dart run sqlite_loom db:update users \
  --set active=false --where id=42 --force
dart run sqlite_loom db:delete audit_logs --all --force
dart run sqlite_loom db:import users --input tool/fixtures/users.json --dry-run
```

Actual updates, deletes, truncation, and `db:execute` use the same runner,
environment, production, and confirmation safeguards as destructive migration
commands. `db:execute` is atomic and accepts one DML or DDL statement; it
rejects read-only SQL, transaction control, PRAGMAs, attachment, and vacuuming.
Use the dedicated commands for those operations.

`db:import` accepts an array of JSON objects or RFC 4180-style CSV with a header
row. It validates every column before opening one transaction, so any invalid
or conflicting row rolls back the entire import. CSV fields are imported as
text and SQLite applies the destination column affinity. `db:copy` inserts all
shared source/destination columns in one statement and refuses a self-copy.
Both commands are additive and fail normally on constraint conflicts.
JSON import recognizes exported `{ "base64": "..." }` values and byte arrays
as BLOBs, allowing lossless JSON export/import round trips.

`db:truncate` deletes every row and resets the table's AUTOINCREMENT sequence.
`db:vacuum` rebuilds the configured database using SQLite's `VACUUM` command.
Use `--json` for stable structured mutation counts and diagnostics.

Insert, import, and copy operations require data-manipulation permission from
the application runner and are refused in production by default, but do not
require `--force` because they are additive. By default this permission follows
`allowDestructive`; custom runners can set `allowDataManipulation` separately.

Destructive commands require all of the following:

1. the application runner enables destructive operations;
2. the environment is not production, unless the application explicitly opts
   into production destruction;
3. the user supplies `--force` or passes the runner's confirmation callback.

Use `--json` for CI and scripts. Stable success, usage, unavailable-service,
refusal, and software-failure exit codes let automation fail predictably.

## CI baseline

```shell
dart run sqlite_loom doctor
dart run sqlite_loom migrate:validate --json
dart run sqlite_loom sandbox --env staging --json
dart run sqlite_loom schema:diff --env staging --json
```

Commit migration source, the readable index, and the finalized lock together. Never
commit `.sqlite_loom/development.sqlite` or its journal/WAL sidecars.
