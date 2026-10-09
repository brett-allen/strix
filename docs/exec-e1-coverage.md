# E1 Symbol Coverage Inventory

**Phase:** E1 (session + catalog v2 + CREATE/DROP TABLE + CLI `sql`)  
**E2 follow-on:** [`exec-e2-coverage.md`](exec-e2-coverage.md) (row codec + INSERT).  
**Method:** Manual inventory (no llvm-cov in toolchain). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch — not “compiles” or bare `has_error` without classification.

**Coverage ratio:** **36 / 37 = 97.3%** (≥ 80% required)

Uncovered (1): `cli.print_usage` — help text only; not part of the DDL execute surface.

---

## `src/exec` (22 / 22)

| Symbol | File | Tested? | Test name(s) | Branches covered |
|--------|------|---------|--------------|------------------|
| `session_open` | session.odin | yes | `test_session_open_close_roundtrip`, `test_session_open_missing_file` | happy (file open + CREATE); missing file → error code |
| `session_adopt` | session.odin | yes | `test_session_adopt_nil_and_engine` | nil → closed; live engine pointer; close does not own |
| `session_close` | session.odin | yes | `test_session_open_close_roundtrip`, `test_session_adopt_nil_and_engine` | owned close; adopt no-close; idempotent close |
| `session_engine` | session.odin | yes | session tests | live pointer; nil after close |
| `ok_error` | error.odin | yes | `test_ok_has_free_error` | none / `!has_error` |
| `has_error` | error.odin | yes | many | true/false |
| `free_error` | error.odin | yes | `test_ok_has_free_error` | owned message; no-op on ok |
| `make_error` | error.odin | yes | `test_ok_has_free_error`, `test_format_error_*` | format args; code |
| `error_at` | error.odin | yes | `test_ok_has_free_error` | cloned message + code |
| `from_parse_error` | error.odin | yes | `test_from_parse_error` | none; clone message; empty → `"parse error"` |
| `from_engine_error` | error.odin | yes | `test_from_engine_error_mapping` | None; Exists→Table_Exists; Not_Found; Has_Indexes; Closed; Io; Invalid_Argument; default Engine |
| `format_error` | error.odin | yes | `test_format_error_with_and_without_span` | no span; `line:col:`; empty ok |
| `ok_result` | result.odin | yes | `test_ok_result_and_free_result` | kind=Ok |
| `free_result` | result.odin | yes | `test_ok_result_and_free_result` | empty Ok; owned Result_Set columns/rows |
| `column_from_def` | ddl.odin | yes | `test_column_from_def_pk_not_null`, bind constraint tests | PK+NOT NULL; UNIQUE accepted (S3); DEFAULT/CHECK/REFERENCES → Unsupported_Ast (CHECK/REFERENCES still) |
| `bind_create_table_columns` | ddl.odin | yes | `test_bind_rejects_empty_columns`, duplicate/PK/constraint tests | empty; duplicate names; table PK; unknown PK col; UNIQUE accepted (S3); CHECK/FK table constraints → Unsupported_Ast |
| `exec_create_table` | ddl.odin | yes | create/IF NOT EXISTS/closed AST tests | happy; Table_Exists; IF NOT EXISTS; closed session |
| `exec_drop_table` | ddl.odin | yes | drop/IF EXISTS/indexes/closed AST tests | happy; Unknown_Table; IF EXISTS; Has_Indexes (table remains); closed |
| `exec_script` | exec.odin | yes | multi-stmt, stop-on-error, parse, closed | multi CREATE/DROP; stop on Table_Exists; Parse; Closed |
| `exec_statement` | exec.odin | yes | session + ddl + unsupported | happy; Parse; Closed; Unsupported_Ast |
| `exec_statement_ast` | exec.odin | yes | `test_exec_statement_ast_create_drop_direct`, unsupported, closed | CREATE/DROP direct; all unsupported kinds |
| `statement_kind_label` | exec.odin | yes | `test_statement_kind_labels` | all `Statement_Kind` values |

---

## E1 catalog helpers (9 / 9)

| Symbol | File | Tested? | Test name(s) | Branches covered |
|--------|------|---------|--------------|------------------|
| `catalog_table_key` | catalog.odin | yes | `test_catalog_keys_and_free_entry` | `table:<name>` |
| `catalog_index_key` | catalog.odin | yes | `test_catalog_keys_and_free_entry` | `index:<name>` |
| `free_catalog_entry` | catalog.odin | yes | catalog + create reopen tests | columns + parent strings freed |
| `encode_catalog_row` | catalog.odin | yes | v2/v1/index encode tests | v2+cols; v1 table; index; index w/o parent → nil |
| `decode_catalog_row` | catalog.odin | yes | roundtrip + corrupt | v2; v1 table; index; short/bad version → Corrupt |
| `catalog_register_table` | catalog.odin | yes | `test_catalog_register_get_unregister_schema`, empty schema | schema+next_rowid; Exists; empty name; empty columns v2 |
| `catalog_get_table_entry` | catalog.odin | yes | register/get/drop tests | happy v2; Not_Found |
| `catalog_table_has_indexes` | catalog.odin | yes | `test_catalog_unregister_requires_txn_*`, drop indexes | true/false parent match |
| `catalog_unregister_table` | catalog.odin | yes | unregister + indexes + no-txn | success removes; Has_Indexes; Not_Found; No_Txn |

---

## CLI E1 surface (5 / 6)

| Symbol | File | Tested? | Test name(s) | Branches covered |
|--------|------|---------|--------------|------------------|
| `parse_sql_command_args` | cli.odin | yes | `test_parse_sql_command_args_variants` | `-c` / `--command`; path+`-c`; `.sql` file; stdin intent; `-c` missing value |
| `run_sql` | cli.odin | yes | `test_run_sql_create_drop_via_session_path`, open/exec failure | CREATE durable; DROP; open fail; unknown-table INSERT / unsupported SELECT exit≠0 |
| `run_sql_command` | cli.odin | yes | `test_run_sql_command_missing_c_arg`, via `run` sql | parse error exit 1; dispatch to `run_sql` |
| `read_file_or_stdin` | cli.odin | yes | `test_read_file_or_stdin_file` | file happy; missing file fail (stdin not unit-tested — process-coupled) |
| `ensure_strix_path` | cli.odin | yes | `test_ensure_strix_path_default_and_suffix` | default; suffix; already `.strix` |
| `print_usage` | cli.odin | **no** | — | help text only |

`init_database` / `run` sql dispatch covered by CLI integration tests (`test_run_dispatches_sql_subcommand`) but counted under `run_sql` / existing init smoke rather than as separate inventory rows above.

---

## DDL branch matrix (required)

| Branch | Asserted |
|--------|----------|
| CREATE happy + PK + NOT NULL + type names | yes — reopen catalog v2 |
| CREATE IF NOT EXISTS | yes — Ok, schema unchanged |
| CREATE duplicate → Table_Exists | yes |
| CREATE empty columns | yes — `Invalid_Schema` via `bind_create_table_columns` |
| Unsupported column constraints | yes — CHECK/REFERENCES (UNIQUE/DEFAULT literal supported post-E1/S3) |
| Unsupported table constraints | yes — CHECK/FK (UNIQUE supported in S3) |
| Duplicate column names | yes — `Invalid_Schema` |
| Table PRIMARY KEY unknown col | yes — `Invalid_Schema` |
| Table PRIMARY KEY applies flag | yes — `VARCHAR(32)` preserved |
| DROP happy durable | yes — reopen Not_Found |
| DROP IF EXISTS missing | yes — Ok |
| DROP missing | yes — `Unknown_Table` |
| DROP Has_Indexes | yes — code + table still present |
| Parse error | yes — `Parse` |
| Multi-statement create;drop | yes — durable outcomes |
| Script stop-on-error | yes — later CREATE not applied |
| session_open vs adopt | yes |
| session_close owned/adopt/idempotent | yes |
| format_error / free_error | yes |
| Unsupported CREATE INDEX/DROP INDEX/ALTER (SELECT/INSERT/UPDATE/DELETE moved to later phases) | yes — `Unsupported_Ast` each |
| Unsupported column DEFAULT non-literal | yes — `Unsupported_Ast` (literal DEFAULT accepted in E2) |

---

## Ratio

| Bucket | Covered | Total |
|--------|---------|-------|
| `src/exec` | 22 | 22 |
| E1 catalog helpers | 9 | 9 |
| CLI E1 surface | 5 | 6 |
| **Combined** | **36** | **37** |

**36/37 = 97.3% ≥ 80% → PASS**
