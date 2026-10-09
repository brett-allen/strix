# F1 Symbol Coverage Inventory

**Phase:** F1 (Join widening — `LEFT OUTER` + 3+ tables)  
**Plan:** [`sql-followon.md`](sql-followon.md) § Phase F1  
**Prior:** [`sql-compliance-s6-coverage.md`](sql-compliance-s6-coverage.md)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch.

**Coverage ratio:** **26 / 31 = 83.9%** (≥ 80% required)

---

## Validate / bind (`join.odin` + `expr.odin` + `dml_select.odin`) — 9 / 11

| Symbol / concern | Tested? | Test name(s) | Branches covered |
|------------------|---------|--------------|------------------|
| `validate_select_joins` INNER + ON | yes | `test_inner_join_equi_filter` | accept |
| `validate_select_joins` CROSS / comma | yes | `test_cross_join_and_comma` | accept; no ON |
| `validate_select_joins` LEFT + ON | yes | `test_left_join_preserves_unmatched` | accept `LEFT` / `LEFT OUTER` |
| `validate_select_joins` USING | yes | `test_join_rejects_using_right_full_natural`; `unsupported_test` | `Unsupported_Ast` |
| `validate_select_joins` N JOIN clauses | yes | `test_three_table_join_chain` | accept multi-JOIN |
| `build_flat_join_columns` N sides | yes | 3-table + LEFT happy paths | flat schema + N `Join_Side`s |
| Duplicate exposed alias | yes | `test_join_duplicate_alias_and_unknown_table` | `Invalid_Schema` |
| `resolve_column_index` qualified | yes | equi-join + table_star + 3-table | `t.col` / alias |
| `resolve_column_index` ambiguous (2- and 3-table) | yes | `test_join_ambiguous_column`; `test_join_three_table_ambiguous` | `Unknown_Column` + “ambiguous” |
| `resolve_column_index` unknown | yes | `test_join_unknown_column` | missing col / bad qualifier |
| INNER / LEFT missing `ON` at exec | no | — | parser usually requires ON; exec path untested |

Uncovered (2): INNER/LEFT missing `ON` at exec (parser typically rejects first).

---

## Execute nested-loop (`join.odin` + `dml_select.odin`) — 10 / 12

| Symbol / concern | Tested? | Test name(s) | Branches covered |
|------------------|---------|--------------|------------------|
| `scan_table_rows` | yes | all join tests | N sides |
| `concat_join_row` | yes | equi / cross / 3-table | left\|\|right values |
| `null_extend_join_row` | yes | `test_left_join_preserves_unmatched` | right cols → `NULL` |
| `nested_loop_join_step` INNER ON | yes | `test_inner_join_equi_filter` | keep/drop |
| `nested_loop_join_step` LEFT unmatched | yes | `test_left_join_preserves_unmatched` | NULL-extend path |
| `nested_loop_join_step` CROSS (no ON) | yes | `test_cross_join_and_comma` | cartesian |
| `filter_rows_where` after join | yes | ON vs WHERE; INNER+WHERE | post-join filter |
| Left-deep 3-table chain | yes | `test_three_table_join_chain` | INNER–INNER; LEFT–INNER; LEFT–LEFT |
| Mix LEFT + INNER | yes | `test_three_table_join_chain` | INNER after LEFT drops NULL left |
| Table_Star on one side | yes | `test_join_qualified_and_table_star` | `o.*` |
| Unknown right table | yes | `test_join_duplicate_alias_and_unknown_table` | `Unknown_Table` |
| Empty×non-empty LEFT → NULL-extend all left | no | — | empty right untested explicitly |
| `filter_rows_where` eval error path | no | — | error mid-filter untested |

Uncovered (2): empty-right LEFT NULL-extend-all; WHERE eval error cleanup.

---

## Aggregates / GROUP BY over widened joins — 4 / 4

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| Whole-query `COUNT(*)` over join | yes | `test_join_with_aggregate` | S4 path on joined stream |
| `GROUP BY` over join | yes | `test_join_with_aggregate` | S5 path + qualified group key |
| HAVING over LEFT join groups | yes | `test_join_with_aggregate` | `COUNT(o.id)=0` keeps unmatched |
| ORDER BY after join | yes | equi / LEFT / 3-table ORDER BY | in-memory sort |

---

## Rejects / regression — 3 / 4

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| USING / RIGHT / FULL / NATURAL rejects | yes | `test_join_rejects_using_right_full_natural` | `Unsupported_Ast` / `Parse` |
| Single-table SELECT unchanged | yes | existing `select_test` / S1–S5 suites | no regression |
| `SELECT DISTINCT` still rejected | yes | `unsupported_test`; `select_test` negatives | unchanged |
| Index point-lookup skipped on joins | no | — | joins always seq-scan (by design; not asserted) |

Uncovered (1): explicit assert that join path does not use index lookup.

---

## Branch matrix (required)

| Branch | Asserted |
|--------|----------|
| Equi LEFT preserving unmatched left | yes |
| ON vs WHERE (NULL-extended filtered by WHERE) | yes |
| Filter in ON keeps unmatched left | yes |
| 3-table INNER chain | yes |
| Mix LEFT + INNER / LEFT + LEFT | yes |
| Ambiguous unqualified (2- and 3-table) | yes |
| USING rejected (`Unsupported_Ast`) | yes |
| RIGHT / FULL / NATURAL → `Parse` | yes |
| Agg / GROUP BY / HAVING over LEFT | yes |
| S1–S6 INNER/CROSS regression | yes — full `./build.sh test` |

---

## New/changed error uses (F1)

| Code | When |
|------|------|
| `Unsupported_Ast` | `JOIN … USING`; (unchanged) DISTINCT / BETWEEN / … |
| `Parse` | `RIGHT` / `FULL` / `NATURAL` (parser `Unsupported_Syntax`) |
| `Unknown_Column` | Unbound / bad qualifier; **ambiguous** unqualified name across N sides |
| `Unknown_Table` | Missing join input table |
| `Invalid_Schema` | Duplicate exposed table/alias in FROM/JOIN |

---

## Ratio

| Bucket | Covered | Total |
|--------|---------|-------|
| Validate / bind | 9 | 11 |
| Execute nested-loop | 10 | 12 |
| Aggregates / GROUP BY over widened joins | 4 | 4 |
| Rejects / regression | 3 | 4 |
| **Combined** | **26** | **31** |

**26/31 = 83.9% ≥ 80% → PASS**

Uncovered (5): INNER/LEFT missing ON at exec; empty-right LEFT; WHERE eval error cleanup; index-skip assertion on join path.
