# Plan: SQL Compliance Subset

Pivot Strix execute semantics from SQLite-shaped quirks toward a **SQL-compliant subset** (standard-SQL / H2-ish clarity): typed columns, explicit `CAST`, strict boolean context, and `PRIMARY KEY` as a real uniqueness constraint — without claiming full SQL:20xx or H2 product parity.

| | |
|---|---|
| **Branch** | `feature/sql-compliance` |
| **Depends on** | Execute v1 DoD ([`sql-execute.md`](sql-execute.md) E1–E6), dialect honesty ([`sql-dialect.md`](sql-dialect.md)), indexes ([`storage-format.md`](storage-format.md) index v2) |
| **Does not invent** | A second parser dialect — widen **execute** semantics; keep parser surface honest; name intentional extensions |

---

## Audience

| Reader | Use this doc to… |
|--------|------------------|
| Implementer | Start at [Prerequisites](#prerequisites--starting-state), then phase **S1** (after S0 freeze) |
| PM / lead | Track [Phased delivery](#phased-delivery); each phase is user-visible; coverage inventories gate exit |

**Rule for phases:** every phase ends with durable or user-visible semantic value. Scaffolding (helpers, index maintenance plumbing) is an implementation detail inside the phase that needs it — never a standalone milestone.

---

## Prerequisites / starting state

Already landed (do not re-implement):

| Layer | Status | Notes |
|-------|--------|--------|
| `src/sql` | Parser v1 | Parses `CAST`, `JOIN`, `GROUP BY`/`HAVING`, aggregates-as-calls, UNIQUE/PK constraints — many reject at bind/exec |
| `src/exec` | E1–E6 + **S3** | CRUD, indexes, scripts/txns; sole `INTEGER`/`INT` PK = IPK (rowid alias); TEXT/UUID-style single-column PK + UNIQUE via system unique indexes; rejects composite PK |
| Expression eval | E3 + **S1** + **S2** | Strict boolean context (Text/Blob rejected); Integer–Integer exact `i64`; mixed int/float via `f64`; Text/Blob↔numeric without `CAST` → error; scalar `CAST(expr AS type)` executed (S2) |
| Catalog / rows | v2 tables, heap codec | `columns[]` + `next_rowid`; btree key = internal rowid |
| CLI / shell | `strix sql` / `strix shell` | Batch + REPL; `.dot` meta-commands are **not** SQL |

**Honest surface today:** see [`sql-dialect.md`](sql-dialect.md) “Executed vs parsed only.” Compliance work changes **execute** rules; update that matrix as each S-phase lands.

---

## Goals

- Prefer **SQL compliance** over SQLite quirk-compatibility for execute semantics.
- Ship a **documented subset**: clear accept/reject rules, named extensions, no silent “affinity” surprises.
- Make **typed columns matter**: declared types guide bind/insert/compare/`CAST`; no SQLite-style type affinity.
- Treat **`PRIMARY KEY` as `UNIQUE` + `NOT NULL`** (index-backed), including **TEXT / UUID-style** single-column PKs — not only IPK/rowid alias.
- Keep **rowid** as the internal btree storage key regardless of logical PK type.
- Incremental delivery with acceptance checkboxes, exit criteria, and **≥80%** coverage inventories per phase (same hard rule as execute / shell).

## Non-goals

- Full SQL:20xx / SQL:2023 conformance, or claiming “standard SQL” without a subset boundary.
- H2 JDBC / product parity (MVCC modes, modes catalog, full function library, etc.).
- Query planner / cost-based optimizer beyond trivial plans.
- Concurrent sessions, WAL, network protocol.
- Prepared statements / `?` binding (still deferred unless a later plan owns it).
- Views, triggers, CTEs, set ops, window functions, `CHECK` / FK enforcement, `ALTER` beyond what execute already rejects.
- Rewriting the parser into a different grammar family — compliance is primarily **semantic**.

---

## North star principles

| Principle | Meaning for Strix |
|-----------|-------------------|
| **Typed columns matter** | Declared type names are meaningful at bind/insert/`CAST`/compare — not free-form labels ignored at runtime. |
| **No type affinity** | Do not coerce values into a column’s “affinity” on insert the SQLite way. Store what was bound (after explicit rules / `CAST`); reject illegal combinations clearly. |
| **`CAST` is explicit** | Type conversion happens via `CAST(expr AS type)` (and documented literal bind rules), not ambient affinity. |
| **Boolean context is strict** | `WHERE` / `AND` / `OR` / `NOT` accept only well-defined truth values (integers `0`/`≠0`, and later a real boolean if introduced). Non-NULL Text/Blob is **not** automatically TRUE. |
| **`PRIMARY KEY` = `UNIQUE` + `NOT NULL`** | Logical PK is a uniqueness constraint enforced via an index (unique index maintenance). Composite PK remains a later slice unless a phase explicitly takes it. |
| **rowid stays internal** | Every heap row still has a btree **rowid** key. Logical PK columns may or may not alias it. |

**Clarity bar:** when unsure, prefer H2 / common standard-SQL behavior over SQLite quirk parity, and document the choice in [`sql-dialect.md`](sql-dialect.md).

---

## Breaking changes vs today

SQLite-isms to **remove**, **tighten**, or **demote to a named extension**. Defaults below are the compliance target; phases own the cutover.

| Today (SQLite-ish) | Compliance target | Phase | Disposition |
|--------------------|-------------------|-------|-------------|
| Non-NULL Text/Blob is TRUE in `WHERE` / `AND` / `OR` / `NOT` | Reject Text/Blob in boolean context (`Unsupported_Ast` or typed error) | **S1** | **Remove** |
| Soft int↔float compare always via `f64` when either side is float | Keep exact `i64` for Integer–Integer; document mixed numeric policy (default: allow mixed numeric with `f64`, reject Text/Blob↔numeric without `CAST`) | **S1** | **Tighten** |
| “Affinity later” language in catalog / plans | Typed columns + explicit `CAST`; no affinity engine | **S0–S2** | **Remove** (doc + code path) |
| Sole `INTEGER`/`INT PRIMARY KEY` = only allowed PK; TEXT/composite rejected | TEXT/UUID-style PK via unique index; IPK remains optional **extension** | **S3** | **Widen** + name IPK |
| Decorative / non-enforced UNIQUE (parsed, not executed) | Enforce `UNIQUE` / PK with index maintenance | **S3** | **Implement** |
| `CAST` parsed, exec rejects | Scalar `CAST` executed | **S2** | **Implement** |
| `COUNT` / aggregates rejected | `COUNT(*)` then richer aggs | **S4** | **Implement** |
| `GROUP BY` / `HAVING` rejected | Whole-query then grouped aggs | **S5** | **Implement** |
| `JOIN` rejected | `INNER JOIN` first | **S6** | **Implement** |
| Bracket / backtick identifiers | Keep as **extension** (parser already accepts) | — | **Extension** |
| `IF NOT EXISTS` / `IF EXISTS` | Keep as **extension** | — | **Extension** |
| `.dot` shell commands | Not SQL — stay shell-only | — | **Extension** (non-SQL) |

Insert “soft coerce” of text literals into numeric columns without `CAST` — if any path exists or creeps in — is **out of policy**; S1/S2 tests must lock rejection or require explicit `CAST`.

---

## Named extensions

Intentional deviations from the compliance subset. Documented in dialect notes; not silent.

| Extension | Status | Notes |
|-----------|--------|--------|
| **IPK / rowid alias** | **Keep (default)** — see [IPK decision](#ipk-decision) | Sole column `INTEGER`/`INT PRIMARY KEY` aliases btree rowid; auto-allocate via `next_rowid`. Coexists with unique (non-IPK) PKs after S3. |
| **`IF NOT EXISTS` / `IF EXISTS`** | Keep | DDL convenience; widely expected. |
| **Bracket / backtick identifiers** | Keep (parser) | SQLite-compatible quoting; double-quoted idents remain the standard form. |
| **`.dot` shell meta-commands** | Keep | Not SQL; see [`cli-shell.md`](cli-shell.md). |
| **`INSERT OR REPLACE` / `OR IGNORE`** | Parsed only | Still reject at exec until a dedicated upsert plan. |
| **Implicit rowid always present** | Storage fact | Even with TEXT PK, rows have an internal rowid; not exposed as a SQL column unless we later add an extension (`rowid` / `_rowid_`) — **default: do not expose** in S3. |

---

## IPK decision

| Option | Summary |
|--------|---------|
| **(A) Keep IPK as documented extension** | Sole `INTEGER`/`INT PRIMARY KEY` continues to alias rowid. Non-integer PKs use unique indexes. Two PK shapes, clearly documented. |
| **(B) Migrate off IPK** | Later introduce `GENERATED … AS IDENTITY` / `SERIAL`-style and treat all PKs as unique indexes; deprecate rowid alias. |

**Default: (A).** Lowest disruption, matches current storage (`next_rowid` + rowid keys), and still unlocks TEXT/UUID PKs in S3.

**Open Q #1:** Confirm (A) vs schedule (B) after S3. Until then, implementers assume **(A)**.

---

## Architecture (semantic layers)

```text
  SQL text
     │
     ▼
  src/sql  (parse — largely unchanged)
     │
     ▼
  src/exec bind
     │  name resolve • type/constraint checks • reject unsupported
     ▼
  src/exec run
     │  eval (strict bool, CAST, aggs) • unique index maintain • joins
     ▼
  engine (catalog, btree, rowid keys, secondary indexes)
```

| Concern | Owner |
|---------|--------|
| Boolean / compare / `CAST` rules | `src/exec` expr eval + bind |
| UNIQUE / PK enforcement | `src/exec` + index APIs already used by E5 |
| Aggregates / `GROUP BY` / `JOIN` | `src/exec` query execution (new plans) |
| Dialect honesty | [`sql-dialect.md`](sql-dialect.md) matrix + this plan |

**Import rule unchanged:** `sql` ↛ `exec` / `engine`.

---

## Phased delivery

Suggested order and why:

| Phase | Ships | Why this order |
|-------|-------|----------------|
| **S0** | Spec freeze + doc north-star | Lock principles before code churn |
| **S1** | Semantic hygiene (bool, compare, idents) | Small, user-visible correctness; every later phase inherits strict eval |
| **S2** | Scalar `CAST` | Explicit conversion before richer DML/PK inserts need it |
| **S3** | `UNIQUE` + TEXT/UUID PK | Core product ask; needs indexes (E5) + clean types from S1/S2 |
| **S4** | Aggregates (`COUNT(*)` first) | Useful without grouping; foundation for S5 |
| **S5** | `GROUP BY` / `HAVING` | Builds on S4 aggregate eval |
| **S6** | `JOIN` (`INNER` first) | Independent of constraints; largest planner surface — last |

**Adjustment note:** If S3 unique-index work reveals that numeric index point-lookup must land first, fold a minimal “unique probe on insert” into S3 without pulling S6 forward. Do **not** delay S1/S2 for joins.

---

### Phase S0 — Spec freeze + doc north-star

- [x] This plan (`docs/sql-compliance.md`)
- [x] Reframe [`sql-dialect.md`](sql-dialect.md) opening: compliance subset + named extensions (not “SQLite-shaped dialect baseline”)
- [x] Pointer from [`sql-execute.md`](sql-execute.md) to this plan as the post-E6 semantic north star
- [ ] PM/lead ack of [IPK default (A)](#ipk-decision) and open-question defaults (can land during S1)

**Exit:** Docs describe the target; implementers have a single living plan. **No code required for S0.**

**Coverage inventory:** none (docs only).

---

### Phase S1 — Semantic hygiene

User-visible: predicates stop lying; type mismatches fail clearly.

- [x] Boolean context: Text/Blob (and other non-numeric non-null kinds) in `WHERE` / `AND` / `OR` / `NOT` → clear error; Integer `0` = false, `≠0` = true; NULL remains unknown (three-valued logic preserved for `AND`/`OR` short-circuit)
- [x] Comparison policy documented + tested: Integer–Integer exact; mixed int/float per north star; Text/Blob↔numeric without `CAST` → error; same-kind Text/Blob byte/lex compare unchanged
- [x] INSERT/UPDATE declared-type kind check: recognized types reject mismatched literal/expression kinds with `Constraint` (no soft coerce / affinity); empty/unknown type names store bound kind as-is
- [x] Identifier policy clarification in dialect (columns fold; tables/indexes case-sensitive) — ensure exec errors/messages match docs; no silent fold on table names
- [x] Update [`sql-dialect.md`](sql-dialect.md) executed matrix for boolean/compare/INSERT type behavior; scrub E3 Text-truthiness inventory
- [x] Tests: former Text-truthiness cases become negatives; numeric compare matrix; INSERT kind mismatch → `Constraint`; codes stable
- [x] Coverage inventory: [`sql-compliance-s1-coverage.md`](sql-compliance-s1-coverage.md) ≥80%

**Exit:** `WHERE 'x'` (bare text as predicate) errors; `WHERE 1` / `WHERE 0` behave; mixed illegal compares error without `CAST`; `INSERT INTO t (n) VALUES ('10')` into `n INT` → `Constraint`.

**Test expectations:** assert `Exec_Error_Code` + message class; regression that IPK CRUD still works.

---

### Phase S2 — Scalar `CAST`

- [x] Execute `CAST(expr AS type)` for a documented type-name set (minimum: `INTEGER`/`INT`, `REAL`/`FLOAT`/`DOUBLE`, `TEXT`/`VARCHAR`, `BLOB`; UUID-as-TEXT acceptable until a native UUID type exists)
- [x] Invalid casts → clear error (not NULL-by-affinity)
- [x] Use `CAST` in projection, `WHERE`, `SET` (same eval path)
- [x] Dialect + execute notes list supported cast pairs
- [x] Tests: happy paths + reject matrix; interaction with S1 compare rules
- [x] Coverage inventory: [`sql-compliance-s2-coverage.md`](sql-compliance-s2-coverage.md) ≥80%

**Exit:** Users can convert explicitly; no ambient affinity required for demos.

---

### Phase S3 — `UNIQUE` constraints + TEXT/UUID PK

- [x] Enforce column/table `UNIQUE` via unique secondary index (create on `CREATE TABLE` / `CREATE UNIQUE INDEX` as applicable; maintain on `INSERT`/`UPDATE`/`DELETE`)
- [x] Single-column `PRIMARY KEY` on non-IPK types (e.g. `TEXT`, `VARCHAR(…)`): imply `NOT NULL` + unique index; reject NULL PK values with `Constraint`
- [x] Duplicate PK/UNIQUE → `Constraint` (stable code)
- [x] IPK path **unchanged** under default (A); document both shapes in dialect
- [x] Reject or defer composite PK with clear error until a follow-on slice (default: **still reject composite** in S3)
- [x] Catalog/schema flags as needed; update [`storage-format.md`](storage-format.md) if on-disk meta grows
- [x] Tests: TEXT PK insert/select/update/delete; unique violation; IPK regression; reopen durable
- [x] Coverage inventory: [`sql-compliance-s3-coverage.md`](sql-compliance-s3-coverage.md) ≥80%

**Exit:** `CREATE TABLE t (id TEXT PRIMARY KEY, …); INSERT …;` works end-to-end via CLI; duplicates fail closed.

---

### Phase S4 — Aggregates

- [ ] `COUNT(*)` over whole query (no `GROUP BY`) — single-table first
- [ ] Then richer aggs as capacity allows: `COUNT(expr)`, `SUM` / `AVG` / `MIN` / `MAX` on numerics (document null-skipping per standard)
- [ ] Reject unsupported call forms clearly
- [ ] Projection rules: aggregate-only select without `GROUP BY` yields one row
- [ ] Tests + [`sql-compliance-s4-coverage.md`](sql-compliance-s4-coverage.md) ≥80%

**Exit:** `SELECT COUNT(*) FROM t` works; demo scripts can summarize tables.

---

### Phase S5 — `GROUP BY` / `HAVING`

- [ ] `GROUP BY` expressions (start: column refs) + aggregates from S4
- [ ] `HAVING` filter post-aggregate
- [ ] Reject `HAVING` without `GROUP BY` (already parser-adjacent); reject select-list columns not in group/agg per documented rule (default: **strict** — no SQLite “bare column” pick-any)
- [ ] Tests + [`sql-compliance-s5-coverage.md`](sql-compliance-s5-coverage.md) ≥80%

**Exit:** Grouped summaries work on a single table.

---

### Phase S6 — `JOIN` (INNER first)

- [ ] `INNER JOIN` … `ON expr` (two tables); column binding with optional aliases / `t.col`
- [ ] `CROSS JOIN` / comma-join if already parsed — only if same pipeline is cheap; else reject clearly until follow-on
- [ ] Defer `LEFT OUTER` unless trivial once INNER is solid (default: **INNER only** in S6)
- [ ] Tests: equi-join filter; unknown column; ambiguous column errors
- [ ] Coverage inventory: [`sql-compliance-s6-coverage.md`](sql-compliance-s6-coverage.md) ≥80%
- [ ] Update dialect “Executed vs parsed only” for joins

**Exit:** Two-table inner joins runnable via CLI/shell.

---

## Testing strategy

| Layer | Focus |
|-------|--------|
| `exec` unit | Bool/compare/`CAST`; unique/PK constraints; agg/group/join plans |
| Integration | Temp `.strix`; reopen durability for UNIQUE/PK indexes |
| Negatives | Stable `Exec_Error_Code`; no vacuous `has_error` |
| Regressions | IPK CRUD, E5 index maintain, E6 txn/fence behavior unchanged unless a phase explicitly changes them |

**Hard rule:** each S1–S6 phase ships `docs/sql-compliance-sN-coverage.md` with public/new symbol inventory and **≥80%** coverage by the inventory method (same spirit as [`exec-e2-coverage.md`](exec-e2-coverage.md) / shell C-inventories).

---

## Documentation deliverables

| Doc | Purpose |
|-----|---------|
| `docs/sql-compliance.md` | This plan (living) |
| `docs/sql-dialect.md` | North-star framing + executed matrix updates per phase |
| `docs/sql-execute.md` | Historical execute plan; pointer to compliance for post-E6 semantics |
| `docs/storage-format.md` | On-disk changes if S3+ needs catalog flags |
| `docs/sql-compliance-sN-coverage.md` | Per-phase coverage proof (S1–S6) |

---

## Definition of done (compliance program)

Not a single ship gate — **each phase has its own exit**. Program-level success looks like:

- [ ] S0 docs live; dialect/execute framing updated
- [ ] S1–S3 landed → TEXT/UUID PK + strict eval + `CAST` (minimum product arc)
- [ ] S4–S6 landed → aggregates, groups, inner joins (query arc)
- [ ] Dialect matrix honest; extensions named; no affinity claims
- [ ] Coverage inventories ≥80% per implemented phase

---

## Open questions

Defaults stand unless overridden before/during the relevant phase:

1. **IPK:** keep as extension **(A)** vs migrate to IDENTITY/SERIAL **(B)** — **default (A).**
2. **Composite `PRIMARY KEY`:** defer past S3 — **default: reject until a follow-on phase.**
3. **Expose internal `rowid` as SQL column?** — **default: no** in S3–S6.
4. **Mixed int/float compare:** allow via `f64` — **default: yes** (document); Text↔numeric requires `CAST`.
5. **Boolean type:** native `BOOLEAN` / `TRUE`/`FALSE` literals — **default: defer**; integers only in boolean context for S1.
6. **`LEFT OUTER JOIN`:** — **default: after INNER** (post-S6 or S6 stretch only if INNER exits early).
7. **Strict `GROUP BY` select list** (no SQLite bare columns) — **default: strict.**
8. **UUID:** native type vs `TEXT` + app convention — **default: `TEXT` PK** until a typed UUID lands.
9. **Unique index naming for implicit PK/UNIQUE:** system-generated names vs require user indexes only — **default: auto-create system unique indexes** for PK/UNIQUE constraints at `CREATE TABLE`.

---

## Immediate next steps

1. ~~Land this plan + dialect/execute framing (S0)~~ — this PR/branch docs work.
2. Confirm open Q defaults with PM (especially **IPK = A**).
3. ~~Implement **S1** (boolean + compare hygiene) with `sql-compliance-s1-coverage.md`.~~
4. ~~Implement **S2** (`CAST`) with `sql-compliance-s2-coverage.md`.~~
5. ~~Implement **S3** (UNIQUE + TEXT PK) with `sql-compliance-s3-coverage.md`.~~
6. Next: **S4** (`COUNT(*)` / aggregates).
