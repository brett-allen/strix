# S4 Symbol Coverage Inventory

**Phase:** S4 (whole-query aggregates)  
**Plan:** [`sql-compliance.md`](sql-compliance.md) § Phase S4  
**Prior:** [`sql-compliance-s3-coverage.md`](sql-compliance-s3-coverage.md)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch.

**Coverage ratio:** **24 / 26 = 92.3%** (≥ 80% required)

---

## Prepare / classify (`src/exec/agg.odin`) — 8 / 9

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `is_aggregate_name` / `resolve_agg_fn` | yes | count/sum/avg/min/max happy; reject `SUM(*)` / `COUNT()` | COUNT(*); COUNT(expr); SUM/AVG/MIN/MAX arity; `*` only for COUNT |
| `analyze_expr_aggs` | yes | mixed columns; nested `SUM(COUNT(*))`; WHERE/ORDER rejects | bare vs agg; nested reject; Star in COUNT arg |
| `prepare_aggregate_select` | yes | `test_count_star_*`; `test_agg_reject_mixed_columns` | agg mode; mix → `Unsupported_Ast`; no-agg → row mode |
| `collect_agg_calls` | yes | multi-agg `COUNT`/`SUM`/`AVG`/`MIN`/`MAX` | multiple slots |
| `validate_agg_projection_exprs` | yes | `test_agg_unknown_column_in_arg`; empty-table COUNT | unbound in arg; WHERE dry-run |
| Aggregates in WHERE | yes | `test_agg_reject_where_and_order` | `Unsupported_Ast` |
| ORDER BY bare col with agg | yes | `test_agg_reject_where_and_order` | `Unsupported_Ast` |
| ORDER BY aggregate | no | — | `ORDER BY COUNT(*)` untested |

Uncovered (1): `ORDER BY COUNT(*)` with whole-query agg.

---

## Accumulate / finalize — 7 / 8

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `accumulate_agg_slot` COUNT(*) | yes | `test_count_star_basic_and_empty` | row count; WHERE filter |
| `accumulate_agg_slot` COUNT(expr) | yes | `test_count_expr_null_skipping` | null skip |
| `accumulate_agg_slot` SUM/AVG | yes | `test_sum_avg_min_max_numerics`; empty/all-null | int sum; float sum; null skip; non-numeric → `Unsupported_Ast` |
| `accumulate_agg_slot` MIN/MAX | yes | numerics + text reject | extremum; null skip; text → error |
| `finalize_agg_slot` | yes | empty + populated | COUNT→0; SUM/AVG/MIN/MAX→NULL when empty; AVG→Float |
| `exec_select_aggregate` | yes | all agg tests; LIMIT 0 / OFFSET | one row; empty table one row; LIMIT/OFFSET on result |
| `project_agg_cell` / `eval_expr_with_aggs` | yes | `COUNT(*) + 1`; constant alongside agg; `CAST(COUNT(*) AS TEXT)` | slot lookup; arith; literal; cast |
| Int→float SUM promote mid-stream | no | — | first ints then float in same SUM untested |

Uncovered (1): SUM accumulator promoting from int to float after seeing a float operand mid-scan.

---

## Reject / projection plumbing — 6 / 6

| Symbol / concern | Tested? | Test name(s) | Branches covered |
|------------------|---------|--------------|------------------|
| Mix agg + column / `*` | yes | `test_agg_reject_mixed_columns` | `Unsupported_Ast` |
| Nested agg / `SUM(*)` / `COUNT()` / `abs` | yes | `test_agg_reject_unsupported_forms` | `Unsupported_Ast` |
| Non-numeric SUM/MIN | yes | same | `Unsupported_Ast` |
| GROUP BY still rejected | yes | same | S5 foreshadow |
| `projection_name` for Call | yes | `COUNT(*)` column name | printed call text |
| `eval_cast_with_aggs` | yes | `test_agg_cast_count` | CAST over COUNT(*) |

---

## End-to-end — 3 / 3

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| `SELECT COUNT(*) FROM t` | yes | `test_count_star_basic_and_empty` | exit criterion |
| Empty table one-row semantics | yes | empty COUNT=0; empty SUM…=NULL | standard |
| Alias on aggregate | yes | `COUNT(*) AS n` | alias wins over printed name |

---

## Branch matrix (required)

| Branch | Asserted |
|--------|----------|
| `COUNT(*)` whole-query, one row | yes |
| `COUNT(*)` on empty table → `0` | yes |
| `COUNT(expr)` null-skipping | yes |
| `SUM` / `AVG` / `MIN` / `MAX` on numerics | yes |
| Empty / all-NULL: SUM/AVG/MIN/MAX → `NULL` | yes |
| `AVG` of integers → Float | yes |
| WHERE filters before aggregation | yes |
| Mix agg + non-agg column → `Unsupported_Ast` | yes |
| Nested agg / `SUM(*)` / `COUNT()` / non-agg call → `Unsupported_Ast` | yes |
| Non-numeric SUM/MIN → `Unsupported_Ast` | yes |
| Aggregates in WHERE → `Unsupported_Ast` | yes |
| ORDER BY bare column with agg SELECT → `Unsupported_Ast` | yes |
| GROUP BY still → `Unsupported_Ast` (S5) | yes |
| LIMIT/OFFSET on aggregate result row | yes |
| Unknown column in agg arg → `Unknown_Column` | yes |
| `CAST(COUNT(*) AS TEXT)` | yes |
| E1–E6 + S1–S3 still green | yes — full `./build.sh test` |

---

## New/changed error uses (S4)

| Code | When |
|------|------|
| `Unsupported_Ast` | Mix agg + bare columns; nested aggs; `SUM(*)`/`AVG(*)`/`MIN(*)`/`MAX(*)`; bad `COUNT` arity; non-numeric SUM/AVG/MIN/MAX; non-agg function calls; ORDER BY bare/agg with whole-query agg; aggregates in WHERE; GROUP BY/HAVING (unchanged) |
| `Unknown_Column` | Unbound name in aggregate argument (unchanged code; dry-run path) |

---

## Ratio

| Bucket | Covered | Total |
|--------|---------|-------|
| Prepare / classify | 8 | 9 |
| Accumulate / finalize | 7 | 8 |
| Reject / projection plumbing | 6 | 6 |
| End-to-end | 3 | 3 |
| **Combined** | **24** | **26** |

**24/26 = 92.3% ≥ 80% → PASS**

Uncovered (2): `ORDER BY COUNT(*)`; SUM int→float mid-scan promote.
