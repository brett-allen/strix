# SQL Dialect Notes (Strix)

SQLite-shaped dialect baseline. Intentional decisions and deviations live here.

## Supported statements (parser v1 / Phase 5)

| Kind | Forms |
|------|--------|
| DDL | `CREATE`/`DROP TABLE`, `CREATE`/`DROP INDEX`, `ALTER TABLE ADD COLUMN` |
| DML read | `SELECT` with joins, `WHERE`, `GROUP BY`/`HAVING`, `ORDER BY`, `LIMIT`/`OFFSET` |
| DML write | `INSERT` (`VALUES` / `SELECT`, `OR REPLACE`/`OR IGNORE`), `UPDATE`, `DELETE` |
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
| `CAST(… AS type)` | Supported |
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

Projection: `*`, `t.*`, `expr [AS alias | alias]`. `FROM` required.

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

Parser v1 accepts a wider surface than the executor runs. **Execute support** lives in [`sql-execute.md`](sql-execute.md) / `src/exec` (phases **E1–E4** minimum).

| Area | Parsed (today) | Executed |
|------|----------------|----------|
| `CREATE`/`DROP TABLE` | yes | **yes (E1)** — column `PRIMARY KEY` / `NOT NULL`; table-level `PRIMARY KEY`; `IF NOT EXISTS` / `IF EXISTS`; rejects other column/table constraints for now |
| `INSERT` … `VALUES` | yes | not yet (E2) |
| Single-table `SELECT` | yes | not yet (E3) |
| `UPDATE` / `DELETE` | yes | not yet (E4) |
| `CREATE`/`DROP INDEX` | yes | not yet (E5 stretch); `DROP TABLE` rejects while indexes exist |
| Joins, `GROUP BY`, `ALTER`, … | yes (subset) | reject at bind/exec until later plans |

Update this table as execute phases land.

## Known gaps

- DML execution incomplete (E2–E4); see [`sql-execute.md`](sql-execute.md)
- No CTEs, set ops, windows, UPSERT, triggers/views/PRAGMA
- No FROM subqueries / correlated subqueries
- `token_kind_string(.NotEq)` prints `!=` even for `<>`
- Constraint names stored only transiently (not in AST yet)