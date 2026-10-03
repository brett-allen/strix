# Plan: SQL Bind & Execute

Wire the existing SQL parser (`src/sql`) to the storage stack (`src/engine`) so users can run DDL/DML against a `.strix` file.

| | |
|---|---|
| **Branch** | `feature/sql-execute` |
| **Depends on** | Parser v1 DoD ([`sql-parser.md`](sql-parser.md)), storage v1 DoD ([`storage-engine.md`](storage-engine.md) S0–S4), CLI `init` ([`src/cli`](../src/cli)) |
| **Supersedes** | Storage plan phase S5 (“SQL DDL/DML slice”) — execution work lives here |

---

## Audience

| Reader | Use this doc to… |
|--------|------------------|
| Implementer | Start at [Prerequisites](#prerequisites--starting-state), then phase **E1** |
| PM / lead | Track [Phased delivery](#phased-delivery); minimum ship = [DoD](#definition-of-done-execute-v1) (**E1–E4**); **E5–E6** are stretch |

**Rule for phases:** every phase ends with durable or user-visible value. Scaffolding (`package exec`, types, wire tests) is an implementation detail inside the phase that needs it — never a standalone milestone.

---

## Prerequisites / starting state

Already landed (do not re-implement):

| Layer | Status | Notes |
|-------|--------|--------|
| `src/sql` | Parser v1 DoD | `parse_statement` / `parse_script` → AST; no storage imports |
| `src/engine` | Storage S0–S4 | `engine_create` / `engine_open`, txns, btree, `table_prime`, `table_insert_row` / `table_get_row` |
| Catalog payload | **v2 tables** / v1 indexes ([`storage-format.md`](storage-format.md)) | Key `table:<name>` / `index:<name>`; table v2 = roots + `columns[]` + `next_rowid` |
| Heap row payload | Opaque bytes | Engine does not interpret columns today (row codec = E2) |
| CLI | `strix init` / `strix sql` | Default path `database.strix`; bare names get `.strix` via `ensure_strix_path` |

**Missing after E1:** row codec + `INSERT`/`SELECT`/`UPDATE`/`DELETE` execution (E2–E4); indexes from SQL (E5).

---

## Goals

- Parse user SQL → **bind** (resolve names against catalog) → **execute** via engine btree/catalog APIs.
- Useful first subset end-to-end: `CREATE TABLE` → `INSERT` → `SELECT` → `UPDATE` / `DELETE`; then stretch `CREATE INDEX` / polish.
- Keep **`src/sql` free of storage imports** (parser stays pure).
- One open database session; statements run in auto-commit or (later) explicit transactions.
- CLI entry points to run SQL against a file created with `strix init`.
- Tests that round-trip: SQL text → durable rows → SQL read-back.

## Non-goals (execute v1)

- Query planner / cost-based optimizer (trivial plans only: seq scan, point insert, etc.).
- Joins, `GROUP BY`, subqueries, views, triggers, CTEs — parser may accept some; executor returns a clear “not supported” error (never silent ignore).
- Prepared statements and parameter binding (`?` / `?N`): **defer**; literals only for v1 DML.
- Concurrent sessions / MVCC.
- WAL (still deferred at storage layer).
- Full SQLite type affinity / collation matrix — pragmatic scalar `Value` tags only.
- Network protocol / multi-user server.
- `ALTER TABLE` execution (parser may accept `ADD COLUMN`; reject at bind until a later plan).

---

## Architecture

```text
  CLI (src/cli)
       │  open .strix, feed SQL text
       ▼
┌──────────────┐     AST      ┌─────────────┐     bound ops     ┌──────────┐
│  src/sql     │ ──────────►  │  src/exec   │ ───────────────►  │  engine  │
│  parse_*     │              │  bind+run   │                   │  catalog │
└──────────────┘              └─────────────┘                   │  btree   │
       ▲                             │                          └────┬─────┘
       │ no engine/dbfile imports    │ reads catalog meta            │
       └─────────────────────────────┘                               ▼
                                                                 paging → dbfile
```

| Package | Role |
|---------|------|
| `src/sql` | Unchanged contract: tokenize/parse → AST + errors |
| `src/exec` (**new**) | Binder + executor; owns session that holds `^engine.Engine` |
| `src/engine` | Storage primitives; extend **catalog payload / row codec** as execute needs |
| `src/cli` | `init` (done); add `sql` command (name locked — not a second `exec` binary verb) |

**Import rule:** `sql` ↛ `exec` / `engine`. `exec` → `sql` + `engine`. `cli` → `exec` (+ `engine` only if needed for open helpers).

### Sketch API (`src/exec`)

```odin
Exec_Session :: struct { /* engine: ^Engine, … */ }

session_open  :: proc(path: string, …) -> (Exec_Session, Exec_Error)
session_adopt :: proc(e: ^engine.Engine) -> Exec_Session   // tests
session_close :: proc(s: ^Exec_Session)

exec_script   :: proc(s: ^Exec_Session, sql_text: string) -> (Exec_Result, Exec_Error)
exec_statement :: proc(s: ^Exec_Session, sql_text: string) -> (Exec_Result, Exec_Error)  // optional thin wrapper

Exec_Result :: struct {
  // kind: rows_affected | result_set | ok
  // rows_affected: int
  // columns / rows for SELECT (allocator-owned; free via free_result)
}
```

The split **session + script/statement entrypoints + freeable result/error** is the contract. Package/types appear when E1 needs them — not as a prior “scaffold phase.”

---

## Schema & row model (execute needs this)

Today’s catalog row is **payload v1**: roots only (see [`storage-format.md`](storage-format.md) § `table_prime`). Table **name** lives in the btree key (`table:<name>`), not in the payload. Execution needs column metadata and rowid allocation state.

### Default — catalog payload v2

**Default (open question #2):** bump `table_prime` **table** row `version` to **2**; keep key `table:<name>`.

Extend the table payload (keep `kind`, `root_page`; add schema fields):

| Field | Purpose |
|-------|---------|
| `version` | `2` |
| `kind` | `1` = table (unchanged) |
| `root_page` | Heap btree root |
| `columns[]` | Ordered: name, type name string (affinity later), not_null, pk flag |
| `next_rowid` | High-water for `INTEGER PRIMARY KEY` / implicit rowid |

Index rows stay v1 shape through E4; index **column list** can wait until E5 if needed. Document the byte layout in [`storage-format.md`](storage-format.md) when E1 lands.

**Proposed decision (alternative, not default):** a separate schema btree or side blob — only if v2 payload proves awkward during E1.

Optional: persist original `CREATE TABLE` SQL text in the catalog for `sqlite_master`-style introspection — nice-to-have in E1, not required for DoD (open question #5).

### Heap row payload

Encode leaf payloads as a simple record (freeze exact bytes in `storage-format.md` during E2):

```text
version u8 | col_count u16 | [null_bitmap] | concatenated field encodings
```

- Values: NULL / integer / float / text / blob (align with SQL literal kinds / runtime `Value`).
- Btree **key** = **big-endian u64 rowid** (already used by `table_insert_row`).
- `INTEGER PRIMARY KEY` column aliases rowid when present; otherwise allocate `next_rowid++` and persist the new high-water in the catalog row.

---

## Execution model

### Session

```text
Exec_Session {
  engine: ^Engine
  // optional: open table handles cache
}
```

- Open via path (`engine_open` / `engine_create` already exists) or **adopt** an existing engine (tests).
- Close flushes via normal engine close (rollback any open txn).

### Transactions

| Mode | Behavior |
|------|----------|
| Auto (default) | Each statement: `txn_begin` → execute → `txn_commit` (rollback on error) |
| Explicit | `BEGIN` / `COMMIT` / `ROLLBACK` in phase **E6** (stretch) |

DDL and DML both require a write txn under auto mode. Nested `BEGIN` while already in a txn → clear error.

**Note:** lexer knows `BEGIN` / `COMMIT` / `ROLLBACK` / `TRANSACTION` keywords today, but the parser does **not** emit txn statements yet. E6 either adds parse support or accepts exec-only recognition of those keywords before/alongside `parse_*`.

### Statement pipeline

1. **Parse** — `sql.parse_statement` / `parse_script`
2. **Bind** — resolve table/column names, types, column indexes; reject unsupported AST shapes with `Exec_Error` + span when available
3. **Plan** — trivial only: “seq scan”, “point insert”, “create table storage”
4. **Execute** — call engine/catalog/btree; produce `Exec_Result` (rows affected / result set)

Unsupported but parsed SQL → bind-time or exec-time **clear error** (not silent ignore).

---

## CLI surface

Extend `strix` (keep `init`):

```text
strix init [path]              # existing
strix sql [path] -c 'SQL'      # run one string
strix sql [path] < file.sql    # run script from stdin
strix sql [path] file.sql      # run script file
```

- Default path = `database.strix` (same as `init`).
- Path resolution: reuse `ensure_strix_path` so `strix sql demo …` opens `demo.strix`.
- Print:
  - DDL/DML writes: `ok` / `N rows` on stdout; errors on stderr with location when known
  - `SELECT`: aligned text table (column names + rows) for v1 (open question #4)

`strix sql` ships in **E1** for DDL (`CREATE`/`DROP TABLE`). Later phases extend what the same command can run.

---

## Phased delivery

Minimum DoD = **E1–E4**. **E5–E6** are stretch.

| Phase | Ships | Value |
|-------|-------|-------|
| **E1** | Session + catalog v2 + `CREATE`/`DROP TABLE` + CLI `sql` | Durable empty tables via SQL |
| **E2** | Row codec + `INSERT` | Durable rows via SQL |
| **E3** | Single-table `SELECT` | Read path / demo scripts |
| **E4** | `UPDATE` / `DELETE` | Full basic CRUD ← **DoD** |
| **E5** | Indexes (stretch) | Indexed tables from SQL |
| **E6** | Script/txn polish (stretch) | UX + dialect matrix |

### Phase E1 — Session, schema meta, `CREATE TABLE` / `DROP TABLE`

First milestone. Package scaffolding is whatever E1 needs to compile — it is **not** exit criteria by itself.

- [x] `src/exec` (`package exec`): session open/adopt/close; `exec_script` / errors / results
- [x] Catalog payload **v2** (columns + `next_rowid`); update [`storage-format.md`](storage-format.md)
- [x] Engine helpers: register table **with schema**; unregister/drop catalog row (new API if needed)
- [x] Bind + exec `CREATE TABLE [IF NOT EXISTS]` (auto-commit write txn)
- [x] Bind + exec `DROP TABLE [IF EXISTS]` (unregister; page reclaim best-effort; index policy per open Q #6)
- [x] Unsupported stmt kinds / table options → clear error (not a “reject everything” stub as the deliverable)
- [x] `strix sql` runs `CREATE`/`DROP` against a `.strix` file (`init` then `sql -c '…'`)
- [x] Tests: create → reopen → catalog shows columns; `IF NOT EXISTS`; drop removes catalog entry
- [x] Wire `./build.sh test` → `src/test/exec`

**Exit:** After `strix init` + `strix sql … -c 'CREATE TABLE …'`, reopening the file shows the table and column meta in `table_prime` (v2). `DROP TABLE` removes it. No empty “parse-only stub” phase counts as done.

**Index policy (Q #6):** `DROP TABLE` **rejects** with a clear error if any `index:` catalog rows still name that table as parent (until E5 defines cascade).

### Phase E2 — `INSERT` + row codec

- [ ] Row encode/decode for heap payloads; document in [`storage-format.md`](storage-format.md)
- [ ] `INSERT INTO t [(cols)] VALUES (...), (...)`
- [ ] Auto rowid / PK rowid rules; persist `next_rowid`
- [ ] Column default: only literal / `NULL` defaults if already on AST; else error
- [ ] Reject `INSERT … SELECT` / `DEFAULT VALUES` / conflict clauses with clear errors unless already trivial
- [ ] Tests: insert → reopen → `table_get_row` (and SQL `SELECT` once E3 lands)

**Exit:** user can `init`, `CREATE TABLE`, `INSERT` via CLI; rows survive reopen.

### Phase E3 — `SELECT` (single table)

- [ ] `SELECT` projection (`*`, columns, simple exprs over row)
- [ ] `FROM` single table; optional alias
- [ ] `WHERE` on bound columns (expression eval over row values — see [Expression evaluation](#expression-evaluation-binderexecutor))
- [ ] `ORDER BY` / `LIMIT` / `OFFSET` in executor (in-memory sort OK for v1)
- [ ] Reject joins / `GROUP BY` / subqueries / `DISTINCT` (unless trivial) clearly
- [ ] CLI prints result sets
- [ ] Tests: filter/sort/limit; golden text output optional

**Exit:** read path for bootstrap-style scripts (create/insert/select).

### Phase E4 — `UPDATE` / `DELETE`

- [ ] `DELETE FROM t [WHERE …]`
- [ ] `UPDATE t SET … [WHERE …]`
- [ ] Row rewrite / delete-by-rowid
- [ ] If indexes exist before E5: **forbid** `UPDATE`/`DELETE` with a clear error — do not leave indexes stale
- [ ] Tests: mutate + select; reopen

**Exit:** basic CRUD via SQL. **← minimum execute v1 DoD**

### Phase E5 — Stretch: `CREATE INDEX` / `DROP INDEX` + maintenance

- [ ] `CREATE INDEX` → `catalog_register_index` + backfill from table scan
- [ ] `DROP INDEX`
- [ ] Maintain indexes on `INSERT` / `UPDATE` / `DELETE`
- [ ] Optional: use index for simple `WHERE col = const` (point lookup); seq scan remains correct
- [ ] Tests: index create, insert maintains, lookup path

**Exit:** indexed tables usable from SQL.

### Phase E6 — Stretch: script UX + polish

- [ ] Multi-statement scripts with stop-on-error; optional continue-on-error flag
- [ ] `BEGIN` / `COMMIT` / `ROLLBACK` (parse and/or exec-only keywords)
- [ ] Better error formatting (`file:line:col: message`)
- [ ] Run parser fixtures `bootstrap_v1.sql` / `crud.sql` **adapted** to the supported execute subset against a real `.strix` (full fixture includes `CREATE INDEX` — needs E5 or trim)

**Exit:** “Executed vs parsed-only” section in [`sql-dialect.md`](sql-dialect.md) kept current (prefer that over a new `sql-execute-support.md` unless the table outgrows the dialect doc).

---

## Expression evaluation (binder/executor)

For `WHERE` / `SET` / projections (mainly E3–E4):

- Eval AST `Expr` against a **row environment** (column name/index → `Value`).
- Support parser Phase 1 exprs that are meaningful on scalars: literals, column refs, comparisons, `AND`/`OR`/`NOT`, arithmetic, `IS NULL`, `IN` list (see [`sql-parser.md`](sql-parser.md) Phase 1).
- Fail clearly on unbound names, type conflicts, or unsupported nodes (`CAST` optional early; `BETWEEN` optional).

Do **not** implement a full SQL type system in E1–E3 — use a small runtime `Value` tagged union.

---

## Error model

```odin
Exec_Error :: struct {
  code:    Exec_Error_Code,
  message: string,   // owned
  span:    sql.Span, // if available
}
```

- Map engine errors to exec errors; free messages like `sql.free_error`.
- Prefer stable `Exec_Error_Code` values for negatives tests (e.g. `Unsupported_Ast`, `Unknown_Table`, `Unknown_Column`, `Constraint`, `Engine`).
- Introduce codes in E1 as CREATE/DROP needs them; avoid casual churn after E2 negatives lock in.

---

## Testing strategy

| Layer | Focus |
|-------|--------|
| `exec` unit | Bind failures; schema meta; CREATE/DROP; later row codec + DML |
| Integration | Temp `.strix` via `engine_create`; SQL → reopen catalog/rows |
| CLI | Smoke from E1: `init` + `sql -c 'CREATE TABLE …'`; pure `parse_sql_command_args` unit tests |
| Negative | Unsupported AST (join, etc.) → stable error code |

Wire `src/test/exec` into `./build.sh test` as part of E1.

**Hard rule (until coverage tooling exists):** each execute phase must ship an inventory of that phase’s new package surface (public procs + engine helpers the phase introduced/changed for exec) with test mapping, and achieve **≥80% symbol coverage** by the inventory method — see [`exec-e1-coverage.md`](exec-e1-coverage.md) for E1. Tests must assert error **codes** and/or **durable outcomes**, not vacuous `has_error` / compile-only checks.

---

## Documentation deliverables

| Doc | Purpose |
|-----|---------|
| `docs/sql-execute.md` | This plan (living) |
| `docs/storage-format.md` | Catalog v2 (E1) / row payload bytes (E2) |
| `docs/sql-dialect.md` | **Executed** vs **Parsed only** — update as phases land |
| `docs/storage-engine.md` | S5 points here (done) |
| `docs/exec-e1-coverage.md` | E1 symbol inventory + ≥80% coverage proof |

---

## Definition of done (execute v1)

- [ ] Phases **E1–E4** complete; tests green under `./build.sh test`
- [ ] CLI: `init` + `sql` can run create/insert/select/update/delete on a `.strix` file
- [ ] `src/sql` still has no `engine` / `exec` imports
- [ ] Unsupported SQL fails with clear errors (no silent no-ops)
- [ ] Catalog v2 + heap row formats documented in `storage-format.md`
- [ ] Dialect doc states what execute supports (update the stub table as each phase lands; fuller matrix by E6)

**Stretch (not required for DoD):** E5 (indexes), E6 (txn keywords, fixture polish, richer dialect matrix).

---

## Open questions

Defaults stand unless overridden before/during the relevant phase:

1. **Package name:** `exec` vs `runtime` vs `query` — **default `exec`.**
2. **Catalog v2 vs separate schema btree** — **default: version bump on `table:<name>` payload.**
3. **Implicit commit per statement vs requiring `BEGIN`** — **default: auto-commit per statement.**
4. **SELECT output format** — aligned columns vs CSV — **default: aligned text for CLI.**
5. **Persist original `CREATE TABLE` SQL text in catalog?** — nice for `sqlite_master` parity; **optional in E1**, not DoD.
6. **`DROP TABLE` with indexes:** cascade-drop indexes vs reject until indexes dropped — **Decided in E1: reject with clear error until E5 defines cascade.**

---

## Immediate next steps

1. Land this plan; override open-question defaults only if you disagree.
2. Implement **E1** (session + catalog v2 + `CREATE`/`DROP TABLE` + CLI `sql`).
3. **E2** `INSERT`, then **E3** `SELECT` for a demo path:

```bash
./strix init demo
./strix sql demo -c "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);"
./strix sql demo -c "INSERT INTO t (id, name) VALUES (1, 'a');"
./strix sql demo -c "SELECT id, name FROM t;"
# opens demo.strix (ensure_strix_path)
```
