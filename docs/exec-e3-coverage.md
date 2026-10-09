# E3 Symbol Coverage Inventory

> **Superseded by S1 for boolean / compare truthiness.**  
> Non-NULL Text/Blob is **not** TRUE in boolean context. S1 rejects Text/Blob in `WHERE` / `AND` / `OR` / `NOT` with `Unsupported_Ast`. See [`sql-compliance-s1-coverage.md`](sql-compliance-s1-coverage.md) and [`sql-dialect.md`](sql-dialect.md) § Boolean context & comparisons.  
> Rows below that mention Text-as-boolean describe **historical E3 ship behavior** only; the branch matrix and `value_is_*` notes have been rewritten to match **current (S1) reject behavior** so this file does not conflict with S1.

**Phase:** E3 (single-table `SELECT` + expression evaluation + CLI result-set print)  
**Prior:** [`exec-e2-coverage.md`](exec-e2-coverage.md)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch. Defer-only frees and padding helpers do not count as covered.

**Coverage ratio:** **40 / 44 = 91%** (≥ 80% required) — E3 ship ratio retained; boolean negatives now live under S1 inventory.

---

## Expression evaluator (`src/exec/expr.odin`) + E2 `clone_value` — 25 / 27

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `eval_expr` | yes | where/projection/order + negatives | Literal; Column_Ref; Unary; Binary; Is_Null; In_List; reject Call/Between/Cast/Star/Placeholder |
| `eval_expr_bool` | yes | WHERE filter tests; S1 Text/Blob reject | TRUE keep (numeric); FALSE/NULL drop; Text/Blob → `Unsupported_Ast` (S1) |
| `eval_const_integer` | yes | LIMIT/OFFSET tests | non-neg integer constants |
| `eval_column_ref` | yes | alias select; Unknown_Column | 1-seg; 2-seg qualifier; unknown → Unknown_Column |
| `qualifier_matches` / `find_column_index` | yes | alias select; identifier case-fold test | table name + alias; equal_fold |
| `eval_unary` | yes | `-score`; `NOT (…)` | Minus numeric; NOT (Text → `Unsupported_Ast` under S1) |
| `eval_binary` / `eval_logic` / `eval_compare` | yes | WHERE AND/OR/comparisons | AND/OR; Eq/NotEq/Lt/…; NULL → NULL |
| `compare_values` | yes | ORDER BY; IN; incompatible ORDER BY kinds | numeric; text; type mismatch → error |
| `is_numeric_kind` / `value_as_f64` | yes | score sort; comparisons | int/float coerce |
| `bytes_compare` | no | (indirect via text ORDER BY only) | — |
| `eval_arith` | yes | `score + 1`; `-score` | Add/Sub integer |
| `eval_concat` | yes | `'hi' \|\| name` | text\|\|text |
| `value_as_text` | yes | `'hi' \|\| name`; `'x' \|\| 1.5` | Text; Integer; Float |
| `eval_is_null` | yes | `IS NULL` / `IS NOT NULL` | negated + plain |
| `eval_in_list` | yes | `id IN (1, 3)` | match |
| `format_value_cell` / `format_blob_hex` | yes | cells; `test_select_blob_and_empty_result` | NULL/int/text/blob `X'…'` |
| `value_is_true` / `value_is_false` / `value_is_null` | yes | WHERE AND short-circuit; S1 boolean negatives; IS NULL | int/float only in bool context; Text/Blob rejected before `value_is_*` (S1); NULL unknown |
| `clone_value` (E2) | yes | dual `name` projection | text clone independence |

---

## SELECT bind/exec (`src/exec/dml_select.odin`, `result.odin`, `exec.odin`) — 14 / 16

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `exec_select` | yes | all select_* tests | scan; filter; project; sort; limit/offset; empty |
| `validate_select_supported` | yes | DISTINCT/JOIN negatives; GROUP BY executed (S5) | Unsupported_Ast for DISTINCT/JOIN |
| `validate_select_exprs` | yes | Unknown_Column WHERE; BETWEEN | dry-run unbound/unsupported |
| `bind_select_projection` | yes | `*`; columns; `p.*`; expr alias | Star; Table_Star; Column; Expr |
| `table_star_matches` | yes | `SELECT p.*` | alias match |
| `resolve_proj_column` | yes | named cols; Unknown_Column | 1/2 seg; unknown |
| `projection_name` | yes | `AS s1`; bare column | alias; column segment |
| `project_cell` | yes | column + expr projections | Column idx; Expr eval |
| `sort_scanned_rows` / `compare_order_keys` | yes | ORDER BY DESC/ASC; incompatible kinds | desc flip; compare error propagates |
| `free_scanned_rows` | no | defer-only | — |
| `free_bound_projs` | no | defer-only | — |
| `result_set_result` | yes | all Result_Set asserts | kind + owned columns/rows |
| `exec_statement_ast` Select arm | yes | select tests; unsupported list | dispatches `exec_select` |

---

## CLI E3 surface — 1 / 1

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `format_result_set` / `print_result_set` | yes | `test_run_sql_select_prints_result_set` | header + row content asserted |

---

## Branch matrix (required)

| Branch | Asserted |
|--------|----------|
| `SELECT *` / column list / simple exprs | yes |
| FROM single table + optional alias | yes |
| WHERE: literals, cols, comparisons, AND/OR/NOT, arith, IS NULL, IN | yes |
| WHERE: Text/Blob as boolean → `Unsupported_Ast` (S1; E3 once treated non-NULL Text as TRUE) | yes — see S1 inventory |
| ORDER BY / LIMIT / OFFSET | yes |
| ORDER BY incompatible kinds → error | yes |
| Reject DISTINCT / JOIN → `Unsupported_Ast`; GROUP BY → S5 | yes |
| Reject BETWEEN / Call / Placeholder → `Unsupported_Ast` | yes |
| CAST → executed (S2; was `Unsupported_Ast` in E3) | yes — see [`sql-compliance-s2-coverage.md`](sql-compliance-s2-coverage.md) |
| Unknown table / column codes | yes |
| Identifier case-fold bind | yes |
| create/insert/select reopen round-trip | yes |
| CLI prints aligned result set (header/rows) | yes |
| Empty result set (header, 0 rows) | yes |
| Blob cell formatting | yes |
| E1/E2 still green | yes — full `./build.sh test` |

---

## New/changed error uses (E3)

| Code | When |
|------|------|
| `Unknown_Table` | FROM missing table; bad `t.*` qualifier |
| `Unknown_Column` | projection / WHERE / ORDER BY unbound name or bad qualifier |
| `Unsupported_Ast` | DISTINCT, JOIN, BETWEEN, non-agg calls, placeholders, non-integer LIMIT/OFFSET; ORDER BY type mismatch; **(S1)** Text/Blob in boolean context; Text/Blob↔numeric compare; **(S2)** invalid/`CAST` target errors (CAST itself is executed); **(S4)** whole-query `COUNT`/`SUM`/`AVG`/`MIN`/`MAX` are executed — see [`sql-compliance-s4-coverage.md`](sql-compliance-s4-coverage.md); **(S5)** `GROUP BY`/`HAVING` executed — see [`sql-compliance-s5-coverage.md`](sql-compliance-s5-coverage.md) |
| `Closed` | SELECT on closed session |
| `Engine` | decode / cursor failures during scan |

---

## Ratio

| Bucket | Covered | Total |
|--------|---------|-------|
| Expr + `clone_value` | 25 | 27 |
| SELECT bind/exec | 14 | 16 |
| CLI E3 | 1 | 1 |
| **Combined** | **40** | **44** |

**40/44 = 91% ≥ 80% → PASS**

Uncovered (4): `bytes_compare` (indirect only); `free_scanned_rows` / `free_bound_projs` (defer-only).
