# SQL Dialect Notes (Strix)

**North star:** a **SQL-compliant subset** (standard-SQL / H2-ish clarity) plus **named extensions** — not full SQL:20xx and not “SQLite quirk parity.” Typed columns matter; no type affinity; `CAST` is explicit; boolean context is strict; `PRIMARY KEY` means `UNIQUE` + `NOT NULL` (index-backed). Internal **rowid** remains the storage key.

Execute semantics migrate under [`sql-compliance.md`](sql-compliance.md) (phases S0–S6). Parser surface may still accept forms the executor rejects until those phases land. Intentional deviations (IPK/rowid alias, `IF NOT EXISTS`, bracket/backtick idents, shell `.commands`) are **named extensions**, not the baseline.

Historical note: early execute (E1–E6) followed SQLite-shaped shortcuts (Text truthiness, IPK-only PK). **S1** removed Text/Blob truthiness and tightened compares; **S2** executes scalar `CAST`; **S3** enforces `UNIQUE` / non-IPK `PRIMARY KEY` via unique secondary indexes; **S4** executes whole-query aggregates (`COUNT`/`SUM`/`AVG`/`MIN`/`MAX`); **S5** executes single-table `GROUP BY` / `HAVING`. Remaining work (joins) is in the compliance plan.

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

### Boolean context & comparisons (execute / S1)

| Rule | Behavior |
|------|----------|
| Boolean (`WHERE` / `AND` / `OR` / `NOT`) | Integer/Float: `0` = false, `≠0` = true. NULL = unknown (3VL preserved; short-circuit may skip the other side). Text/Blob (and other non-numeric non-null) → `Unsupported_Ast`. |
| Integer–Integer compare | Exact `i64` (not via `f64`) |
| Mixed int/float compare | Allowed via `f64` (north-star default; documented) |
| Text/Blob ↔ numeric | Error without `CAST` (`Unsupported_Ast`) |
| Same-kind Text/Blob | Byte/lex compare unchanged |

### INSERT / UPDATE declared-type kinds (execute / S1)

| Rule | Behavior |
|------|----------|
| Recognized types | Bound value kind must match: `INT`/`INTEGER` → Integer; `REAL`/`FLOAT`/`DOUBLE` → Float; `TEXT`/`VARCHAR`/`CHAR`/`CHARACTER`/`CLOB`/`NVARCHAR`/`UUID` → Text; `BLOB` → Blob. Parameters (e.g. `VARCHAR(10)`) ignored for matching. |
| Mismatch | `Constraint` (e.g. `INSERT INTO t (n) VALUES ('10')` into `n INT`) — no soft coerce, no affinity |
| NULL | Allowed unless `NOT NULL` |
| Empty / unknown type name | Store bound kind as-is (no check until a recognized name) |
| `UPDATE SET` | Same kind check on assigned values |

### PRIMARY KEY shapes (execute / S3)

| Shape | Behavior |
|-------|----------|
| **IPK (extension)** | Sole column `INTEGER`/`INT PRIMARY KEY` aliases btree rowid; omit/`NULL` auto-allocates via `next_rowid`. No system unique index on the IPK column. |
| **Non-IPK PK** | Single-column PK on other types (`TEXT`, `VARCHAR(…)`, `UUID`, `REAL`, …) → implied `NOT NULL` + system unique index `strix_autoindex_<table>_<n>`. NULL / duplicate → `Constraint`. |
| **Composite PK** | Still rejected (`Unsupported_Ast`). |
| **Internal rowid** | Always present as the heap btree key; **not** exposed as a SQL column in S3. |

`UNIQUE` (column or table) and `CREATE UNIQUE INDEX` use the same unique-index maintenance path. Nullable UNIQUE columns allow multiple NULLs.

### Scalar `CAST` (execute / S2)

`CAST(expr AS type)` is the **only** conversion path (no type affinity). Same `eval_expr` path as projection / `WHERE` / `SET`. NULL → NULL. Invalid casts → `Unsupported_Ast` (never NULL-by-affinity).

**Target type names** (parameters stripped, case-insensitive): `INTEGER`/`INT`; `REAL`/`FLOAT`/`DOUBLE`; `TEXT`/`VARCHAR`/`CHAR`/`CHARACTER`/`CLOB`/`NVARCHAR`/`UUID` (UUID → Text until a native UUID type); `BLOB`. Other names (e.g. `BOOLEAN`) → error.

| From → To | INTEGER | REAL | TEXT | BLOB |
|-----------|---------|------|------|------|
| NULL | NULL | NULL | NULL | NULL |
| Integer | identity | `f64` | decimal string | **reject** |
| Float | truncate toward 0 (finite, in `i64` range) | identity | `%g` string | **reject** |
| Text | strict decimal\* | full `f64` parse (trim) | identity | UTF-8 bytes |
| Blob | **reject** | **reject** | bytes as UTF-8 text | identity |

\* **Text → INTEGER:** trim surrounding whitespace; optional leading `+`/`-`; remaining must be **decimal digits only**. Reject empty, fractional (`'10.5'`), hex (`'0x10'`), underscores, trailing garbage (`'10x'`), or digits that do not fit in `i64` (no silent wrap; same `Unsupported_Ast` / out-of-range honesty as Float→INTEGER). Use `CAST(… AS REAL)` then `CAST(… AS INTEGER)` if you need float-then-truncate from text.

### Aggregates (execute / S4)

Whole-query aggregates on a **single table** without `GROUP BY`. `WHERE` filters rows **before** aggregation. An aggregate-only select list (aggregates and/or constants; no bare columns) yields **exactly one row**, including on an empty table.

| Function | Behavior |
|----------|----------|
| `COUNT(*)` | Counts all filtered rows (including rows with NULLs elsewhere) |
| `COUNT(expr)` | Counts non-NULL `expr` values (null-skipping) |
| `SUM(expr)` | Numeric sum; null-skipping; empty/all-NULL → `NULL`; Integer until a Float appears |
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

### Literals & comments

- Strings: `'…'` with `''` escape; unterminated strings are lexer errors
- Blob: `X'hex'` / `x'hex'` — hex length must be **even**; odd length is a lexer error
- Numbers: int, float, hex `0x…`
- Comments: `--` line; `/* */` block — **unterminated `/*` is a lexer error** (not silently absorbed)
- Placeholders: `?` (index 0), `?N` (stores N, including `?0`)

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

## Fixtures & goldens

- `.sql` fixtures: `bootstrap.sql`, `bootstrap_v1.sql`, `crud.sql`, `phase5.sql`
- Sibling `.ast` goldens from `print_script` (trailing newlines normalized)
- Regenerate: `odin run tools/regen_ast_goldens`

## Executed vs parsed only

Parser v1 accepts a wider surface than the executor runs. **Execute support** lives in [`sql-execute.md`](sql-execute.md) / `src/exec` (phases **E1–E4** minimum; **E5** indexes + **E6** script/txn polish landed).

| Area | Parsed (today) | Executed |
|------|----------------|----------|
| `CREATE`/`DROP TABLE` | yes | **yes (E1/E2 + S3)** — `NOT NULL`; literal/`NULL` `DEFAULT`; **two PK shapes (S3):** (A) sole `INTEGER`/`INT PRIMARY KEY` = IPK/rowid alias (named extension); (B) single-column non-IPK PK (`TEXT`/`VARCHAR`/`UUID`/…) = `NOT NULL` + system unique index `strix_autoindex_<table>_<n>`; column/table `UNIQUE` → system unique indexes; `DROP TABLE` auto-drops system autoindexes (user indexes still block); `IF NOT EXISTS` / `IF EXISTS`; rejects **composite** PK; CHECK/FK still unsupported |
| `INSERT` … `VALUES` | yes | **yes (E2 + S1 + S3)** — multi-row (one txn; mid-statement failure rolls back in auto-commit); optional column list; IPK rowid alias for sole `INTEGER`/`INT` PK; non-IPK PK / UNIQUE duplicates → `Constraint`; NULL PK → `Constraint`; UNIQUE allows multiple NULLs; **declared-type kind check (S1):** recognized types (`INT`/`INTEGER` → Integer; `REAL`/`FLOAT`/`DOUBLE` → Float; `TEXT`/`VARCHAR`/…/`UUID` → Text; `BLOB` → Blob) reject mismatched literal kinds with `Constraint` (no soft coerce / affinity); empty/unknown type names store the bound kind as-is; rejects `INSERT…SELECT` / `OR REPLACE`/`OR IGNORE` / `DEFAULT VALUES`; maintains secondary indexes (E5/S3) |
| Single-table `SELECT` | yes | **yes (E3 + S1 + S2 + S4 + S5)** — `*` / columns / simple exprs; FROM + optional alias; WHERE (literals, cols, comparisons, AND/OR/NOT, arith, `IS NULL`, `IN` list, **`CAST` (S2)**); **strict boolean context (S1):** Integer/Float `0` = false, `≠0` = true; NULL unknown (3VL for AND/OR); Text/Blob (and other non-numeric non-null) in `WHERE`/`AND`/`OR`/`NOT` → `Unsupported_Ast`; **compare (S1):** Integer–Integer exact `i64`; mixed int/float via `f64`; same-kind Text/Blob byte/lex; Text/Blob↔numeric without `CAST` → `Unsupported_Ast`; **`CAST(expr AS type)` (S2)** in projection/WHERE — see [Scalar CAST](#scalar-cast-execute--s2); **whole-query aggregates (S4):** `COUNT(*)` / `COUNT(expr)` / `SUM` / `AVG` / `MIN` / `MAX` (numerics; null-skipping except `COUNT(*)`) without `GROUP BY` → one result row — see [Aggregates](#aggregates-execute--s4); **`GROUP BY` / `HAVING` (S5):** column-ref keys; strict select list; HAVING post-agg; empty groups → 0 rows — see [GROUP BY / HAVING](#group-by--having-execute--s5); ORDER BY / LIMIT / OFFSET (in-memory; group keys/aggs with GROUP BY; incompatible ORDER BY kinds → error); rejects DISTINCT / JOIN / BETWEEN / subqueries with `Unsupported_Ast`; CLI aligned text table; optional index point lookup for **text/blob** `WHERE col = const` only (E5; numeric eq stays on seq scan) |
| `UPDATE` / `DELETE` | yes | **yes (E4/E5 + S1 + S2)** — seq scan; `SET` / `WHERE` via E3 `eval_expr` / `Row_Env` (same S1 boolean/compare rules; **`CAST` in SET/WHERE (S2)**); `SET` values checked against declared column kinds (same as INSERT); row rewrite / delete-by-rowid; `rows_affected`; maintains indexes when catalog has column metadata; rejects mutate on legacy indexes without columns (`Has_Indexes`); rejects updating IPK (rowid); NOT NULL / type mismatch on SET → `Constraint` |
| `CREATE`/`DROP INDEX` | yes | **yes (E5 + S3)** — `CREATE INDEX` / `CREATE UNIQUE INDEX`; register + backfill; unique indexes probe for collisions (`Constraint`); `IF NOT EXISTS` / `IF EXISTS`; catalog index v2 column list + Unique flag (bit1 of index column flags); `DESC` on index columns is **catalog metadata only** (key bytes are always ASC-encoded for v1); index names starting with `strix_autoindex_` (case-insensitive) are reserved → `Invalid_Schema`; `DROP TABLE` auto-drops `strix_autoindex_*` then still rejects while user indexes exist |
| `BEGIN` / `COMMIT` / `ROLLBACK` | yes (E6) | **yes (E6)** — explicit txn mode; nested `BEGIN` → `In_Txn`; statements inside txn do not auto-commit until `COMMIT`; `ROLLBACK` undoes; `COMMIT`/`ROLLBACK` without `BEGIN` → `No_Txn`; **write failure inside explicit txn aborts the whole txn** (no savepoints; clears `explicit_txn`, sets `txn_aborted`); **flush-fence recovery:** retry `COMMIT` on the still-open session (auto-commit fence promotes to `explicit_txn`; shell close/quit/EOF/`--bail` exit refused until recovered; batch process exit **forfeits** recovery) |
| Scripts | yes | **yes (E6)** — stop-on-error default; optional `continue_on_error` / CLI `--continue-on-error`; **after an explicit-txn abort, the script always stops** (even with `continue_on_error`) so later statements cannot auto-commit outside the aborted txn; **after a flush fence, only recovery `COMMIT` and `SELECT` may run** (other stmts hard-stop; with `continue_on_error`, intervening non-allowed stmts are skipped until `COMMIT`); errors format as `file:line:col: message` when path+span known |
| Joins, `ALTER`, … | yes (subset) | reject at bind/exec until later plans (`GROUP BY`/`HAVING` executed in S5) |

Update this table as execute phases land.

## Known gaps

- No cascade for **user** indexes on `DROP TABLE` (drop indexes first); system `strix_autoindex_*` indexes are auto-dropped; users cannot create indexes with that reserved prefix
- No CTEs, set ops, windows, UPSERT, triggers/views/PRAGMA
- No FROM subqueries / correlated subqueries
- `token_kind_string(.NotEq)` prints `!=` even for `<>`
- Constraint names stored only transiently (not in AST yet)