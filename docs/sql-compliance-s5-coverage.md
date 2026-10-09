# S5 Symbol Coverage Inventory

**Phase:** S5 (`GROUP BY` / `HAVING`)  
**Plan:** [`sql-compliance.md`](sql-compliance.md) § Phase S5  
**Prior:** [`sql-compliance-s4-coverage.md`](sql-compliance-s4-coverage.md)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch.

**Coverage ratio:** **22 / 25 = 88.0%** (≥ 80% required)

---

## Prepare / validate (`src/exec/agg.odin`) — 8 / 9

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `resolve_group_by_columns` | yes | `test_group_by_count_sum`; `test_group_by_reject_expr_and_having_bare` | column refs; reject `GROUP BY amt + 1` |
| `validate_expr_group_cols` | yes | `test_group_by_strict_select_reject`; HAVING bare reject | select-list bare non-group; HAVING bare |
| `prepare_grouped_select` | yes | all group tests; `SELECT *` reject | slots from proj/HAVING/ORDER BY; strict list |
| `column_idx_in_group` | yes | multi-key + strict reject | membership |
| `reject_aggs_in_where` | yes | S4 `test_agg_reject_where_and_order` | unchanged |
| `clone_agg_slot_templates` | yes | multi-group COUNT/SUM | per-group accumulators |
| `group_keys_equal` / `extract_group_key` | yes | NULL region group; multi-key | NULL=NULL; multi-col keys |
| `make_group_rep_row` | yes | group key projection / HAVING on key | synthetic row for keys |
| Qualified `t.col` in GROUP BY | no | — | `GROUP BY sales.region` untested |

Uncovered (1): qualified table.column in `GROUP BY`.

---

## Execute / HAVING / ORDER BY (`dml_select.odin` + agg) — 9 / 10

| Symbol / concern | Tested? | Test name(s) | Branches covered |
|------------------|---------|--------------|------------------|
| `exec_select_grouped` | yes | all `test_group_by_*` | partition; accumulate; project |
| Empty groups → 0 rows | yes | `test_group_by_empty_zero_rows` | vs whole-query one-row |
| `HAVING` post-aggregate | yes | `test_group_by_having` | agg + group-key predicates |
| WHERE pre-group | yes | `test_group_by_where_pre_filter` | filter before partition |
| `ORDER BY` group key | yes | `test_group_by_count_sum` | NULL sort; ASC |
| `ORDER BY` aggregate | yes | `test_group_by_order_by_agg` | `ORDER BY SUM(…) DESC` |
| `sort_grouped_out_rows` | yes | ORDER BY tests | insertion sort |
| LIMIT/OFFSET on groups | yes | `test_group_by_limit_offset` | window on group rows |
| `eval_expr_bool_with_aggs` | yes | HAVING | TRUE/FALSE filter |
| HAVING with only group key (no agg in HAVING) | no | — | `HAVING region = 'east'` alone untested |

Uncovered (1): HAVING that references only a group key (no aggregate).

---

## Strictness / rejects — 5 / 5

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| Bare non-group column in select | yes | `test_group_by_strict_select_reject` | `Unsupported_Ast` |
| `SELECT *` with GROUP BY | yes | same + `unsupported_test` | `Unsupported_Ast` |
| `GROUP BY` expression (non-column) | yes | `test_group_by_reject_expr_and_having_bare` | `Unsupported_Ast` |
| HAVING bare non-group column | yes | same | `Unsupported_Ast` |
| Mix agg+column without GROUP BY | yes | `test_whole_query_agg_still_works` | S4 path intact |

---

## End-to-end / regression — 3 / 3

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| `SELECT region, COUNT(*) … GROUP BY region` | yes | `test_group_by_count_sum` | exit criterion |
| Keys-only GROUP BY (no agg) | yes | `test_group_by_no_agg_keys_only` | distinct groups |
| Whole-query agg still works | yes | `test_whole_query_agg_still_works`; S4 suite | S4 unchanged |

---

## Branch matrix (required)

| Branch | Asserted |
|--------|----------|
| GROUP BY column + COUNT/SUM | yes |
| HAVING filters post-aggregate | yes |
| WHERE filters pre-group | yes |
| Empty table GROUP BY → 0 rows | yes |
| Whole-query empty COUNT still → 1 row | yes (script tail + S4) |
| Strict: non-group bare column → `Unsupported_Ast` | yes |
| Strict: `SELECT *` + GROUP BY → `Unsupported_Ast` | yes |
| GROUP BY non-column expr → `Unsupported_Ast` | yes |
| HAVING without GROUP BY | yes (parser; unchanged) |
| ORDER BY group key / aggregate | yes |
| Multi-column GROUP BY | yes |
| NULL group key collapses | yes |
| AVG/MIN/MAX with GROUP BY | yes |
| LIMIT/OFFSET on groups | yes |
| S1–S4 still green | yes — full `./build.sh test` |

---

## New/changed error uses (S5)

| Code | When |
|------|------|
| `Unsupported_Ast` | Non-column `GROUP BY`; select/HAVING/ORDER BY column not in group or agg; `SELECT *` with GROUP BY; (S4) mix without GROUP BY message no longer says “not supported yet” |
| `Unknown_Column` | Unbound name in GROUP BY / grouped exprs (unchanged code) |

---

## Ratio

| Bucket | Covered | Total |
|--------|---------|-------|
| Prepare / validate | 8 | 9 |
| Execute / HAVING / ORDER BY | 9 | 10 |
| Strictness / rejects | 5 | 5 |
| End-to-end / regression | 3 | 3 |
| **Combined** | **22** | **25** |

**22/25 = 88.0% ≥ 80% → PASS**

Uncovered (3): qualified `GROUP BY t.col`; HAVING on group key only; (optional stretch) ORDER BY output alias.
