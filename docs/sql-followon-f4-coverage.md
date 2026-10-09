# F4 Symbol Coverage Inventory

**Phase:** F4 (Prepared statements / `?` binding)  
**Plan:** [`sql-followon.md`](sql-followon.md) § Phase F4  
**Prior:** F3 BOOLEAN/UUID; parser `Placeholder` / `?N`  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch. Docs-only notes and stretch goals are listed under Deferred and are **not** in the denominator.

**Coverage ratio:** **30 / 30 = 100%** (≥ 80% required)

Section sums: Parser 3 + API 8 + Eval 4 + DML positions 9 + Errors 6 = **30**. Covered cells: **30**. Ratio **30/30 = 100%**.

**Locked choices:**
- Session-level bind API on `Exec_Session` (not SQL `PREPARE`/`EXECUTE` text)
- Positional `?` auto-numbers 0,1,2… per statement; `?N` explicit (parser)
- Bound `Value`s cloned into the session table; same declared-type kind checks as literals
- CLI/shell: **API-first** (no `.param` / `--bind` in this phase)
- `exec_statement_params` dense arity: `len(params) == max_placeholder_index + 1` (document in dialect)

---

## Parser numbering — 3 / 3

| Symbol / concern | Tested? | Test name(s) | Branches covered |
|------------------|---------|--------------|------------------|
| Bare `?` → 0 | yes | `test_expr_placeholders` | single |
| Bare `?, ?` auto 0,1,… | yes | `test_expr_placeholder_auto_number` | left-to-right |
| `?N` explicit + advance | yes | same (`?2` then bare `?` → 3); `test_bind_qn_explicit_and_reuse` | exec path |

---

## Session / API (`bind.odin` + `exec.odin`) — 8 / 8

| Symbol / concern | Tested? | Test name(s) | Branches covered |
|------------------|---------|--------------|------------------|
| `session_bind` | yes | `test_bind_session_persist_and_clear` | clone into slot |
| `session_bind_all` | yes | via `exec_statement_params` | 0..n-1 |
| `session_clear_binds` | yes | persist test + params defer | destroy storage |
| `session_bind_count` | yes | persist test | filled count |
| `exec_statement_params` | yes | insert/select/update/delete tests | bind→exec→clear |
| `lookup_active_bind` success | yes | all happy-path binds | clone out |
| `validate_bind_arity` | yes | `test_bind_unbound_and_arity_errors` | too few/many/extra; dense `?2` |
| `collect_placeholder_max_statement` | yes | arity paths (INSERT/SELECT/JOIN/HAVING/LIMIT) | max index |

---

## Eval — 4 / 4

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| `eval_expr` Placeholder | yes | SELECT WHERE / projection / JOIN ON | bind table |
| `eval_expr_with_aggs` Placeholder | yes | `test_bind_having_and_limit_params` (HAVING) | agg-path lookup |
| `eval_literal_expr` Placeholder | yes | INSERT VALUES | VALUES bind |
| Unbound → `Invalid_Schema` | yes | unbound test + `test_select_negatives_codes` | clear message |

---

## DML positions — 9 / 9

| Position | Tested? | Test name(s) | Notes |
|----------|---------|--------------|-------|
| INSERT VALUES | yes | `test_bind_insert_select_params` | `VALUES (?, ?)` |
| SELECT WHERE | yes | same | `WHERE id = ?` |
| SELECT projection | yes | `test_bind_select_projection_and_join_on` | `a.n + ?` |
| JOIN ON | yes | same | `ON … AND b.id = ?` (param in ON, not only WHERE) |
| HAVING | yes | `test_bind_having_and_limit_params` | `HAVING COUNT(*) >= ?` |
| LIMIT / OFFSET | yes | same | `LIMIT ? OFFSET ?` |
| UPDATE SET | yes | `test_bind_update_delete_where_set` | `SET label = ?` |
| UPDATE WHERE | yes | same | `WHERE id = ?` |
| DELETE WHERE | yes | same | `WHERE n = ?` |

---

## Errors / types — 6 / 6

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| Arity too few | yes | `test_bind_unbound_and_arity_errors` | `Invalid_Schema`; dense `?2` needs 3 |
| Arity too many | yes | same | `Invalid_Schema` |
| Params on no-placeholder stmt | yes | same | `Invalid_Schema` |
| Unbound (no bind) | yes | same | `Invalid_Schema` |
| Kind mismatch → `Constraint` | yes | `test_bind_type_constraint_on_column` | BOOLEAN |
| `?N` reuse same slot | yes | `test_bind_qn_explicit_and_reuse` | `?1, ?0, ?1` |

---

## Deferred (not in denominator)

| Item | Disposition |
|------|-------------|
| SQL text `PREPARE` / `EXECUTE` | Out of scope (session API is the extension) |
| Named `:name` / `$name` | Deferred |
| Shell `.param` / batch `--bind` | Deferred; document API-first (open Q #7) |
| Persistent prepared AST cache | Not required; re-parse each `exec_statement_params` |
| Placeholders in `DEFAULT` / DDL | Not a supported position this phase |
| Sparse `exec_statement_params` (skip unused low indices) | Not supported; dense arity required — see dialect |

---

## Totals

| Section | Covered | Total |
|---------|---------|-------|
| Parser | 3 | 3 |
| Session / API | 8 | 8 |
| Eval | 4 | 4 |
| DML positions | 9 | 9 |
| Errors / types | 6 | 6 |
| **Sum** | **30** | **30** |

**Ratio: 30/30 = 100% ≥ 80%.** Exit criterion met.
