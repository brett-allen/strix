# Plan: SQL Language Parser

Implement a SQL parser for Strix that covers **DDL** and **DML**, targeting a **SQLite-shaped** dialect as the first parity north star.

## Goals

- Parse DDL and DML into a typed AST that later stages (binder, planner, executor) can consume.
- Produce clear, location-aware syntax errors.
- Keep the grammar small, explicit, and testable; grow it deliberately.
- Prefer SQLite syntax and semantics where dialects disagree.

## Non-goals (v1)

- Full SQLite SQL surface (window functions, CTEs, UPSERT, recursive queries, etc.).
- Query planning, optimization, or execution.
- PL/SQL / procedural extensions.
- Network protocol / wire format.
- Perfect round-trip pretty-printing (nice-to-have later).

## Dialect baseline

Use SQLite as the reference for:

| Area | Baseline |
|------|----------|
| Identifiers | Unquoted, `"double"`, `` `backtick` ``, `[bracket]` |
| Strings | Single-quoted, `''` escape |
| Comments | `--` line, `/* */` block |
| Types | Affinity-style names (`INTEGER`, `TEXT`, `REAL`, `BLOB`, `NUMERIC`, plus common aliases) |
| Null / bool | `NULL`; no native boolean literal required in v1 (`0`/`1` / expressions later) |
| Case | Keywords case-insensitive; unquoted identifiers folded per SQLite rules |

Document every intentional deviation from SQLite in `docs/sql-dialect.md` as they appear.

## Architecture

```
source text
    │
    ▼
┌────────┐
│ Lexer  │  tokens + spans
└───┬────┘
    ▼
┌────────┐
│ Parser │  recursive descent
└───┬────┘
    ▼
┌────────┐
│  AST   │  statements / expressions
└────────┘
```

**Package layout** (under `src/sql/`):

```
src/sql/
  token.odin      # Token_Kind, Token, spans
  lexer.odin      # scan source → tokens
  ast.odin        # statement + expression nodes
  parser.odin     # recursive descent entrypoints
  error.odin      # Parse_Error, formatting
  # later:
  print.odin      # optional AST debug printer
```

**Tests** live under `src/test/sql/` (or co-located `*_test.odin` if preferred), driven by `./build.sh test`.

Design choices:

1. **Hand-written recursive descent** — no external generator; easier to evolve and debug in Odin.
2. **Lexer produces a token slice** — parser indexes into it; keeps lookahead simple (`peek`, `next`, `expect`).
3. **AST owns structure only** — no name resolution, type checking, or catalog lookups in the parser.
4. **One statement or a script** — support `parse_statement` and `parse_script` (semicolon-separated).

## AST sketch

```text
Script            = Statement*
Statement         = DDL | DML

DDL               = Create_Table | Drop_Table
                  | Create_Index | Drop_Index
                  | Alter_Table          # phased in later

DML               = Select | Insert | Update | Delete

Create_Table      = name, if_not_exists, elements[]  # Table_Element in source order
                  #   Column | Table_Constraint
Column_Def        = name, type_name?, constraints[]
Column_Constraint = Not_Null | Primary_Key | Unique | Default | Check | References
Table_Constraint  = Primary_Key | Unique | Check | Foreign_Key

Select            = with?, select_cores (+ UNION… later), order_by?, limit?
Select_Core       = distinct?, projection, from?, where?, group_by?, having?
Insert            = or_conflict?, table, columns?, values|select|default_values
Update            = or_conflict?, table, sets[], where?
Delete            = table, where?

Expr              = Literal | Ident | Binary | Unary | Call | Cast
                  | Column_Ref | Placeholder | Subquery   # grow carefully
```

Prefer tagged unions / enums for node kinds. Store source spans on every node for diagnostics.

## Syntax coverage by phase

### Phase 0 — Foundations

- [x] `Token_Kind`, `Token`, byte/line/column spans
- [x] Lexer: identifiers, keywords, numbers (int/float), strings, punctuators, comments
- [x] Keyword table (case-insensitive lookup)
- [x] Parser scaffolding: `peek` / `next` / `expect` / `synchronize` (used by `parse_script` on error)
- [x] `Parse_Error` with span + message + stable `Parse_Error_Code`
- [x] Golden tests: tokenize fixtures; reject bad tokens cleanly

**Exit criteria:** lexer round-trips representative SQL snippets; keywords vs identifiers distinguished.

### Phase 1 — Expressions (shared by DDL defaults and DML)

- [x] Literals: integer, float, string, blob (`X'…'`), `NULL`
- [x] Names: `a`, `a.b`, quoted forms
- [x] Unary / binary operators with SQLite-ish precedence
- [x] Parentheses, function calls (`count(*)`, `abs(x)`)
- [x] Comparisons, `AND` / `OR` / `NOT`, `IS [NOT] NULL`
- [x] `IN (…)` list form; basic `BETWEEN`
- [x] Placeholders: `?`, `?N` (bind positions for later)

**Exit criteria:** expression parser covered by unit tests for precedence and associativity.

### Phase 2 — DDL (minimum viable schema)

- [x] `CREATE TABLE [IF NOT EXISTS] name ( … )`
- [x] Column definitions: name + optional type name + column constraints
- [x] Column constraints: `PRIMARY KEY`, `NOT NULL`, `UNIQUE`, `DEFAULT expr`
- [x] Table constraints: `PRIMARY KEY (…)`, `UNIQUE (…)`
- [x] `DROP TABLE [IF EXISTS] name`
- [x] `CREATE INDEX [IF NOT EXISTS] name ON table ( cols… )`
- [x] `DROP INDEX [IF EXISTS] name`

Defer initially:

- `ALTER TABLE`
- `FOREIGN KEY` / `REFERENCES` enforcement details (parse later even if executor ignores)
- `CHECK` constraints
- `WITHOUT ROWID`, generated columns, table options

**Exit criteria:** parse and pretty-debug the core schema statements used by early storage tests.

### Phase 3 — DML reads

- [x] `SELECT [DISTINCT] proj FROM …`
- [x] Projection: `*`, `table.*`, exprs with optional `AS` alias
- [x] `FROM` item: table name + optional alias (no joins yet → single table)
- [x] `WHERE expr`
- [x] `ORDER BY expr [ASC|DESC]` (list)
- [x] `LIMIT expr [OFFSET expr]` (SQLite forms)

**Exit criteria:** single-table selects with filter/sort/limit parse stably.

### Phase 4 — DML writes

- [x] `INSERT INTO t [(cols)] VALUES (…), (…)`
- [x] `INSERT INTO t [(cols)] SELECT …`
- [x] `UPDATE t SET col = expr [, …] [WHERE expr]`
- [x] `DELETE FROM t [WHERE expr]`
- [x] Optional conflict clause stubs: `INSERT OR REPLACE` / `OR IGNORE` (parse only)

**Exit criteria:** round-trip AST snapshots for CRUD statement fixtures.

### Phase 5 — Joins and richer DDL (parser completeness toward SQLite subset)

- [x] `JOIN` / `LEFT JOIN` / `CROSS JOIN` with `ON` / `USING`
- [x] `GROUP BY` / `HAVING`
- [x] `CHECK` constraints; `REFERENCES` in column/table form
- [x] `ALTER TABLE` — start with `ADD COLUMN` only
- [x] Multiple statements / scripts with `;`
- [x] Basic `CAST(expr AS type)`

Still deferred after Phase 5 unless needed:

- CTEs (`WITH`), `UNION` / `INTERSECT` / `EXCEPT`
- Window functions, `UPSERT` (`ON CONFLICT`)
- Triggers, views, `PRAGMA`
- Subqueries in `FROM` / correlated subqueries (parse after executor demand)

## Parser conventions

- **Keywords:** reserved only where SQLite requires; otherwise allow as identifiers when unambiguous.
- **Error recovery:** `parse_script` returns statements parsed before the first error, synchronizes to the next `;`, and returns that error (later statements are not parsed yet).
- **Ambiguity:** resolve like SQLite (e.g. `JOIN` precedence, type-name parsing rules).
- **Memory:** AST strings are cloned into the allocator passed to `parse_*`; caller owns lifetime via `free_*`. Lexer tokens alias `src`.
- **API surface (suggested):**

```odin
parse_script     :: proc(src: string, allocator := context.allocator) -> (Script, Parse_Error)
parse_statement  :: proc(src: string, allocator := context.allocator) -> (Statement, Parse_Error)
tokenize         :: proc(src: string, allocator := context.allocator) -> ([]Token, Parse_Error)
```

## Testing strategy

| Layer | What |
|-------|------|
| Lexer unit tests | Category fixtures: numbers, strings, comments, operators |
| Parser unit tests | One construct per test; assert AST shape |
| Golden / snapshot | `.sql` → sibling `.ast` under `src/test/sql/fixtures/` via `print_script`; regen with `odin run tools/regen_ast_goldens` |
| Negative tests | Invalid SQL fails with stable `Parse_Error_Code` (+ message substring checks) |
| Dialect tests | Marked cases comparing notes to SQLite behavior |

Wire into `./build.sh test` so `src/test/sql` runs with the rest of the suite.
## Implementation order (suggested weeks)

1. **Week A:** Phase 0 lexer + error types + fixture harness.
2. **Week B:** Phase 1 expressions + precedence tests.
3. **Week C:** Phase 2 DDL (`CREATE`/`DROP` table + index).
4. **Week D:** Phase 3 `SELECT` (single table).
5. **Week E:** Phase 4 `INSERT`/`UPDATE`/`DELETE`.
6. **Week F:** Phase 5 joins + `GROUP BY` + `ADD COLUMN`; freeze v1 grammar doc.

Adjust pacing freely; phases are the contract, not the calendar.

## Documentation deliverables

| Doc | Purpose |
|-----|---------|
| `docs/sql-parser.md` | This plan (living) |
| `docs/sql-dialect.md` | Accepted syntax, deviations from SQLite |
| `docs/sql-ast.md` | AST node reference once shapes stabilize |

Update the dialect doc whenever a Phase checkbox lands.

## Dependencies on the rest of Strix

The parser must not depend on storage or catalog. Downstream order:

```
sql parser  →  binder/catalog  →  planner  →  executor / storage
```

Early engine work can stub a hand-built AST, but **DDL/DML support for real SQL entry starts here**.

## Definition of done (parser v1)

- [x] Phases 0–5 complete with tests green under `./build.sh test`
- [x] Can parse a bootstrap script: create table + index, insert rows, select/update/delete
- [x] Errors include source location
- [x] Dialect notes list supported statements and known gaps
- [x] No catalog/executor imports inside `src/sql`

## Open questions

1. **Type names:** free-form SQLite affinity strings vs a fixed enum plus `Custom` — lean free-form with normalized affinity later.
2. **Script vs REPL:** prioritize `parse_script` for files, or single-statement for a CLI first?
3. **AST stability:** allow breaking AST changes until Phase 4 ends; then document and treat as semi-stable.
4. **Test package layout:** single `src/test` package vs `src/test/sql` package — choose when the first fixtures land.
