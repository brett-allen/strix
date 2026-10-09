# SQL Dialect Notes (Strix)

**North star:** a **SQL-compliant subset** (standard-SQL / H2-ish clarity) plus **named extensions** — not full SQL:20xx and not “SQLite quirk parity.” Typed columns matter; no type affinity; `CAST` is explicit; boolean context is strict; `PRIMARY KEY` means `UNIQUE` + `NOT NULL` (index-backed). Internal **rowid** remains the storage key.

Execute semantics migrate under [`sql-compliance.md`](sql-compliance.md) (phases S0–S6). Parser surface may still accept forms the executor rejects until those phases land. Intentional deviations (IPK/rowid alias, `IF NOT EXISTS`, bracket/backtick idents, shell `.commands`) are **named extensions**, not the baseline.

Historical note: early execute (E1–E6) followed SQLite-shaped shortcuts (Text truthiness, IPK-only PK). **S1** removed Text/Blob truthiness and tightened compares; **S2** executes scalar `CAST`; **S3** enforces `UNIQUE` / non-IPK `PRIMARY KEY` via unique secondary indexes; **S4** executes whole-query aggregates (`COUNT`/`SUM`/`AVG`/`MIN`/`MAX`); **S5** executes single-table `GROUP BY` / `HAVING`; **S6** executes two-table `INNER` / `CROSS` joins. Compliance program query arc complete through S6. **F1** widens joins to `LEFT OUTER` and 3+ tables; **F2** executes composite `PRIMARY KEY`; **F3** adds native `BOOLEAN` + typed `UUID`; **F4** adds session-level prepared `?` / `?N` binding.

**Follow-on F0–F4 complete** — see [`sql-followon.md`](sql-followon.md).

## Supported statements (parser v1 / Phase 5)

| Kind | Forms |
|------|--------|
| DDL | `CREATE`/`DROP TABLE`, `CREATE`/`DROP INDEX`, `ALTER TABLE ADD COLUMN` |
| DML read | `SELECT` with joins, `WHERE`, `GROUP BY`/`HAVING`, `ORDER BY`, `LIMIT`/`OFFSET` |
| DML write | `INSERT` (`VALUES` / `SELECT`; `OR REPLACE`/`OR IGNORE` **parsed only**), `UPDATE`, `DELETE` |
| Txn | `BEGIN` / `COMMIT` / `ROLLBACK` (`[TRANSACTION]` optional) |
| Scripts | Semicolon-separated via `parse_script` |

## Phase 0 — Tokenization

### Identifiers

| Form | Example | Notes |
|------|---------|--------|
| Unquoted | `users`, `_id` | ASCII letters, digits, `_` |
| Double-quoted | `"Weird Name"` | `""` escape |
| Backtick | `` `tbl` `` | doubled backtick escape |
| Bracket | `[col]` | SQLite-compatible |

Keywords are case-insensitive; quoted forms are always `Ident`. Unicode unquoted idents not supported yet.

**Execute bind policy:**
- **Columns** (and IPK type names): case-insensitive `equal_fold` at bind (CREATE duplicate/PK matching, INSERT column lists, SELECT/UPDATE SET/WHERE, index column bind). Case-only duplicate column names at `CREATE TABLE` are rejected (`Invalid_Schema`).
- **Tables / indexes:** catalog keys are **case-sensitive** (exact match on the name as stored). `Users` and `users` are distinct; wrong-case `FROM` / `DROP INDEX` → `Unknown_Table` / `Unknown_Index` (no silent fold). Docs must not claim fold “everywhere.”

### Boolean context & comparisons (execute / S1 + F3)

| Rule | Behavior |
|------|----------|
| Boolean (`WHERE` / `AND` / `OR` / `NOT`) | Integer/Float: `0` = false, `≠0` = true. Native `BOOLEAN`: `TRUE`/`FALSE`. NULL = unknown (3VL preserved; short-circuit may skip the other side). Text/Blob/Uuid → `Unsupported_Ast`. |
| Literals `TRUE` / `FALSE` | Lexer keywords → `Value_Kind.Boolean`; usable in projection, `WHERE`, `INSERT`/`UPDATE`, `DEFAULT` |
| Integer–Integer compare | Exact `i64` (not via `f64`) |
| Mixed int/float compare | Allowed via `f64` (north-star default; documented) |
| Boolean–Boolean | `false` < `true` (0/1) |
| Uuid–Uuid | Byte compare of 16-byte values |
| Uuid ↔ Text | Text parsed as UUID string form (8-4-4-4-12 or 32 hex); invalid → `Unsupported_Ast` |
| Text/Blob ↔ numeric; Boolean ↔ Integer | Error without `CAST` (`Unsupported_Ast`) — no affinity |
| Same-kind Text/Blob | Byte/lex compare unchanged |

### INSERT / UPDATE declared-type kinds (execute / S1 + F3)

| Rule | Behavior |
|------|----------|
| Recognized types | Bound value kind must match: `INT`/`INTEGER` → Integer; `REAL`/`FLOAT`/`DOUBLE` → Float; `TEXT`/`VARCHAR`/`CHAR`/`CHARACTER`/`CLOB`/`NVARCHAR` → Text; `BLOB` → Blob; `BOOLEAN`/`BOOL` → Boolean; `UUID` → Uuid (16 bytes). Parameters (e.g. `VARCHAR(10)`) ignored for matching. |
| UUID string bind | A Text string literal into a `UUID` column is **validated and stored as typed Uuid** (canonical lowercase on display). Malformed → `Constraint`. This is typed-column bind, not ambient affinity (other types still reject wrong kinds). |
| Mismatch | `Constraint` (e.g. `INSERT INTO t (n) VALUES ('10')` into `n INT`; `INSERT INTO t (ok) VALUES (1)` into `ok BOOLEAN`) — use `CAST` for conversions |
| NULL | Allowed unless `NOT NULL` |
| Empty / unknown type name | Store bound kind as-is (no check until a recognized name) |
| `UPDATE SET` | Same kind check on assigned values |
| Pre-F3 UUID-as-Text | Tables created before F3 that declared `UUID` but stored Text heap tags remain Text on disk; new `UUID` columns use typed storage |

### PRIMARY KEY shapes (execute / S3 + F2)

| Shape | Behavior |
|-------|----------|
| **IPK (extension)** | Sole column `INTEGER`/`INT PRIMARY KEY` aliases btree rowid; omit/`NULL` auto-allocates via `next_rowid`. No system unique index on the IPK column. |
| **Non-IPK PK** | Single-column PK on other types (`TEXT`, `VARCHAR(…)`, `UUID`, `REAL`, …) → implied `NOT NULL` + system unique index `strix_autoindex_<table>_<n>`. NULL / duplicate → `Constraint`. |
| **Composite PK (F2)** | Table `PRIMARY KEY (c1, c2, …)` (≥2 cols) → `NOT NULL` on every PK column + composite unique system index `strix_autoindex_<table>_<n>`. Duplicate pair / NULL in any PK col → `Constraint`. **Never** aliases rowid (even if all PK cols are `INTEGER`). |
| **Internal rowid** | Always present as the heap btree key; **not** exposed as a SQL column. |

Ill-formed mixes (e.g. column-level IPK plus a different table `PRIMARY KEY (…)`, or multiple table `PRIMARY KEY` constraints) → `Invalid_Schema`. Prefer the table-constraint form for composite keys.

`UNIQUE` (column or table) and `CREATE UNIQUE INDEX` use the same unique-index maintenance path. Nullable UNIQUE columns allow multiple NULLs.

### Scalar `CAST` (execute / S2 + F3)

`CAST(expr AS type)` is the **only** conversion path (no type affinity). Same `eval_expr` path as projection / `WHERE` / `SET`. NULL → NULL. Invalid casts → `Unsupported_Ast` (never NULL-by-affinity).

**Target type names** (parameters stripped, case-insensitive): `INTEGER`/`INT`; `REAL`/`FLOAT`/`DOUBLE`; `TEXT`/`VARCHAR`/`CHAR`/`CHARACTER`/`CLOB`/`NVARCHAR`; `BLOB`; `BOOLEAN`/`BOOL`; `UUID` (typed 16-byte). Unknown names → error.

| From → To | INTEGER | REAL | TEXT | BLOB | BOOLEAN | UUID |
|-----------|---------|------|------|------|---------|------|
| NULL | NULL | NULL | NULL | NULL | NULL | NULL |
| Integer | identity | `f64` | decimal string | **reject** | `≠0`→TRUE | **reject** |
| Float | truncate toward 0 (finite, in `i64` range) | identity | `%g` string | **reject** | `≠0`→TRUE | **reject** |
| Text | strict decimal\* | full `f64` parse (trim) | identity | UTF-8 bytes | `TRUE`/`FALSE` only | parse UUID† |
| Blob | **reject** | **reject** | bytes as UTF-8 text | identity | **reject** | exactly 16 bytes |
| Boolean | 0/1 | 0.0/1.0 | `TRUE`/`FALSE` | **reject** | identity | **reject** |
| Uuid | **reject** | **reject** | canonical 8-4-4-4-12 | 16 raw bytes | **reject** | identity |

\* **Text → INTEGER:** trim surrounding whitespace; optional leading `+`/`-`; remaining must be **decimal digits only**. Reject empty, fractional (`'10.5'`), hex (`'0x10'`), underscores, trailing garbage (`'10x'`), or digits that do not fit in `i64` (no silent wrap; same `Unsupported_Ast` / out-of-range honesty as Float→INTEGER). Use `CAST(… AS REAL)` then `CAST(… AS INTEGER)` if you need float-then-truncate from text.

† **Text → UUID:** accept hyphenated 8-4-4-4-12 (any hex case) or 32 hex digits; store 16 bytes; display lowercase hyphenated.

### Aggregates (execute / S4)

Whole-query aggregates on a **single table** without `GROUP BY`. `WHERE` filters rows **before** aggregation. An aggregate-only select list (aggregates and/or constants; no bare columns) yields **exactly one row**, including on an empty table.

| Function | Behavior |
|----------|----------|
| `COUNT(*)` | Counts all filtered rows (including rows with NULLs elsewhere) |
| `COUNT(expr)` | Counts non-NULL `expr` values (null-skipping) |
| `SUM(expr)` | Numeric sum; null-skipping; empty/all-NULL → `NULL`; Integer until a Float appears; **i64 overflow → `Unsupported_Ast`** (fail-closed, F3) |

Scalar integer `+` / `-` / `*` / unary `-` (and `min(i64)/-1`) are likewise **fail-closed** (`Unsupported_Ast`); no silent wrap. IPK / implicit `next_rowid` auto-alloc refuses past `max(i64)` (`Constraint`).
| `AVG(expr)` | Numeric average; null-skipping; **always Float** (integers promote); empty/all-NULL → `NULL` |
| `MIN(expr)` / `MAX(expr)` | Numeric only (S4); null-skipping; empty/all-NULL → `NULL` |

**Rejected** (`Unsupported_Ast`): mix of aggregates with non-aggregate columns without `GROUP BY` (strict); nested aggregates; `SUM(*)` / `AVG(*)` / `MIN(*)` / `MAX(*)`; bad arity; non-numeric `SUM`/`AVG`/`MIN`/`MAX`; non-aggregate function calls (`abs`, …); aggregates in `WHERE`; `ORDER BY` bare columns (or aggregates) with whole-query agg; `DISTINCT` inside agg (not parsed as such); `FILTER` / ordered-set aggs (not parsed).

### GROUP BY / HAVING (execute / S5)

Single-table grouped aggregates. `WHERE` filters **before** grouping; `HAVING` filters **after** per-group aggregation.

| Rule | Behavior |
|------|----------|
| `GROUP BY` items | **Column references only** (e.g. `region`, `t.region`). Arbitrary expressions → `Unsupported_Ast` |
| Select list | **Strict:** every bare column must be a `GROUP BY` column (or appear only inside an aggregate). No SQLite “pick any” bare column. `SELECT *` with `GROUP BY` → `Unsupported_Ast` |
| Empty input | **Zero result rows** (no groups). Contrast whole-query agg (S4), which still yields one row |
| `HAVING` | Post-aggregate boolean; may use aggregates and/or group keys. Parser rejects `HAVING` without `GROUP BY` |
| `ORDER BY` | Group keys and/or aggregates allowed; other bare columns → `Unsupported_Ast`. Select-list aliases in `ORDER BY` are **not** resolved (use the aggregate/key expression again) |
| NULL keys | All-NULL group keys form one group (NULL equals NULL for grouping) |

Keys-only `GROUP BY` (no aggregates in the select list) is supported (distinct groups).

### JOIN (execute / S6 + F1)

**Left-deep nested-loop** joins (correctness over clever plans; no join reordering). Each `JOIN` clause is applied in written order; `ON` is evaluated at that join step; `WHERE` applies after the full join chain. Soft guidance for demos: keep to roughly ≤4 joins (no hard cap in code).

| Form | Executed? | Notes |
|------|-----------|-------|
| `INNER JOIN` … `ON expr` / `JOIN` … `ON expr` | **yes** | Required `ON`; equi-join and general boolean `ON` |
| `CROSS JOIN` / comma-join (`FROM a, b`) | **yes** | Cartesian product; filter with `WHERE` |
| `LEFT [OUTER] JOIN` … `ON expr` | **yes (F1)** | NULL-extends **right** columns when no `ON` match; unmatched left rows preserved |
| Multiple `JOIN` clauses / 3+ tables | **yes (F1)** | Left-deep composition; mix `LEFT` + `INNER` + `CROSS` / comma-join |
| `JOIN` … `USING (…)` | **no** | `Unsupported_Ast` (use `ON`; deferred past F1) |
| `RIGHT` / `FULL` / `NATURAL` | **no** | Parse `Unsupported_Syntax` → exec `Parse` |

**Column binding:** optional table aliases and `t.col` / `alias.col` qualifiers across **N** `Join_Side`s. Unqualified names that appear in more than one input → `Unknown_Column` with message `ambiguous column: …`. Unknown names / qualifiers → `Unknown_Column`. Duplicate exposed aliases → `Invalid_Schema`.

**With aggregates / `GROUP BY`:** joined row stream feeds the S4/S5 path (whole-query agg and grouped agg over widened joins are supported).

**Not used on join queries:** single-table index point-lookup (all sides seq-scanned).

### Literals & comments

- Strings: `'…'` with `''` escape; unterminated strings are lexer errors
- Blob: `X'hex'` / `x'hex'` — hex length must be **even**; odd length is a lexer error
- Numbers: int, float, hex `0x…`
- Comments: `--` line; `/* */` block — **unterminated `/*` is a lexer error** (not silently absorbed)
- Placeholders (F4 executed): bare `?` auto-assigns 0, 1, 2, … left-to-right **per statement**; `?N` uses explicit index N (including `?0`) and advances the auto counter past N when needed. `?N` outside `0..65535` or digit overflow → parse error (`Invalid_Number`). `print_expr` always emits `?N` (including `?0`) so print/reparse preserves indices. Bound via session API — see [Prepared parameters](#prepared-parameters-execute--f4)

### Keyword policy (expressions)

Keywords stay hard-reserved in the lexer. Expression specials:

| Form | Behavior |
|------|----------|
| `CAST(… AS type)` | Parsed; **executed (S2)** — see [Scalar CAST](#scalar-cast-execute--s2) |
| `CURRENT_DATE` / `CURRENT_TIME` / `CURRENT_TIMESTAMP` | Parsed as zero-arg calls |
| `REPLACE(…)` | Parsed as a function call when `(` follows |
| `LIKE` / `GLOB` / `MATCH` / `REGEXP` / `ISNULL` / `NOTNULL` | Clear “not supported yet” errors (no silent leftover tokens) |

## Phase 1 — Expressions

Precedence (high → low): unary `+`/`-`/`NOT` → `*`/`/`/`%` → `+`/`-` → `||` → comparisons → `IS [NOT] NULL` / `[NOT] IN` / `[NOT] BETWEEN` → `AND` → `OR`.

Still deferred: full `LIKE` semantics, `CASE`, bitwise ops, subqueries as expressions.

## Phase 2–4 — DDL / DML (summary)

- Column constraints: `PRIMARY KEY`, `NOT NULL`, `UNIQUE`, `DEFAULT expr`, `CHECK (expr)`, `REFERENCES t[(cols)]`
- Table constraints: `PRIMARY KEY (…)`, `UNIQUE (…)`, `CHECK (…)`, `FOREIGN KEY (…) REFERENCES …`
- Optional `CONSTRAINT name` **must** be followed by a real constraint body; bare `CONSTRAINT name` is a parse error
- Type-name parameters (e.g. `VARCHAR(10)`, `DECIMAL(10,2)`): inside `(…)` only signed numbers and commas are allowed; constraint keywords / other tokens error; unclosed `(` errors
- Name lists and `VALUES` rows require **≥1** element (`PRIMARY KEY ()`, `USING ()`, `VALUES ()` rejected)
- `INSERT`/`UPDATE`/`DELETE` as in Phase 4; `INSERT … DEFAULT VALUES` and `ON CONFLICT` upsert rejected

## Phase 3–5 — SELECT

```sql
SELECT [DISTINCT|ALL] select_item [, …]
FROM table [AS alias]
  { JOIN | INNER JOIN | LEFT [OUTER] JOIN | CROSS JOIN } table [AS alias] { ON expr | USING (cols) }
  | , table   -- treated as CROSS JOIN
[WHERE expr]
[GROUP BY expr [, …] [HAVING expr]]
[ORDER BY expr [ASC|DESC] [, …]]
[LIMIT expr [OFFSET expr]]
```

Projection: `*`, `t.*`, `expr [AS alias | alias]`. `FROM` required. **ORDER BY DESC** is executed (in-memory sort). Index-column `DESC` is catalog-only (see execute matrix).

### Explicitly rejected (clear error, no hang)

- `RIGHT` / `FULL` / `NATURAL` joins
- `HAVING` without `GROUP BY`
- `LIMIT offset, count`
- `UNION` / `INTERSECT` / `EXCEPT`
- CTEs (`WITH`), window functions, `ON CONFLICT` upsert
- `ALTER` forms other than `ADD [COLUMN]`
- Triggers, views, `PRAGMA`, FROM subqueries

## AST field naming

Odin keywords force `is_distinct` and `where_expr` on `Select_Stmt` (not `distinct` / `where`).

## API

```odin
tokenize / parse_expr / parse_statement / parse_script
print_statement / print_script / print_expr
free_expr / free_statement / free_script / free_error
```

### String ownership

- `Token.text` aliases `src` (lexer only).
- AST strings are **cloned** into the parse allocator; free via `free_*`. `src` need not outlive a successful parse.
- Quoted idents in the AST are normalized (no delimiters). See `docs/sql-ast.md`.

### `parse_script` errors

On the first statement error, successfully parsed prior statements are returned in `Script`, tokens are synchronized to the next `;`, and the `Parse_Error` is returned. Always `free_script` even when `has_error` is true. Statements after the failure are not parsed in this version.

### `Parse_Error`

Includes `code` (`Parse_Error_Code`), span (offset/length + 1-based line/column), and message.

| Code | Typical cause |
|------|----------------|
| `Unexpected_Token` | Wrong token / default parser mismatch |
| `Unexpected_EOF` | Hit EOF while expecting more |
| `Trailing_Token` | Extra tokens after a complete statement/expr |
| `Unterminated_String` | Unclosed `'…'` or blob quotes |
| `Unterminated_Comment` | Unclosed `/*` |
| `Unterminated_Ident` | Unclosed `"…"` / `` `…` `` / `[…]` |
| `Invalid_Blob` | Odd-length hex / bad blob chars |
| `Invalid_Number` | Bad hex / float exponent |
| `Invalid_Type_Name` | Bad / unclosed type-name parameters |
| `Empty_List` | `()`, empty `IN` / name / `VALUES` lists |
| `Unsupported_Syntax` | Known deferred forms (`LIKE`, `UNION`, …) |
| `Expected_Statement` | Empty input where a statement was required |

## Prepared parameters (execute — F4)

**Named extension / library surface** (not SQL-standard `PREPARE`/`EXECUTE` text).

| Topic | Behavior |
|-------|----------|
| Forms | Positional `?` (auto 0-based per statement) and `?N` (explicit). No `:name` / `$name`. |
| API | `session_bind` / `session_bind_all` / `session_clear_binds` on `Exec_Session`; one-shot `exec_statement_params(s, sql, params)` |
| Ownership | Session **clones** each bound `Value`; caller keeps theirs. `exec_statement_params` clears binds after the statement. Plain `session_bind` + `exec_statement` keeps binds until clear / rebind / `session_close`. |
| Positions | `INSERT` VALUES; `SELECT` projection / WHERE / JOIN ON / HAVING / LIMIT/OFFSET exprs; `UPDATE` SET + WHERE; `DELETE` WHERE. Not: DDL `DEFAULT`, SQL `PREPARE` text. |
| Types | Same declared-column kind checks as literals (`Constraint` on mismatch). |
| Arity | `exec_statement_params` requires a **dense** `params` slice of length `max_index + 1` (indices `0..max`). A sole `?2` still needs **three** values (slots 0 and 1 are bound but unused). Gaps are rejected (`Invalid_Schema`). Prefer bare `?` / contiguous `?0`…`?N` with this API; for sparse explicit indices use `session_bind` per slot + `exec_statement` (no dense pre-check; unbound slots still fail at eval). |
| Errors | Unbound → `Invalid_Schema` (`unbound parameter ?N`); arity mismatch on `exec_statement_params` → `Invalid_Schema`; type → `Constraint`. |
| CLI / shell | Batch `strix sql` and interactive shell accept **literals in SQL text only**. Bind from Odin via the session API (tests: `src/test/exec/bind_test.odin`). Shell `.param` / `--bind` deferred. |

## Fixtures & goldens

- `.sql` fixtures: `bootstrap.sql`, `bootstrap_v1.sql`, `crud.sql`, `phase5.sql`
- Sibling `.ast` goldens from `print_script` (trailing newlines normalized)
- Regenerate: `odin run tools/regen_ast_goldens`

## Executed vs parsed only

Parser v1 accepts a wider surface than the executor runs. **Execute support** lives in [`sql-execute.md`](sql-execute.md) / `src/exec` (phases **E1–E4** minimum; **E5** indexes + **E6** script/txn polish landed).

| Area | Parsed (today) | Executed |
|------|----------------|----------|
| `CREATE`/`DROP TABLE` | yes | **yes (E1/E2 + S3 + F2 + F3)** — `NOT NULL`; literal/`NULL`/`TRUE`/`FALSE` `DEFAULT`; **PK shapes:** (A) sole `INTEGER`/`INT PRIMARY KEY` = IPK/rowid alias (named extension); (B) single-column non-IPK PK (`TEXT`/`VARCHAR`/`UUID`/…) = `NOT NULL` + system unique index; (C) **composite** `PRIMARY KEY (c1, c2, …)` = `NOT NULL` on all PK cols + composite unique system index (never rowid alias); column/table `UNIQUE` → system unique indexes; `BOOLEAN`/`UUID` column types (F3); `DROP TABLE` auto-drops system autoindexes (user indexes still block); `IF NOT EXISTS` / `IF EXISTS`; rejects conflicting PK mixes; CHECK/FK still unsupported |
| `INSERT` … `VALUES` | yes | **yes (E2 + S1 + S3 + F3 + F4)** — multi-row (one txn; mid-statement failure rolls back in auto-commit); optional column list; IPK rowid alias for sole `INTEGER`/`INT` PK; non-IPK PK / UNIQUE duplicates → `Constraint`; NULL PK → `Constraint`; UNIQUE allows multiple NULLs; **declared-type kind check (S1/F3):** recognized types include `BOOLEAN`→Boolean and `UUID`→Uuid (string→Uuid bind for UUID cols); mismatch → `Constraint` (no soft coerce / affinity); empty/unknown type names store the bound kind as-is; **`?` / `?N` in VALUES (F4)** via session bind; rejects `INSERT…SELECT` / `OR REPLACE`/`OR IGNORE` / `DEFAULT VALUES`; maintains secondary indexes (E5/S3) |
| `SELECT` (single-table + N-table join) | yes | **yes (E3 + S1 + S2 + S4 + S5 + S6 + F1 + F3 + F4)** — `*` / columns / simple exprs; FROM + optional alias; WHERE (literals incl. **`TRUE`/`FALSE`**, cols, comparisons, AND/OR/NOT, arith, `IS NULL`, `IN` list, **`CAST` (S2/F3)**, **`?` params (F4)**); **strict boolean context (S1/F3):** Integer/Float/`BOOLEAN`; NULL unknown (3VL for AND/OR); Text/Blob/Uuid in bool context → `Unsupported_Ast`; **compare** includes Boolean–Boolean and Uuid (+ UUID string form); **`CAST`** matrix includes BOOLEAN/UUID — see [Scalar CAST](#scalar-cast-execute--s2--f3); **whole-query aggregates (S4):** `COUNT(*)` / `COUNT(expr)` / `SUM` / `AVG` / `MIN` / `MAX` (numerics; null-skipping except `COUNT(*)`; **SUM i64 overflow fail-closed**) without `GROUP BY` → one result row — see [Aggregates](#aggregates-execute--s4); **`GROUP BY` / `HAVING` (S5):** column-ref keys; strict select list; HAVING post-agg; empty groups → 0 rows — see [GROUP BY / HAVING](#group-by--having-execute--s5); **`JOIN` (S6 + F1):** left-deep nested-loop `INNER` / `CROSS` / comma-join / **`LEFT [OUTER] JOIN` … `ON`**; 3+ tables; qualified names / aliases; ambiguous unqualified → `Unknown_Column`; aggs/`GROUP BY`/`HAVING` over joins supported; rejects `USING`, `RIGHT`/`FULL`/`NATURAL` — see [JOIN](#join-execute--s6--f1); ORDER BY / LIMIT / OFFSET (in-memory; group keys/aggs with GROUP BY; incompatible ORDER BY kinds → error); rejects DISTINCT / BETWEEN / subqueries with `Unsupported_Ast`; CLI aligned text table; optional index point lookup for **text/blob/uuid** `WHERE col = const` only on **single-table** selects (E5; numeric eq stays on seq scan; joins always seq-scan all sides) |
| `UPDATE` / `DELETE` | yes | **yes (E4/E5 + S1 + S2 + F4)** — seq scan; `SET` / `WHERE` via E3 `eval_expr` / `Row_Env` (same S1 boolean/compare rules; **`CAST` in SET/WHERE (S2)**; **`?` in SET/WHERE (F4)**); `SET` values checked against declared column kinds (same as INSERT); row rewrite / delete-by-rowid; `rows_affected`; **set-oriented unique index maintenance on UPDATE** (delete all old keys for the update set, then insert all new — key swaps succeed; true duplicates → `Constraint`); rejects mutate on legacy indexes without columns (`Has_Indexes`); rejects updating IPK (rowid); NOT NULL / type mismatch on SET → `Constraint` |
| `CREATE`/`DROP INDEX` | yes | **yes (E5 + S3)** — `CREATE INDEX` / `CREATE UNIQUE INDEX`; register + backfill; unique indexes probe for collisions (`Constraint`); `IF NOT EXISTS` / `IF EXISTS`; catalog index v2 column list + Unique flag (bit1 of index column flags); `DESC` on index columns is **catalog metadata only** (key bytes are always ASC-encoded for v1); index names starting with `strix_autoindex_` (case-insensitive) are reserved for **CREATE and DROP** → `Invalid_Schema` (system autoindexes drop only via `DROP TABLE`); `DROP TABLE` auto-drops `strix_autoindex_*` then still rejects while user indexes exist |
| `BEGIN` / `COMMIT` / `ROLLBACK` | yes (E6) | **yes (E6)** — explicit txn mode; nested `BEGIN` → `In_Txn`; statements inside txn do not auto-commit until `COMMIT`; `ROLLBACK` undoes; `COMMIT`/`ROLLBACK` without `BEGIN` → `No_Txn`; **write failure inside explicit txn aborts the whole txn** (no savepoints; clears `explicit_txn`, sets `txn_aborted`); **flush-fence recovery:** retry `COMMIT` on the still-open session (auto-commit fence promotes to `explicit_txn`; shell close/quit/EOF/`--bail` exit refused until recovered; batch process exit **forfeits** recovery) |
| Scripts | yes | **yes (E6)** — stop-on-error default; optional `continue_on_error` / CLI `--continue-on-error`; **after an explicit-txn abort, the script always stops** (even with `continue_on_error`) so later statements cannot auto-commit outside the aborted txn; **after a flush fence, only recovery `COMMIT` and `SELECT` may run** (other stmts hard-stop; with `continue_on_error`, intervening non-allowed stmts are skipped until `COMMIT`); errors format as `file:line:col: message` when path+span known |
| `ALTER`, subqueries, … | yes (subset) | reject at bind/exec (`JOIN` executed in S6/F1 for INNER/CROSS/LEFT, N tables) |

Update this table as execute phases land.

## Known gaps

- No cascade for **user** indexes on `DROP TABLE` (drop indexes first); system `strix_autoindex_*` indexes are auto-dropped with the table; users cannot **create or drop** indexes with that reserved prefix
- `.schema` emits multi-column UNIQUE as table-level `UNIQUE (c1, c2)` inside `CREATE TABLE` (never dumps `strix_autoindex_*` names)
- No CTEs, set ops, windows, UPSERT, triggers/views/PRAGMA
- No FROM subqueries / correlated subqueries
- `token_kind_string(.NotEq)` prints `!=` even for `<>`
- Constraint names stored only transiently (not in AST yet)