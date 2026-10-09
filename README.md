# Strix

Embedded SQL database written in Odin. Databases are single files with a `.strix` suffix (default path: `database.strix`).

Requires a working [Odin](https://odin-lang.org/) toolchain on `PATH`.

## Build

```bash
./build.sh          # → ./strix  (default; same as ./build.sh build)
./build.sh test     # package tests under src/test/ and layer packages
./build.sh clean
```

`OUT` / `SRC` env vars override binary name and source package dir (see `./build.sh help`).

## Quickstart

```bash
./build.sh
./strix init examples/demo          # creates examples/demo.strix
./strix sql examples/demo -c "CREATE TABLE t (id INT PRIMARY KEY, name TEXT); INSERT INTO t VALUES (1, 'hi'); SELECT * FROM t;"
./strix sql examples/demo examples/comprehensive.sql
./strix shell examples/demo         # interactive REPL; .help for meta-commands
```

Other batch forms:

```bash
./strix sql examples/demo file.sql
./strix sql examples/demo < file.sql          # stdin
./strix sql examples/demo --continue-on-error file.sql
```

Path args get `.strix` appended when missing. With no command and a TTY stdin, `./strix` opens the shell on `database.strix`.

Shell SQL is statement-oriented (buffer until `;`). Dot-commands (`.tables`, `.schema`, `.read`, `.quit`, …) are meta, not SQL — see [`docs/cli-shell.md`](docs/cli-shell.md).

## SQL surface

Treat [`docs/sql-dialect.md`](docs/sql-dialect.md) as the living contract, especially **Executed vs parsed only**. The parser accepts more than execute runs; unsupported forms fail clearly (no silent affinity, no `CASE` / `LIKE` / WAL claims here).

Related plans:

| Doc | Role |
|-----|------|
| [`docs/sql-compliance.md`](docs/sql-compliance.md) | Typed-subset / compliance program (S0–S6) |
| [`docs/sql-followon.md`](docs/sql-followon.md) | Post-S6 widening (F0–F4) |
| [`docs/sql-execute.md`](docs/sql-execute.md) | Execute wiring (E1–E6) |
| [`docs/storage-format.md`](docs/storage-format.md) | On-disk layout |
| [`docs/storage-engine.md`](docs/storage-engine.md) | `dbfile` / `paging` / `engine` |

Smoke script for the executed subset: [`examples/comprehensive.sql`](examples/comprehensive.sql).

## Parameter binds

Prepared `?` / `?N` binding is an **API** surface (`session_bind` / `session_bind_all` / `exec_statement_params` on `Exec_Session`). Batch `strix sql` and the interactive shell take **literals in SQL text only** — no `.param` / `--bind` yet. See dialect § Prepared parameters; tests in `src/test/exec/bind_test.odin`.

## Durability

Commit uses an in-place flush with a page-0 flush-in-progress fence (no WAL / rollback journal yet). A crash mid-flush can leave a torn file; reopen of a fenced file is **refused** (`.Torn_Flush`) rather than serving mixed pages. In-session flush failure requires retrying `COMMIT` on the still-open session; process exit forfeits dirty pages. Details: [`docs/storage-format.md`](docs/storage-format.md).
