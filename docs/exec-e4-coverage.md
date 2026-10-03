# E4 Symbol Coverage Inventory

**Phase:** E4 (`UPDATE` / `DELETE` + engine row rewrite/delete helpers)  
**Prior:** [`exec-e3-coverage.md`](exec-e3-coverage.md)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch. Defer-only frees and struct-only rows do not count as covered.

**Coverage ratio:** **18 / 21 = 86%** (≥ 80% required)

---

## Engine helpers (`src/engine/catalog.odin`) — 4 / 4

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `table_delete_row` | yes | `test_table_delete_and_rewrite_row`; delete SQL tests | delete then Not_Found |
| `table_rewrite_row` | yes | `test_table_delete_and_rewrite_row`; UPDATE SQL tests | same-length in-place; length-mismatch delete+insert |
| `rowid_from_key` | yes | `test_table_delete_and_rewrite_row` | 8-byte BE ok; short key → Invalid_Argument |
| `rowid_key` (used by helpers) | yes | rewrite/delete + E2 insert paths | big-endian encode |

---

## UPDATE/DELETE exec (`src/exec/dml_update.odin`, `exec.odin`) — 13 / 16

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `exec_delete` | yes | delete where/all; reopen; negatives | WHERE filter; delete-all; rows_affected |
| `exec_update` | yes | update where/all/expr; reopen; negatives | SET exprs; multi-col; 0-row WHERE |
| `table_indexes_maintained` (E5; legacy Has_Indexes) | yes | `test_update_delete_reject_when_indexes_lack_columns` | Has_Indexes for legacy indexes without column metadata |
| `bind_update_assignments` | yes | unknown column; happy UPDATE; case-fold SET | Unknown_Column; bound idxs |
| `validate_mutate_where` | yes | WHERE unknown col; CAST reject (via SET) | dry-run WHERE |
| `validate_update_set_exprs` | yes | `test_update_unsupported_set_expr` | CAST → Unsupported_Ast |
| `collect_matching_rowids` | yes | DELETE WHERE / DELETE ALL | keep/filter; rowid decode |
| `collect_update_rewrites` | yes | UPDATE paths; NOT NULL | SET apply; Constraint; encode |
| `free_pending_rewrite_payloads` / `free_pending_rewrites` | no | defer-only | — |
| `Bound_Assign` / `Pending_Rewrite` | no | struct-only (no dedicated assert) | — |
| `exec_statement_ast` Update/Delete arms | yes | all update/delete tests | dispatches exec_update/delete |
| IPK SET reject | yes | `test_update_rejects_ipk_and_not_null` | Unsupported_Ast |
| NOT NULL on SET | yes | same | Constraint + rollback (row intact) |
| Closed session | yes | `test_update_delete_closed_session` | Closed |
| Unknown table | yes | `test_update_delete_unknown_table_column` | Unknown_Table |

---

## CLI E4 surface — 1 / 1

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `run_sql` Rows_Affected for UPDATE/DELETE | yes | `test_run_sql_update_delete_rows_affected` | exit 0; durable SELECT after mutate |

---

## Branch matrix (required)

| Branch | Asserted |
|--------|----------|
| `DELETE FROM t` / `DELETE … WHERE` | yes |
| `UPDATE t SET …` / `UPDATE … WHERE` | yes |
| SET expressions over row (`qty + 5`, `name \|\| '!'`) | yes |
| rows_affected counts (incl. 0) | yes |
| mutate + SELECT | yes |
| reopen durable | yes |
| Legacy indexes (no column list) → `Has_Indexes` (no stale index risk) | yes |
| Unknown table / column codes | yes |
| IPK SET rejected | yes |
| NOT NULL SET → Constraint + rollback | yes |
| Unsupported SET expr (CAST) | yes |
| Closed session | yes |
| CLI UPDATE/DELETE exit 0 + durable read-back | yes |
| E1–E3 still green | yes — full `./build.sh test` |

---

## New/changed error uses (E4)

| Code | When |
|------|------|
| `Unknown_Table` | UPDATE/DELETE missing table |
| `Unknown_Column` | SET column / WHERE unbound |
| `Has_Indexes` | UPDATE/DELETE while unmaintained (v1 / no-column) `index:` rows name the table |
| `Unsupported_Ast` | SET on INTEGER PRIMARY KEY; unsupported SET/WHERE exprs |
| `Constraint` | NOT NULL after SET |
| `Closed` | UPDATE/DELETE on closed session |
| `Engine` | cursor / rewrite / delete failures |

---

## Ratio

| Bucket | Covered | Total |
|--------|---------|-------|
| Engine helpers | 4 | 4 |
| UPDATE/DELETE exec | 13 | 16 |
| CLI E4 | 1 | 1 |
| **Combined** | **18** | **21** |

**18/21 = 86% ≥ 80% → PASS**

Uncovered (3): defer-only pending-rewrite frees; struct-only `Bound_Assign` / `Pending_Rewrite`.
