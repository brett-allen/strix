# Plan: SQL Bind & Execute

Wire the existing SQL parser (`src/sql`) to the storage stack (`src/engine`) so users can run DDL/DML against a `.strix` file.

| | |
|---|---|
| **Branch** | `feature/sql-execute` |
| **Depends on** | Parser v1 DoD ([`sql-parser.md`](sql-parser.md)), storage v1 DoD ([`storage-engine.md`](storage-engine.md) S0–S4), CLI `init` ([`src/cli`](../src/cli)) |
| **Supersedes** | Storage plan phase S5 (“SQL DDL/DML slice”) — execution work lives here |
| **Post-E6 semantics** | Prefer SQL compliance over SQLite quirks — living plan [`sql-compliance.md`](sql-compliance.md) (S0–S6). Post-S6 widening (**F0–F4** complete): LEFT/3+ joins, composite PK, BOOLEAN/typed UUID, prepared `?` — [`sql-followon.md`](sql-followon.md). This doc remains the execute **wiring** history (E1–E6); compliance + follow-on own later semantic evolution. |

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
| Heap row payload | **E2** | `version \| col_count \| null_bitmap \| fields` — see [`storage-format.md`](storage-format.md) |
| CLI | `strix init` / `strix sql` | Default path `database.strix`; bare names get `.strix` via `ensure_strix_path` |

**E1–E6 landed** on `feature/sql-execute` (E5–E6 were stretch).

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
- Subqueries, views, triggers, CTEs — parser may accept some; executor returns a clear “not supported” error (never silent ignore). `GROUP BY`/`HAVING` executed (S5). Joins: `INNER`/`CROSS`/`LEFT OUTER`, N tables left-deep (S6 + F1); `USING` / `RIGHT` / `FULL` / `NATURAL` still rejected — see [`sql-followon.md`](sql-followon.md) F1.
- Prepared statements and parameter binding (`?` / `?N`): **landed in F4** as a session bind API (not SQL `PREPARE`/`EXECUTE` text) — see sketch below and [`sql-dialect.md`](sql-dialect.md) § Prepared parameters.
- Concurrent sessions / MVCC.
- WAL (still deferred at storage layer).
- SQLite type affinity / collation matrix — out of scope; declared types + explicit `CAST` (S2); pragmatic scalar `Value` tags only.
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
Exec_Session :: struct { /* eng, txn flags, binds: Bind_Table, … */ }

session_open  :: proc(path: string, …) -> (Exec_Session, Exec_Error)
session_adopt :: proc(e: ^engine.Engine) -> Exec_Session   // tests
session_close :: proc(s: ^Exec_Session)

exec_script   :: proc(s: ^Exec_Session, sql_text: string) -> (Exec_Result, Exec_Error)
exec_statement :: proc(s: ^Exec_Session, sql_text: string) -> (Exec_Result, Exec_Error)

// F4 — positional parameters (named extension; not SQL PREPARE/EXECUTE text)
session_bind       :: proc(s: ^Exec_Session, index: int, value: Value) -> Exec_Error  // clones value
session_bind_all   :: proc(s: ^Exec_Session, values: []Value) -> Exec_Error           // clear + bind 0..n-1
session_clear_binds :: proc(s: ^Exec_Session)
exec_statement_params :: proc(s: ^Exec_Session, sql_text: string, params: []Value) -> (Exec_Result, Exec_Error)
//   binds params, checks arity vs max `?`/`?N` in the statement, executes, clears binds.
//   Caller retains ownership of `params`. Unbound / arity → Invalid_Schema; kind → Constraint.

Exec_Result :: struct {
  // kind: rows_affected | result_set | ok
  // rows_affected: int
  // columns / rows for SELECT (allocator-owned; free via free_result)
}
```

The split **session + script/statement entrypoints + freeable result/error** is the contract. Package/types appear when E1 needs them — not as a prior “scaffold phase.” **F4** adds the bind table on the session; `Placeholder` eval reads the active bind table for the current statement.

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
| `columns[]` | Ordered: name, type name string (declared type; no SQLite affinity), not_null, pk flag |
| `next_rowid` | High-water for IPK (`INTEGER`/`INT PRIMARY KEY`) / implicit rowid |

Index rows: v1 (legacy, no columns) through E4; **v2 column list** landed in E5 — see [`storage-format.md`](storage-format.md).

**Proposed decision (alternative, not default):** a separate schema btree or side blob — only if v2 payload proves awkward during E1.

Optional: persist original `CREATE TABLE` SQL text in the catalog for `sqlite_master`-style introspection — nice-to-have in E1, not required for DoD (open question #5).

### Heap row payload

Encode leaf payloads as a simple record (freeze exact bytes in `storage-format.md` during E2):

```text
version u8 | col_count u16 | [null_bitmap] | concatenated field encodings
```

- Values: NULL / integer / float / text / blob (align with SQL literal kinds / runtime `Value`).
- Btree **key** = **big-endian u64 rowid** (already used by `table_insert_row`).
- **IPK (rowid alias, named extension):** exactly **one** `PRIMARY KEY` column whose type name is `INTEGER` or `INT` (case-insensitive `equal_fold`; no `INTEGER(n)`, `BIGINT`, etc.). That column aliases the btree rowid; omit/`NULL` auto-allocates via `next_rowid++` (persisted in the catalog). Auto-alloc refuses past `max(i64)` (`Constraint`; no silent wrap to negative). No secondary unique index is required for the IPK column itself.
- **Non-IPK PRIMARY KEY (S3):** single-column PK on any other type (e.g. `TEXT`, `VARCHAR`, `UUID`) implies `NOT NULL` + a system unique secondary index (`strix_autoindex_<table>_<n>`). Duplicate / NULL PK → `Constraint`. Internal rowid is still allocated but **not** exposed as a SQL column.
- **Composite PRIMARY KEY (F2):** table `PRIMARY KEY (c1, c2, …)` (≥2 columns) implies `NOT NULL` on every PK column + a composite unique system index (same maintenance path as multi-column `UNIQUE`). Duplicate / NULL in any PK column → `Constraint`. Composite **never** aliases rowid.
- **UNIQUE (S3):** column/table `UNIQUE` and `CREATE UNIQUE INDEX` create/maintain unique secondary indexes; collisions → `Constraint`. Multiple NULLs are allowed on nullable UNIQUE columns.

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
- Close rolls back any open txn then closes the pager. If a **partial flush fence** is live (`.Flush_Failed`), close is **refused**: session/engine stay open with dirty frames intact so the caller can retry `COMMIT`. Close never destroys recovery state and then reports an error.

### Transactions

| Mode | Behavior |
|------|----------|
| Auto (default) | Each statement: `txn_begin` → execute → `txn_commit` (rollback on error) |
| Explicit | `BEGIN` / `COMMIT` / `ROLLBACK` (**E6**) |

DDL and DML both require a write txn under auto mode. Nested `BEGIN` while already in a txn → clear `In_Txn` error. Statements inside an explicit txn join the open engine txn (no per-statement commit) until `COMMIT` / `ROLLBACK`. Write failure inside an explicit txn aborts the whole txn (`txn_aborted`); `exec_script` then **stops even with `continue_on_error`**.

**Flush fence (H2):** if `txn_commit` partially writes data pages, the pager refuses `discard_dirty` / `txn_rollback` / close until a flush succeeds. Exec must not ignore that refusal (`_ = txn_rollback`): surface a clear recovery error, keep `engine.in_txn` / `explicit_txn` consistent, and block further non-recovery writes.

**Recovery recipe (in-process / shell):** retry `COMMIT` (recovery flush) **on the still-open session**. `ROLLBACK` stays refused until a flush succeeds. Auto-commit statements that hit the fence **promote** to `explicit_txn` (same recovery path as an explicit `COMMIT` fence) so SQL is not stranded (`COMMIT`/`ROLLBACK` → `No_Txn` while `BEGIN` → `In_Txn`). `session_close` / `engine_close` / shell destroy **refuse** while fenced (session stays usable). Shell refuses `.open` / `.quit` / EOF / `--bail` exit while fenced (stay in REPL until `COMMIT`); read-only `SELECT` is allowed under the fence for inspection.

**Batch `strix sql`:** process exit **cannot** keep a recovery session alive. Close refusal → exit **1** and **forfeits** in-memory dirty pages; the database may be torn after a partial flush. Do **not** tell the user to “retry `COMMIT` on an open session” after the batch process has exited.

**Fence gate (all entry points):** `exec_statement` / `exec_statement_ast` / `exec_script` / shell typed SQL all hard-stop non-recovery writes while fenced. Allowed: recovery `COMMIT`, read-only `SELECT`. Everything else errors (or is skipped under `continue_on_error` — see below).

**`continue_on_error` × flush fence:** after `exec_commit` or an auto-commit write hits `.Flush_Failed` (auto-commit promotes to `explicit_txn`), non-allowed statements are **skipped** until a recovery `COMMIT` in the same script (do not set `txn_aborted` for this path — that would block recovery `COMMIT`). Without `continue_on_error`, the **next** statement must be `COMMIT` (or `SELECT`) or the script stops. If the script ends still fenced after skips → error.

**`txn_aborted` scope:** annotation (“transaction aborted — script stopped”) applies only to aborts in the **current** `exec_script`. Starting a new script after abort has settled (`!explicit_txn`) clears the sticky flag so later scripts / `.read` are not poisoned.

**E6:** parser emits `Begin` / `Commit` / `Rollback` statement kinds (`TRANSACTION` optional); executor owns explicit-txn state on `Exec_Session`.

### Statement pipeline

1. **Parse** — `sql.parse_statement` / `parse_script`
2. **Bind** — resolve **column** names via case-insensitive `equal_fold`; **table/index** names are case-sensitive catalog keys; reject case-only duplicate columns at CREATE; reject unsupported AST shapes with `Exec_Error` + span when available
3. **Plan** — trivial only: “seq scan”, “point insert”, “create table storage”; optional **text/blob** index point lookup
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
strix shell [path]             # interactive REPL (SQL + .commands)
```

- Default path = `database.strix` (same as `init`).
- Path resolution: reuse `ensure_strix_path` so `strix sql demo …` opens `demo.strix`.
- Print:
  - DDL/DML writes: `ok` / `N rows` on stdout; errors on stderr with location when known
  - `SELECT`: aligned text table (column names + rows) for v1 (open question #4)

`strix sql` ships in **E1** for DDL (`CREATE`/`DROP TABLE`). Later phases extend what the same command can run.

Interactive shell (`strix shell`) is a separate surface on top of the same `src/exec` session API: multi-line SQL until `;`, plus line-based `.commands` (`.tables`, `.schema`, `.read`, `.open`, display toggles, etc.). See [`cli-shell.md`](cli-shell.md) for the shell plan, DoD (C1–C4), and coverage inventories.

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
- [x] Bind + exec `DROP TABLE [IF EXISTS]` (unregister; **full btree page reclaim** onto freelist; index policy per open Q #6)
- [x] Unsupported stmt kinds / table options → clear error (not a “reject everything” stub as the deliverable)
- [x] `strix sql` runs `CREATE`/`DROP` against a `.strix` file (`init` then `sql -c '…'`)
- [x] Tests: create → reopen → catalog shows columns; `IF NOT EXISTS`; drop removes catalog entry
- [x] Wire `./build.sh test` → `src/test/exec`

**Exit:** After `strix init` + `strix sql … -c 'CREATE TABLE …'`, reopening the file shows the table and column meta in `table_prime` (v2). `DROP TABLE` removes it. No empty “parse-only stub” phase counts as done.

**Index policy (Q #6):** `DROP TABLE` **rejects** with a clear error if any `index:` catalog rows still name that table as parent (until E5 defines cascade).

### Phase E2 — `INSERT` + row codec

- [x] Row encode/decode for heap payloads; document in [`storage-format.md`](storage-format.md)
- [x] `INSERT INTO t [(cols)] VALUES (...), (...)`
- [x] Auto rowid / PK rowid rules; persist `next_rowid` (`catalog_update_next_rowid`)
- [x] IPK policy: sole `INTEGER`/`INT PRIMARY KEY` = rowid alias (extension); S3 adds non-IPK single-column PK + UNIQUE; F2 adds composite PK (unique system index; never rowid alias)
- [x] Column default: only literal / `NULL` defaults if already on AST; else error
- [x] Reject `INSERT … SELECT` / `DEFAULT VALUES` / conflict clauses with clear errors unless already trivial
- [x] Tests: insert → reopen → `table_get_row` + decode (SQL `SELECT` once E3 lands); multi-row INSERT rollback on mid-statement failure
- [x] Coverage inventory: [`exec-e2-coverage.md`](exec-e2-coverage.md)

**Exit:** user can `init`, `CREATE TABLE`, `INSERT` via CLI; rows survive reopen.

### Phase E3 — `SELECT` (single table)

- [x] `SELECT` projection (`*`, columns, simple exprs over row)
- [x] `FROM` single table; optional alias
- [x] `WHERE` on bound columns (expression eval over row values — see [Expression evaluation](#expression-evaluation-binderexecutor))
- [x] `ORDER BY` / `LIMIT` / `OFFSET` in executor (in-memory sort OK for v1)
- [x] Reject subqueries / `DISTINCT` clearly; `GROUP BY`/`HAVING` executed in S5; joins executed in S6 + F1 (`INNER`/`CROSS`/`LEFT`, N tables; `USING` / `RIGHT`/`FULL`/`NATURAL` still rejected)
- [x] CLI prints result sets
- [x] Tests: filter/sort/limit; create/insert/select round-trip; negatives with codes
- [x] Coverage inventory: [`exec-e3-coverage.md`](exec-e3-coverage.md)

**Exit:** read path for bootstrap-style scripts (create/insert/select).

### Phase E4 — `UPDATE` / `DELETE`

- [x] `DELETE FROM t [WHERE …]`
- [x] `UPDATE t SET … [WHERE …]`
- [x] Row rewrite / delete-by-rowid (`table_delete_row` / `table_rewrite_row`)
- [x] If indexes exist before E5: **forbid** `UPDATE`/`DELETE` with a clear error — do not leave indexes stale *(E5: maintain when column metadata present; still forbid legacy no-column indexes)*
- [x] Tests: mutate + select; reopen; WHERE filter; negatives with codes
- [x] Coverage inventory: [`exec-e4-coverage.md`](exec-e4-coverage.md)

**Exit:** basic CRUD via SQL. **← minimum execute v1 DoD**

### Phase E5 — Stretch: `CREATE INDEX` / `DROP INDEX` + maintenance

- [x] `CREATE INDEX` → `catalog_register_index` + backfill from table scan
- [x] `DROP INDEX`
- [x] Maintain indexes on `INSERT` / `UPDATE` / `DELETE`
- [x] Optional: use index for simple **text/blob** `WHERE col = const` point lookup (numeric eq skipped — index keys are tag-exact; seq scan remains correct); Engine/Io/encode failures on the index path fail hard (no silent seq-scan fallback)
- [x] Tests: index create, insert maintains, lookup path; reopen durable
- [x] Coverage inventory: [`exec-e5-coverage.md`](exec-e5-coverage.md)
- [x] Index catalog v2 column list documented in [`storage-format.md`](storage-format.md)
- [x] `DROP TABLE` still rejects while indexes remain (no cascade)

**Exit:** indexed tables usable from SQL.

### Phase E6 — Stretch: script UX + polish

- [x] Multi-statement scripts with stop-on-error; optional continue-on-error flag (`Exec_Options` / CLI `--continue-on-error`)
- [x] `BEGIN` / `COMMIT` / `ROLLBACK` (parser emits stmt kinds; exec explicit txn mode)
- [x] Better error formatting (`file:line:col: message` when path/span known)
- [x] Run parser fixtures `bootstrap_v1.sql` / `crud.sql` against a real `.strix` (full E5 index support; no trim needed)
- [x] Coverage inventory: [`exec-e6-coverage.md`](exec-e6-coverage.md)

**Exit:** “Executed vs parsed-only” section in [`sql-dialect.md`](sql-dialect.md) kept current (prefer that over a new `sql-execute-support.md` unless the table outgrows the dialect doc).

---

## Expression evaluation (binder/executor)

For `WHERE` / `SET` / projections (mainly E3–E4):

- Eval AST `Expr` against a **row environment** (column name/index → `Value`).
- Support parser Phase 1 exprs that are meaningful on scalars: literals, column refs, comparisons, `AND`/`OR`/`NOT`, arithmetic, `IS NULL`, `IN` list (see [`sql-parser.md`](sql-parser.md) Phase 1).
- **Integer–Integer** comparisons use exact `i64` ordering (not `f64`); mixed integer/float still coerces via `f64`.
- Fail clearly on unbound names, type conflicts, or unsupported nodes (`BETWEEN` optional).
- **S2:** scalar `CAST(expr AS type)` is executed — supported pairs and Text→INTEGER rules live in [`sql-dialect.md`](sql-dialect.md) § Scalar CAST and [`sql-compliance.md`](sql-compliance.md) Phase S2. Invalid casts error (not NULL-by-affinity).
- **S4:** whole-query aggregates (`COUNT` / `SUM` / `AVG` / `MIN` / `MAX`) on `SELECT` without `GROUP BY` — see [`sql-dialect.md`](sql-dialect.md) § Aggregates and [`sql-compliance.md`](sql-compliance.md) Phase S4. Mix of aggregates with bare columns without `GROUP BY` → `Unsupported_Ast` (strict).
- **S5:** `GROUP BY` (column refs) + `HAVING`; strict select list; empty groups → 0 rows — see [`sql-dialect.md`](sql-dialect.md) § GROUP BY / HAVING and [`sql-compliance.md`](sql-compliance.md) Phase S5.
- **S6 + F1:** left-deep nested-loop `INNER` / `CROSS` / comma-join / `LEFT [OUTER] JOIN` … `ON`, N tables; multi-table column bind with aliases / `t.col`; ambiguous unqualified → `Unknown_Column`; aggs/`GROUP BY`/`HAVING` over joins supported — see [`sql-dialect.md`](sql-dialect.md) § JOIN and [`sql-followon.md`](sql-followon.md) Phase F1.

Do **not** implement a full SQL type system in E1–E3 — use a small runtime `Value` tagged union; conversion is explicit via `CAST`.

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
- E1 codes: `Parse`, `Unsupported_Ast`, `Unknown_Table`, `Table_Exists`, `Has_Indexes`, `Invalid_Schema`, `Engine`, `Io`, `Closed`.
- **E2 added:** `Unknown_Column`, `Constraint` (NOT NULL / duplicate rowid / bad IPK).
- **E5 added:** `Index_Exists`, `Unknown_Index`.
- **E6 added:** `In_Txn`, `No_Txn`.

---

## Testing strategy

| Layer | Focus |
|-------|--------|
| `exec` unit | Bind failures; schema meta; CREATE/DROP; later row codec + DML |
| Integration | Temp `.strix` via `engine_create`; SQL → reopen catalog/rows |
| CLI | Smoke from E1: `init` + `sql -c 'CREATE TABLE …'`; pure `parse_sql_command_args` unit tests |
| Negative | Unsupported AST (`USING`, `DISTINCT`, etc.) / parse rejects (`RIGHT`/`FULL`/`NATURAL`) → stable error codes |

Wire `src/test/exec` into `./build.sh test` as part of E1.

**Hard rule (until coverage tooling exists):** each execute phase must ship an inventory of that phase’s new package surface (public procs + engine helpers the phase introduced/changed for exec) with test mapping, and achieve **≥80% symbol coverage** by the inventory method — see [`exec-e1-coverage.md`](exec-e1-coverage.md) (E1), [`exec-e2-coverage.md`](exec-e2-coverage.md) (E2), [`exec-e3-coverage.md`](exec-e3-coverage.md) (E3), [`exec-e4-coverage.md`](exec-e4-coverage.md) (E4), [`exec-e5-coverage.md`](exec-e5-coverage.md) (E5), and [`exec-e6-coverage.md`](exec-e6-coverage.md) (E6). Tests must assert error **codes** and/or **durable outcomes**, not vacuous `has_error` / compile-only checks.

---

## Documentation deliverables

| Doc | Purpose |
|-----|---------|
| `docs/sql-execute.md` | This plan (living) — E1–E6 wiring |
| `docs/sql-compliance.md` | Post-E6 semantic north star (compliance subset, S0–S6) |
| `docs/sql-followon.md` | Post-S6 widening (joins / composite PK / types / prepared) |
| `docs/storage-format.md` | Catalog v2 (E1) / row payload bytes (E2) |
| `docs/sql-dialect.md` | **Executed** vs **Parsed only** — update as phases land |
| `docs/storage-engine.md` | S5 points here (done) |
| `docs/exec-e1-coverage.md` | E1 symbol inventory + ≥80% coverage proof |
| `docs/exec-e2-coverage.md` | E2 symbol inventory + ≥80% coverage proof |
| `docs/exec-e3-coverage.md` | E3 symbol inventory + ≥80% coverage proof |
| `docs/exec-e4-coverage.md` | E4 symbol inventory + ≥80% coverage proof |
| `docs/exec-e5-coverage.md` | E5 symbol inventory + ≥80% coverage proof |
| `docs/exec-e6-coverage.md` | E6 symbol inventory + ≥80% coverage proof |

---

## Definition of done (execute v1)

- [x] Phases **E1–E4** complete; tests green under `./build.sh test`
- [x] CLI: `init` + `sql` can run create/insert/select/update/delete on a `.strix` file
- [x] `src/sql` still has no `engine` / `exec` imports
- [x] Unsupported SQL fails with clear errors (no silent no-ops)
- [x] Catalog v2 + heap row formats documented in `storage-format.md`
- [x] Dialect doc states what execute supports (update the stub table as each phase lands; fuller matrix by E6)

**Stretch (not required for DoD):** E5 (indexes — landed), E6 (txn keywords, fixture polish, richer dialect matrix — landed).

---

## Open questions

Defaults stand unless overridden before/during the relevant phase:

1. **Package name:** `exec` vs `runtime` vs `query` — **default `exec`.**
2. **Catalog v2 vs separate schema btree** — **default: version bump on `table:<name>` payload.**
3. **Implicit commit per statement vs requiring `BEGIN`** — **default: auto-commit per statement** (E6 adds optional explicit `BEGIN`…`COMMIT`/`ROLLBACK`).
4. **SELECT output format** — aligned columns vs CSV — **default: aligned text for CLI.**
5. **Persist original `CREATE TABLE` SQL text in catalog?** — nice for `sqlite_master` parity; **optional in E1**, not DoD.
6. **`DROP TABLE` with indexes:** cascade-drop indexes vs reject until indexes dropped — **E1/E5: keep reject until indexes dropped** (no cascade).

---

## Immediate next steps

1. ~~Land this plan~~ / ~~E1~~ / ~~E2~~ / ~~E3~~ / ~~E4~~ / ~~E5~~ / ~~E6~~ done on `feature/sql-execute`.
2. ~~Semantic north star after E6: [`sql-compliance.md`](sql-compliance.md) (S0–S6).~~
3. ~~Post-S6 execute widening F0–F4~~ — complete; see [`sql-followon.md`](sql-followon.md).
