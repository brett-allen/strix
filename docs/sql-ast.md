# SQL AST Reference (Strix)

Semi-stable after Phase 5. Spans are stored on statements and most nodes for diagnostics.

## String ownership

**Hard contract:** every string field on the AST is owned by the AST (cloned into the parse allocator). `free_expr` / `free_statement` / `free_script` free them.

- Lexer `Token.text` aliases the input `src` buffer (not owned).
- After a successful `parse_*`, callers may discard `src`.
- Quoted identifiers are stored **normalized** (delimiters stripped; `""` / `` `` `` escapes undone). Original spelling remains available via `span` into `src` if the caller kept `src`.
- Literal `text` keeps the source spelling (including quotes on strings / `X'…'` on blobs) but is still a clone.

## Top level

- `Script` → `[]Statement`
- `Statement` → tagged `Statement_Kind` + `Statement_Data` union

Kinds: `Create_Table`, `Drop_Table`, `Create_Index`, `Drop_Index`, `Alter_Table`, `Select`, `Insert`, `Update`, `Delete`.

## DDL

- `Create_Table_Stmt` — name, `if_not_exists`, **`elements[]`** (`Table_Element` in source order)
  - `Table_Element` — `.Column` (`Column_Def`) or `.Table_Constraint` (`Table_Constraint`)
  - Mixed column / table-constraint order is preserved (printer emits the same order)
- `Column_Def` — name, `type_name`, `constraints[]`
- `Column_Constraint` — `Primary_Key` | `Not_Null` | `Unique` | `Default` (`default_expr`) | `Check` (`check_expr`) | `References` (`Foreign_Key_Ref`)
- `Table_Constraint` — `Primary_Key`/`Unique` (`columns`) | `Check` | `Foreign_Key` (`columns` + `references`)
- `Foreign_Key_Ref` — `table`, optional `columns[]`
- `Alter_Table_Stmt` — `table` + `Column_Def` (ADD COLUMN only)
- Index/drop structs as in Phase 2

## SELECT

- `Select_Stmt` — `is_distinct`, `projection[]`, `from`, `joins[]`, `where_expr`, `group_by[]`, `having`, `order_by[]`, `limit`, `offset`
- `Select_Item` — `Star` | `Table_Star` | `Expr` (+ optional `alias`)
- `Join_Clause` — `Inner` | `Left` | `Cross`; `on` and/or `using_cols`

## DML writes

- `Insert_Stmt` — conflict (`None`/`Replace`/`Ignore`), `Values` rows or nested `Select_Stmt`
- `Update_Stmt` — `sets[]` of `Assignment`, optional `where_expr`
- `Delete_Stmt` — table + optional `where_expr`

## Expressions

`Literal`, `Column_Ref`, `Placeholder`, `Star`, `Unary`, `Binary`, `Call`, `Is_Null`, `In_List`, `Between`, `Cast` (`expr` + `type_name`).
