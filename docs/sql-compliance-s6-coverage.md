# S6 Symbol Coverage Inventory

**Phase:** S6 (`JOIN` — INNER first)  
**Plan:** [`sql-compliance.md`](sql-compliance.md) § Phase S6  
**Prior:** [`sql-compliance-s5-coverage.md`](sql-compliance-s5-coverage.md)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch.

**Coverage ratio:** **24 / 28 = 85.7%** (≥ 80% required)

---

## Validate / bind (`join.odin` + `expr.odin` + `dml_select.odin`) — 10 / 11

| Symbol / concern | Tested? | Test name(s) | Branches covered |
|------------------|---------|--------------|------------------|
| `validate_select_joins` INNER + ON | yes | `test_inner_join_equi_filter` | accept |
| `validate_select_joins` CROSS / comma | yes | `test_cross_join_and_comma` | accept; no ON |
| `validate_select_joins` LEFT | yes | `test_join_rejects_left_using_multi`; `unsupported_test` | `Unsupported_Ast` |
| `validate_select_joins` USING | yes | `test_join_rejects_left_using_multi` | `Unsupported_Ast` |
| `validate_select_joins` >1 JOIN | yes | `test_join_rejects_left_using_multi` | `Unsupported_Ast` |
| `build_flat_join_columns` | yes | all join happy paths | flat schema + sides |
| Duplicate exposed alias | yes | `test_join_duplicate_alias_and_unknown_table` | `Invalid_Schema` |
| `resolve_column_index` qualified | yes | equi-join + table_star tests | `t.col` / alias |
| `resolve_column_index` ambiguous | yes | `test_join_ambiguous_column` | `Unknown_Column` + “ambiguous” |
| `resolve_column_index` unknown | yes | `test_join_unknown_column` | missing col / bad qualifier |
| INNER JOIN without ON | no | — | parser usually requires ON; exec path untested |

Uncovered (1): INNER JOIN missing `ON` at exec (parser typically rejects first).

---

## Execute nested-loop (`join.odin` + `dml_select.odin`) — 8 / 9

| Symbol / concern | Tested? | Test name(s) | Branches covered |
|------------------|---------|--------------|------------------|
| `scan_table_rows` | yes | all join tests | both sides |
| `concat_join_row` | yes | equi / cross | left\|\|right values |
| `nested_loop_join` ON filter | yes | `test_inner_join_equi_filter` | keep/drop |
| `nested_loop_join` + WHERE | yes | equi + WHERE qty; comma + WHERE | post-join filter |
| `nested_loop_join` CROSS (no ON) | yes | `test_cross_join_and_comma` | cartesian |
| Table_Star on one side | yes | `test_join_qualified_and_table_star` | `o.*` |
| Unknown right table | yes | `test_join_duplicate_alias_and_unknown_table` | `Unknown_Table` |
| Self-join with aliases | yes | equi uses distinct aliases; self-join in historical negatives now LEFT | aliases work |
| Empty×non-empty join → 0 rows | no | — | both sides empty untested explicitly |

Uncovered (1): explicit empty-table join → zero rows.

---

## Aggregates / GROUP BY over joins — 3 / 4

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| Whole-query `COUNT(*)` over join | yes | `test_join_with_aggregate` | S4 path on joined stream |
| `GROUP BY` over join | yes | `test_join_with_aggregate` | S5 path + qualified group key |
| HAVING over join groups | no | — | not asserted |
| ORDER BY after join | yes | equi-join ORDER BY | in-memory sort |

Uncovered (1): HAVING on join-grouped query.

---

## Rejects / regression — 3 / 4

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| LEFT / USING / multi-JOIN rejects | yes | `test_join_rejects_left_using_multi` | `Unsupported_Ast` |
| Single-table SELECT unchanged | yes | existing `select_test` / S1–S5 suites | no regression |
| `SELECT DISTINCT` still rejected | yes | `unsupported_test`; `select_test` negatives | unchanged |
| Index point-lookup skipped on joins | no | — | joins always seq-scan (by design; not asserted) |

Uncovered (1): explicit assert that join path does not use index lookup.

---

## Branch matrix (required)

| Branch | Asserted |
|--------|----------|
| Equi-join INNER ON + projection | yes |
| JOIN + WHERE | yes |
| Aliases / `t.col` | yes |
| Ambiguous unqualified column | yes |
| Unknown column / qualifier | yes |
| CROSS JOIN / comma-join | yes |
| LEFT OUTER rejected | yes |
| USING rejected | yes |
| 3+ tables rejected | yes |
| Agg / GROUP BY over join | yes |
| S1–S5 still green | yes — full `./build.sh test` |

---

## New/changed error uses (S6)

| Code | When |
|------|------|
| `Unsupported_Ast` | `LEFT OUTER JOIN`; `USING`; multiple JOIN clauses; (unchanged) DISTINCT / BETWEEN / … |
| `Unknown_Column` | Unbound / bad qualifier; **ambiguous** unqualified name (`ambiguous column: …`) |
| `Unknown_Table` | Missing join input table |
| `Invalid_Schema` | Duplicate exposed table/alias in FROM/JOIN |

---

## Ratio

| Bucket | Covered | Total |
|--------|---------|-------|
| Validate / bind | 10 | 11 |
| Execute nested-loop | 8 | 9 |
| Aggregates / GROUP BY over joins | 3 | 4 |
| Rejects / regression | 3 | 4 |
| **Combined** | **24** | **28** |

**24/28 = 85.7% ≥ 80% → PASS**

Uncovered (4): INNER missing ON at exec; empty×non-empty join zero rows; HAVING over join groups; index-skip assertion on join path.
