# E6 Symbol Coverage Inventory

**Phase:** E6 (script UX + polish: txn keywords, continue-on-error, error formatting, fixture runs)  
**Prior:** [`exec-e5-coverage.md`](exec-e5-coverage.md)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch.

**Coverage ratio:** **22 / 24 = 91.7%** (≥ 80% required)

---

## Parser txn statements (`src/sql`) — 6 / 6

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `parse_begin` | yes | `test_parse_begin_commit_rollback` | bare + `TRANSACTION` |
| `parse_commit` | yes | same | bare + `TRANSACTION` |
| `parse_rollback` | yes | same | bare + `TRANSACTION` |
| `parse_optional_transaction` | yes | same | present / absent |
| `txn_stmt_span` | yes | same (span on stmt) | length from start→last tok |
| print/free Begin/Commit/Rollback | yes | same | `BEGIN`/`COMMIT`/`ROLLBACK` print; free no-op |

---

## Exec txn + script (`src/exec`) — 12 / 13

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `stmt_write_begin` | yes | txn commit/rollback + all auto-commit DML | auto begin; join explicit |
| `stmt_write_commit` | yes | auto-commit paths; explicit no-op commit | started / !started |
| `stmt_write_abort` | yes | IF NOT EXISTS / error paths; failed multi-row INSERT in BEGIN | started rollback; explicit → whole-txn abort |
| `exec_begin` | yes | nested BEGIN; commit script | happy; `In_Txn`; closed via session |
| `exec_commit` | yes | begin/commit persists; `No_Txn` without BEGIN | durable reopen; No_Txn |
| `exec_rollback` | yes | rollback undoes inserts; `No_Txn` | rows gone; No_Txn |
| `exec_script` stop-on-error | yes | `test_script_stop_on_error_and_continue_on_error` + E1 multi-stmt | first error stops |
| `exec_script` continue_on_error | yes | same + txn-abort stop | later stmts run; first err returned; **stops after explicit-txn abort** |
| `Exec_Options` | yes | continue + fixture `source_path` | both fields |
| `format_error` with path | yes | `test_format_error_with_source_path`; error_test | `file:line:col:`; path-only; bare |
| `from_engine_error` In_Txn/No_Txn | yes | `test_from_engine_error_mapping` | mapped codes |
| `statement_kind_label` Begin/Commit/Rollback | yes | `test_statement_kind_labels` | all three |
| `session_close` rollback open txn | partial | close after BEGIN covered indirectly via adopt+engine_close | adopt path rollback not asserted alone |

---

## CLI (`src/cli`) — 4 / 5

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `--continue-on-error` parse | yes | `test_parse_sql_command_args_variants` | flag sets `continue_on_error` |
| `run_sql` opts passthrough | yes | existing create/drop + exec failure | default opts; errors still fail |
| `format_error` path from file input | yes | via `run_sql_command` File → `source_path` wiring (unit on exec) | path set for `.sql` |
| usage mentions continue flag | no | help text only | — |
| fixture-style CLI smoke | yes | prior CLI sql tests still green | E1–E5 |

---

## Fixtures against `.strix` — 2 / 2

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `bootstrap_v1.sql` exec | yes | `test_fixture_bootstrap_v1_and_crud_against_strix` | CREATE/INDEX/INSERT/SELECT/UPDATE/DELETE + reopen |
| `crud.sql` exec | yes | same | CRUD + reopen |

---

## Branch matrix (required)

| Branch | Asserted |
|--------|----------|
| Nested `BEGIN` → `In_Txn` | yes |
| Statements inside txn not durable until `COMMIT` | yes (reopen after commit; rollback clears) |
| `ROLLBACK` undoes | yes |
| Failed write inside explicit txn → whole-txn abort | yes (`test_failed_multirow_insert_inside_begin_aborts_txn`) |
| continue_on_error × explicit-txn abort → script stops | yes (`test_continue_on_error_stops_after_explicit_txn_abort`) |
| Fixture reopen asserts row outcomes | yes (`test_fixture_bootstrap_v1_and_crud_against_strix`) |
| `COMMIT`/`ROLLBACK` without `BEGIN` → `No_Txn` | yes |
| Stop-on-error (default) | yes |
| Continue-on-error | yes |
| `file:line:col: message` formatting | yes |
| Fixtures on real `.strix` | yes |
| E1–E5 still green | yes — full `./build.sh test` |

---

## New/changed error uses (E6)

| Code | When |
|------|------|
| `In_Txn` | nested `BEGIN` |
| `No_Txn` | `COMMIT` / `ROLLBACK` with no explicit txn |

---

## Ratio

| Bucket | Covered | Total |
|--------|---------|-------|
| Parser txn | 6 | 6 |
| Exec txn/script | 12 | 13 |
| CLI | 4 | 5 |
| **Total** | **22** | **24** |

**22 / 24 = 91.7%** (≥ 80%). Fixtures (`bootstrap_v1.sql` / `crud.sql` on real `.strix`) are integration proof, not extra inventory rows.

Uncovered (2): `cli.print_usage` continue-flag line (help only); dedicated `session_close`→rollback assertion while adopted (behavior covered via engine close / txn tests).
