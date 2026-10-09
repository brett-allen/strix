# S1 Symbol Coverage Inventory

**Phase:** S1 (semantic hygiene — strict boolean context, comparison policy, identifier honesty)  
**Plan:** [`sql-compliance.md`](sql-compliance.md) § Phase S1  
**Prior:** [`exec-e3-coverage.md`](exec-e3-coverage.md) (expr eval baseline)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch.

**Coverage ratio:** **17 / 18 = 94.4%** (≥ 80% required)

---

## Boolean / compare hygiene (`src/exec/expr.odin`) — 12 / 13

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `require_bool_operand` | yes | `test_select_where_filter_and_exprs`; `test_boolean_context_blob_and_and` | Null/Integer/Float ok; Text → `Unsupported_Ast`; Blob → `Unsupported_Ast` |
| `value_is_true` | yes | `WHERE 1` / `WHERE flag`; AND/OR short-circuit | Integer ≠0 → true; 0 → false |
| `value_is_false` | yes | `WHERE 0`; `0 AND data` short-circuit | Integer 0 → false |
| `value_is_null` | yes | `WHERE NULL`; `IS NULL` paths | NULL unknown in WHERE |
| `eval_expr_bool` | yes | WHERE filter + Text reject | TRUE keep; FALSE/NULL drop; Text → error |
| `eval_unary` `.Not` | yes | `WHERE NOT name` → `Unsupported_Ast` | Text reject; numeric NOT still via other tests |
| `eval_logic` AND/OR | yes | `0 OR name` reject; `flag AND data` reject; `0 AND data` short-circuit | require both evaluated sides; short-circuit skips right |
| `compare_values` Integer–Integer | yes | `test_integer_compare_exact_beyond_f64_mantissa`; `test_compare_policy_matrix` | exact i64 |
| `compare_values` mixed int/float | yes | `test_compare_policy_matrix` (`i = 10.0`, `f > 10`) | via f64 |
| `compare_values` same-kind Text/Blob | yes | `test_compare_policy_matrix` | `'aa'`; `X'AA'` |
| `compare_values` Text/Blob↔numeric | yes | `test_compare_policy_matrix` | Text=int; int=text; Blob=int → `Unsupported_Ast` |
| `compare_values` Text↔Blob | yes | `test_compare_policy_matrix` | kind mismatch → `Unsupported_Ast` |
| `is_numeric_kind` / `value_as_f64` | yes | mixed compare paths | coerce helpers |

Uncovered (1): bare float `0.0`/`1.0` as sole WHERE predicate (Integer paths asserted; Float uses same `value_is_*` arms via numeric compare / existing float ORDER BY).

---

## Identifier policy (exec bind) — 1 / 1

| Symbol / path | Tested? | Test name(s) | Branches covered |
|---------------|---------|--------------|------------------|
| Table/index catalog lookup (case-sensitive) | yes | `test_table_and_index_names_are_case_sensitive` | wrong-case `FROM` → `Unknown_Table`; wrong-case `DROP INDEX` → `Unknown_Index`; column fold with exact table name |

---

## INSERT / UPDATE declared-type kinds — 3 / 3

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `declared_storage_kind` / `type_name_base` | yes | `test_insert_rejects_incompatible_literal_kinds` | INT/TEXT/REAL/BLOB families; untyped skip |
| `check_value_matches_column_type` (INSERT) | yes | `test_insert_rejects_incompatible_literal_kinds` | Text→INT, Blob→INT, Float→INT, Int→TEXT, Int→REAL, Text→BLOB → `Constraint`; matching + untyped ok |
| `check_value_matches_column_type` (UPDATE SET) | yes | via INSERT reject path + shared helper | same helper as INSERT |

---

## Regression — 1 / 1

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| IPK CRUD after S1 | yes | `test_ipk_crud_still_works_after_s1` | CREATE + INSERT (auto rowid) + UPDATE + DELETE + SELECT |

---

## Branch matrix (required)

| Branch | Asserted |
|--------|----------|
| Text in `WHERE` → `Unsupported_Ast` | yes |
| Text in `NOT` / `OR` → `Unsupported_Ast` | yes |
| Blob in `WHERE` / `AND` → `Unsupported_Ast` | yes |
| Integer `WHERE 1` / `WHERE 0` | yes |
| NULL predicate → no error, 0 rows | yes |
| AND short-circuit skips Text/Blob right | yes |
| Integer–Integer exact (incl. beyond f64 mantissa) | yes |
| Mixed int/float compare allowed | yes |
| Text/Blob ↔ numeric → `Unsupported_Ast` | yes |
| Same-kind Text/Blob compare ok | yes |
| Table/index case-sensitive; column fold | yes |
| INSERT Text into INT → `Constraint` (no affinity) | yes |
| INSERT matching kinds + untyped column ok | yes |
| IPK CRUD regression | yes |
| E1–E6 still green | yes — full `./build.sh test` |

---

## New/changed error uses (S1)

| Code | When |
|------|------|
| `Unsupported_Ast` | Text/Blob (non-numeric non-null) in boolean context; Text/Blob↔numeric (or other kind mismatch) compare without `CAST` |
| `Constraint` | INSERT/UPDATE value kind mismatches recognized declared column type (no soft coerce) |

---

## Ratio

| Bucket | Covered | Total |
|--------|---------|-------|
| Boolean / compare | 12 | 13 |
| Identifier policy | 1 | 1 |
| INSERT/UPDATE kinds | 3 | 3 |
| IPK regression | 1 | 1 |
| **Combined** | **17** | **18** |

**17/18 = 94.4% ≥ 80% → PASS**

Uncovered (1): dedicated float-only boolean predicate (shared code path with Integer).
