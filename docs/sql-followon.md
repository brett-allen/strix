# Plan: SQL Follow-on (post S1–S6)

Widen Strix’s executed SQL surface after the compliance program (S0–S6) on main: richer joins, composite primary keys, native types, and prepared-statement binding — still a **documented subset** with H2-ish clarity, no type affinity, and named extensions.

| | |
|---|---|
| **Branch** | `feature/sql-followon` (from main @ `427aaf1`) |
| **Depends on** | Compliance S0–S6 ([`sql-compliance.md`](sql-compliance.md)), dialect honesty ([`sql-dialect.md`](sql-dialect.md)), execute wiring ([`sql-execute.md`](sql-execute.md) E1–E6) |
| **Does not invent** | A second dialect — widen **execute** (and minimal parser/CLI) on the existing AST; name intentional extensions |

**Naming:** phases are **F0–F4** (“follow-on”), not S7+. S1–S6 remain the historical compliance arc; coverage inventories use `docs/sql-followon-fN-coverage.md`. Continuity with “S” would blur a finished program and a new product slice.

---

## Audience

| Reader | Use this doc to… |
|--------|------------------|
| Implementer | Start at [Prerequisites](#prerequisites--starting-state), then phase **F1** (after F0 freeze) |
| PM / lead | Track [Phased delivery](#phased-delivery); each phase is user-visible; coverage inventories gate exit |

**Rule for phases:** every phase ends with durable or user-visible semantic value. Scaffolding is an implementation detail inside the phase that needs it — never a standalone milestone.

---

## Prerequisites / starting state

Already landed (do not re-implement):

| Layer | Status | Notes |
|-------|--------|--------|
| `src/sql` | Parser v1 | Parses `LEFT OUTER`, `USING`, multi-`JOIN`, composite `PRIMARY KEY (…)`, `?` / `?N` placeholders, `CAST`, aggs/`GROUP BY` — many reject at bind/exec |
| `src/exec` | E1–E6 + **S1–S6** + **F1** | Left-deep `INNER`/`CROSS`/`LEFT OUTER`, N tables (`src/exec/join.odin`); single-column PK (IPK or unique index); multi-column **UNIQUE** already enforced; `UUID` type name stores as **Text**; no native `BOOLEAN`; placeholders → `Unsupported_Ast` in eval |
| Expression eval | S1–S6 + F1 | Strict bool; `CAST`; whole-query + grouped aggs; multi-table column bind / ambiguity for **N** `Join_Side`s |
| Catalog / rows | v2 tables, heap v1 | `Value_Kind`: Null / Integer / Float / Text / Blob; index keys already concatenate **N** tagged fields |
| CLI / shell | `strix sql` / `strix shell` | Literals only; no prepare/execute API |

**Honest surface today:** see [`sql-dialect.md`](sql-dialect.md) JOIN / PK / CAST sections. Follow-on changes **execute** (and docs); update that matrix as each F-phase lands.

**Standing decisions from compliance (not reopened by default):**

| Decision | Status |
|----------|--------|
| IPK = sole `INTEGER`/`INT PRIMARY KEY` aliases rowid | **(A)** stands — named extension |
| Internal rowid not exposed as SQL column | **stands** |
| No type affinity; `CAST` explicit | **stands** |
| Strict `GROUP BY` select list | **stands** |

---

## Goals

- Ship user-visible SQL that demos and apps actually need after S6: **LEFT OUTER**, **3+ tables**, **composite PK**, **BOOLEAN** and/or **typed UUID**, **prepared `?` binding**.
- Keep the compliance north star: typed columns matter, no affinity, clear reject/defer boundaries, named extensions.
- Incremental delivery with acceptance checkboxes, exit criteria, and **≥80%** coverage inventories per phase (same hard rule as execute / compliance).
- Prefer H2 / common standard-SQL clarity when unsure; document choices in [`sql-dialect.md`](sql-dialect.md).

## Non-goals

- Full SQL:20xx / H2 product parity; cost-based optimizer; concurrent sessions / network protocol.
- **`RIGHT` / `FULL` / `NATURAL` joins** — stay rejected this program.
- **`USING` clause** — default **defer** past F1 (use `ON`); list under open Q if a cheap stretch appears after LEFT + 3+.
- **`CASE`, `LIKE` / `GLOB` / `MATCH` / `REGEXP`** — still deferred (dialect already says so); not this program unless a later plan owns them.
- **Views, triggers, CTEs, set ops, windows, `CHECK` / FK enforcement, `ALTER` beyond current rejects, WAL** — non-goals.
- Migrating off IPK to IDENTITY/SERIAL **(B)** — out of scope unless PM reopens IPK.
- Rewriting the parser into a different grammar family.

**Later / residue (not a phase unless folded cheaply):**

| Item | Disposition |
|------|-------------|
| `SUM(i64)` overflow | Gate residue — Integer `SUM` currently uses unchecked `+=` (`src/exec/agg.odin`). Prefer **fail-closed** (`Unsupported_Ast` or typed overflow error) when touched; default: fold into F3 polish or a tiny follow PR, not a standalone F-phase |
| `USING` for joins | Defer; see open Q #4 |
| `CASE` / `LIKE` | Later program |

---

## North star principles

| Principle | Meaning for Strix |
|-----------|-------------------|
| **Typed columns matter** | Declared types guide bind/insert/compare/`CAST`; UUID/BOOLEAN are real kinds when introduced, not labels ignored at runtime. |
| **No type affinity** | No SQLite-style ambient coerce; illegal combinations error clearly. |
| **`CAST` is explicit** | New types join the documented cast matrix; invalid casts error (never NULL-by-affinity). |
| **Boolean context is strict** | Integers `0`/`≠0` remain; native `BOOLEAN` participates as true/false; Text/Blob still rejected in bool context. |
| **`PRIMARY KEY` = `UNIQUE` + `NOT NULL`** | Composite PK = unique composite index + NOT NULL on **all** PK columns; IPK shape unchanged under (A). |
| **rowid stays internal** | Heap btree key unchanged; do not expose `rowid` / `_rowid_` in this program. |
| **Joins: correctness first** | Nested-loop / left-deep plans; document caps; no planner fantasy. |

**Clarity bar:** when unsure, prefer H2 / common standard-SQL behavior over SQLite quirk parity, and document the choice in [`sql-dialect.md`](sql-dialect.md).

---

## Architecture (dependency sketch)

```text
  F1 JOIN widen ──► nested_loop + multi Join_Side + NULL-extend
         │
         │  (independent)
         ▼
  F2 composite PK ──► DDL bind + system unique index (multi-col path exists)
         │
         ▼
  F3 BOOLEAN / UUID ──► Value_Kind + heap/index tags + CAST + dialect
         │
         ▼
  F4 prepared ? ──► session bind API + eval Placeholder + CLI story
```

| Concern | Owner |
|---------|--------|
| LEFT / N-table join | `src/exec/join.odin` + select path + `Row_Env` sides |
| Composite PK | `src/exec/ddl.odin` / `dml_insert.odin` + existing `encode_index_key` N-col |
| BOOLEAN / UUID | `Value` / heap codec / index tags / `declared_storage_kind` / `CAST` / dialect |
| Prepared binding | `src/exec` session API + expr eval; CLI/shell surface |
| Dialect honesty | [`sql-dialect.md`](sql-dialect.md) matrix + this plan |

**Import rule unchanged:** `sql` ↛ `exec` / `engine`.

**Real dependencies (code today):**

| Area | Fact |
|------|------|
| Joins | **F1 landed:** `validate_select_joins` accepts N clauses + `.Left` with `ON`; rejects `using_cols`; left-deep `nested_loop_join_step` with NULL-extend for LEFT |
| Composite PK | Rejected in `bind_create_table_columns` / `validate_primary_key_shape`; **multi-column UNIQUE already works** (`test_multi_column_table_unique`) |
| UUID | Type name → Text in `declared_storage_kind` / `CAST … AS UUID` |
| BOOLEAN | Not a lexer keyword / not a `Value_Kind`; `CAST … AS BOOLEAN` errors |
| Placeholders | Lexer/parser store `Placeholder_Data{index}`; `eval_expr` / agg paths reject |

---

## Phased delivery

| Phase | Ships | Why this order |
|-------|-------|----------------|
| **F0** | Spec freeze + doc pointers | Lock principles before code churn |
| **F1** | LEFT OUTER + 3+ tables | Builds on S6 nested-loop; highest demo leverage |
| **F2** | Composite `PRIMARY KEY` | Builds on S3 unique indexes + existing multi-col UNIQUE encoding |
| **F3** | Native `BOOLEAN` + typed `UUID` | Touches parse/bind/eval/`CAST`/storage tags; after PK so PK demos can use typed UUID |
| **F4** | Prepared `?` binding | New exec/API/CLI surface; last so types/joins stabilize first |

**Adjustment note:** If F1 N-table work is large, ship **LEFT on two tables** first with the same coverage inventory, then 3+ in the same phase before exit — do not invent a separate “F1a” milestone. Do **not** pull F4 ahead of F3.

---

### Phase F0 — Spec freeze + doc pointers

- [x] This plan (`docs/sql-followon.md`)
- [x] Point [`sql-compliance.md`](sql-compliance.md) immediate next steps at this follow-on plan
- [x] Short pointers from [`sql-dialect.md`](sql-dialect.md) / [`sql-execute.md`](sql-execute.md) (no false “executed” claims)
- [x] PM/lead ack of open-question defaults (stand as written; F1 started)

**Exit:** Docs describe the target; implementers have a single living follow-on plan. **No code required for F0.**

**Coverage inventory:** none (docs only).

---

### Phase F1 — Join widening (`LEFT OUTER` + 3+ tables)

User-visible: outer joins and multi-table FROM lists runnable via CLI/shell.

**Defaults:**

| Topic | Default |
|-------|---------|
| LEFT OUTER | NULL-extend **right** side when no ON match; evaluate `ON` before `WHERE` (standard); unmatched left rows preserved |
| INNER / CROSS | Unchanged semantics; compose in a left-deep chain |
| 3+ tables | **Left-deep** nested loop over `stmt.joins[]`; document as correctness-first |
| Table / join cap | **Default: unbounded** in code with a **documented soft guidance** (e.g. demos ≤4 joins); optional hard cap only if PM confirms (open Q #3) |
| RIGHT / FULL / NATURAL | Still reject |
| `USING` | Still reject (open Q #4) |

Acceptance:

- [x] `LEFT [OUTER] JOIN` … `ON expr` (start: two tables) — NULL-pad right columns on no match; `ON` filters join matches; `WHERE` filters after join
- [x] Multiple `JOIN` clauses / 3+ tables: left-deep nested loop; column bind with N `Join_Side`s; ambiguous unqualified → `Unknown_Column` (same policy as S6)
- [x] Mix: `LEFT` + `INNER` + `CROSS` / comma-join in one FROM (document evaluation order: left-deep)
- [x] Aggs / `GROUP BY` / `HAVING` over widened join streams (regression + new cases)
- [x] Reject clearly: `RIGHT` / `FULL` / `NATURAL`; `USING` (until Q #4); unsupported join shapes
- [x] Update [`sql-dialect.md`](sql-dialect.md) JOIN section + executed matrix
- [x] Tests: equi LEFT preserving unmatched left; ON vs WHERE difference (NULL-extended row filtered by WHERE); 3-table chain; ambiguity; negatives with stable codes
- [x] Coverage inventory: [`sql-followon-f1-coverage.md`](sql-followon-f1-coverage.md) ≥80%

**Exit:** `SELECT … FROM a LEFT JOIN b ON …` and a 3-table join run end-to-end via CLI; dialect matrix honest.

**Reject / defer boundary:** no hash/merge join; no join reordering; no `USING` unless Q #4 flips; no RIGHT/FULL.

---

### Phase F2 — Composite `PRIMARY KEY`

User-visible: multi-column PK tables with fail-closed uniqueness and NOT NULL.

**Defaults:**

| Topic | Default |
|-------|---------|
| Enforcement | System unique secondary index on the PK column list (`strix_autoindex_<table>_<n>`) — same maintenance path as multi-column UNIQUE |
| NULL | Every PK column `NOT NULL`; NULL in any PK col → `Constraint` |
| IPK | Unchanged: sole `INTEGER`/`INT PRIMARY KEY` still rowid alias; **composite never aliases rowid** |
| Expose rowid | **No** |
| Column-level multi PK | Table constraint `PRIMARY KEY (a, b)` is the primary form; reject contradictory shapes clearly |

Acceptance:

- [ ] Accept table `PRIMARY KEY (c1, c2, …)` (≥2 columns); mark columns PK + NOT NULL; create/maintain composite unique system index
- [ ] Duplicate PK → `Constraint`; NULL in any PK column → `Constraint`
- [ ] INSERT / UPDATE / DELETE maintain the composite unique index (reuse `encode_index_key` N-col)
- [ ] IPK single-column path regression unchanged under (A)
- [ ] Reject ill-formed mixes (e.g. IPK + composite) with clear errors
- [ ] Update dialect PK shapes + [`storage-format.md`](storage-format.md) only if on-disk meta grows (likely **no** format bump — flags/index list already exist)
- [ ] Tests: create/insert/select/update/delete; duplicate; NULL PK col; reopen durable; IPK regression
- [ ] Coverage inventory: [`sql-followon-f2-coverage.md`](sql-followon-f2-coverage.md) ≥80%

**Exit:** `CREATE TABLE t (a TEXT, b TEXT, PRIMARY KEY (a, b));` works end-to-end via CLI; duplicates fail closed.

**Reject / defer boundary:** still no FK; no deferrable constraints; no expose rowid.

---

### Phase F3 — Native `BOOLEAN` + typed `UUID`

User-visible: declared `BOOLEAN` / `UUID` columns store and compare as real types; `CAST` matrix updated.

**Defaults (phased inside F3):**

| Topic | Default |
|-------|---------|
| Order | **BOOLEAN first**, then **UUID** (BOOLEAN touches bool context + literals; UUID needs validation + 16-byte storage) |
| BOOLEAN storage | Prefer a **native `Value_Kind.Boolean`** (and heap/index tag) if codec/catalog allow without huge churn; else document INTEGER 0/1 fallback (open Q #5) |
| BOOLEAN literals | `TRUE` / `FALSE` (lexer keywords or literal forms) bind to Boolean; in boolean context they are true/false |
| BOOLEAN ↔ Integer | No ambient affinity; use `CAST` for conversion (document pairs) |
| UUID storage | Prefer **typed 16-byte** value (new kind or distinguished Blob subtype — open Q #6) with canonical string I/O; reject malformed literals at bind/insert |
| UUID as TEXT today | Migrating: new tables with `UUID` type use typed storage; document that pre-F3 TEXT-stored “UUID” columns remain Text |
| `CAST … AS BOOLEAN` / `AS UUID` | Executed per documented matrix; invalid → clear error |

Acceptance:

- [ ] `BOOLEAN` recognized in INSERT/UPDATE kind checks; compare/bool-context rules documented + tested
- [ ] `TRUE` / `FALSE` usable in SQL where literals are expected (projection, WHERE, INSERT)
- [ ] `UUID` recognized as typed storage (not Text alias); insert/select round-trip; PK on UUID column works (single-column; composite if F2 landed)
- [ ] Malformed UUID literal / wrong kind → `Constraint` or `Unsupported_Ast` (stable, documented)
- [ ] `CAST` matrix + dialect sections updated; no affinity
- [ ] Index encode/decode tags for new kinds; reopen durable
- [ ] Optional polish: `SUM(i64)` overflow fail-closed if cheap in the same PR wave
- [ ] Tests + [`sql-followon-f3-coverage.md`](sql-followon-f3-coverage.md) ≥80%

**Exit:** Users can `CREATE TABLE t (ok BOOLEAN, id UUID PRIMARY KEY, …)` and round-trip via CLI without storing UUID as free-form Text.

**Reject / defer boundary:** no UUID version/variant gymnastics beyond parse/validate; no BOOLEAN three-valued beyond NULL; no SQLite affinity.

---

### Phase F4 — Prepared statements / `?` binding

User-visible: bind parameters once per execute; scripts/apps stop string-building literals for DML/SELECT.

**Defaults:**

| Topic | Default |
|-------|---------|
| API | **Session-level** prepare + execute (or bind-then-`exec_statement` with a param vector) on `Exec_Session` |
| Placeholder form | Positional `?` first (index 0-based as parser already stores); `?N` if cheap (parser already has N) |
| Scope | Bound values apply for that execution; clear ownership/free rules |
| CLI / shell | Documented story: e.g. shell bind helpers and/or `strix sql` flag/API for params — minimum: **programmatic/session API + tests**; shell UX can be thin if API is complete (open Q #7) |
| Types | Bound `Value`s subject to same declared-type kind checks as literals |

Acceptance:

- [ ] Eval of `Placeholder` reads from a session/execution bind table; unbound → clear error
- [ ] `?` works in SELECT/INSERT/UPDATE/DELETE WHERE/SET/VALUES (documented positions)
- [ ] Positional binding API with stable errors (arity mismatch, unbound, type/`Constraint`)
- [ ] `?N` supported if already parsed and cheap; else reject `?N` clearly until a stretch
- [ ] CLI and/or shell story documented and smoke-tested
- [ ] Update dialect “placeholders” + execute API sketch
- [ ] Tests + [`sql-followon-f4-coverage.md`](sql-followon-f4-coverage.md) ≥80%

**Exit:** A prepared/bound `INSERT`/`SELECT` runs via the session API without interpolating literals into SQL text.

**Reject / defer boundary:** no `PREPARE`/`EXECUTE` SQL statements required if the API is session-native (document as extension vs SQL-standard PREPARE); no named `:name` / `$name` params this phase unless free.

---

## Testing strategy

| Layer | Focus |
|-------|--------|
| `exec` unit | LEFT NULL-extend; N-table bind; composite PK; Boolean/UUID kinds; placeholder bind |
| Integration | Temp `.strix`; reopen durability for composite PK indexes + new value tags |
| Negatives | Stable `Exec_Error_Code`; no vacuous `has_error` |
| Regressions | S6 two-table INNER/CROSS; S3 IPK + TEXT PK; S4/S5 aggs; E5/E6 txn/fence |

**Hard rule:** each F1–F4 phase ships `docs/sql-followon-fN-coverage.md` with public/new symbol inventory and **≥80%** coverage by the inventory method (same spirit as [`sql-compliance-s6-coverage.md`](sql-compliance-s6-coverage.md) / [`exec-e2-coverage.md`](exec-e2-coverage.md)).

---

## Documentation deliverables

| Doc | Purpose |
|-----|---------|
| `docs/sql-followon.md` | This plan (living) |
| `docs/sql-dialect.md` | Executed matrix + JOIN/PK/types/placeholders updates per phase |
| `docs/sql-compliance.md` | Historical S0–S6; points here for post-S6 work |
| `docs/sql-execute.md` | Historical E1–E6 wiring; pointer to follow-on |
| `docs/storage-format.md` | On-disk changes if F3 tags / catalog need a bump |
| `docs/sql-followon-fN-coverage.md` | Per-phase coverage proof (F1–F4) |

---

## Definition of done (follow-on program)

Not a single ship gate — **each phase has its own exit**. Program-level success looks like:

- [x] F0 docs live; compliance/dialect/execute pointers updated
- [x] F1 landed → LEFT OUTER + 3+ table joins
- [ ] F2 landed → composite PRIMARY KEY
- [ ] F3 landed → native BOOLEAN + typed UUID (or documented fallback if Q #5/#6 flip)
- [ ] F4 landed → prepared `?` binding with session API + documented CLI/shell story
- [ ] Dialect matrix honest; extensions named; no affinity claims
- [ ] Coverage inventories ≥80% per implemented phase

---

## Open questions

Defaults stand unless overridden before/during the relevant phase:

1. **IPK:** keep extension **(A)** — **default: stands** (do not reopen in this program).
2. **Expose internal `rowid`?** — **default: no.**
3. **N-table join hard cap?** — **default: no hard cap**; document soft guidance for demos. Optional `MAX_JOIN_TABLES` only if PM wants fail-closed resource bounds.
4. **`USING` clause in F1?** — **default: defer** (keep reject; use `ON`). Stretch only if LEFT + 3+ exit early.
5. **BOOLEAN storage:** native `Value_Kind.Boolean` vs INTEGER 0/1 — **default: native Boolean** if heap/index tag bump is tractable; else INTEGER + document.
6. **UUID storage:** typed 16-byte vs TEXT + validation only — **default: typed** if format/catalog allow without huge churn; validation-on-TEXT is fallback.
7. **Prepared CLI/shell depth:** full `.param` / bind commands vs API-first + minimal CLI — **default: session API + tests first**; shell bind UX in the same phase if cheap.
8. **`?N` in F4:** — **default: support if cheap** (parser already stores N); else positional `?` only + clear reject for `?N`.
9. **`SUM(i64)` overflow fail-closed:** — **default: fold into F3 polish or a small gate PR**, not a named F-phase.
10. **SQL-standard `PREPARE`/`EXECUTE` text:** — **default: no**; session API is enough (named extension / library surface).

---

## Immediate next steps

1. ~~Land this plan + compliance/dialect/execute pointers (**F0**).~~
2. ~~Implement **F1** (LEFT OUTER + 3+ joins) with `sql-followon-f1-coverage.md`.~~
3. Confirm open Q defaults with PM (especially **BOOLEAN/UUID storage**, **join cap**, **prepared CLI depth**).
4. Then **F2** (composite PK) → **F3** (BOOLEAN + UUID) → **F4** (prepared `?`).
