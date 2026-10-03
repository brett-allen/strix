# E2 Symbol Coverage Inventory

**Phase:** E2 (heap row codec + `INSERT … VALUES` + `next_rowid` persistence + literal `DEFAULT` + PK policy)  
**Prior:** [`exec-e1-coverage.md`](exec-e1-coverage.md)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch.

**Coverage ratio:** **36 / 37 = 97.3%** (≥ 80% required)

Uncovered (1): `clone_value` (helper reserved for E3 row env).

---

## Row codec + `Value` (`src/exec/value.odin`, `row.odin`) — 18 / 19

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `free_value` / `free_values` | yes | row codec + insert decode | Text/Blob owned; Null/Integer no-op |
| `value_null` / `value_integer` / `value_float` / `value_text` / `value_blob` | yes | `test_heap_row_codec_roundtrip_all_kinds` | all kinds |
| `clone_value` | **no** | — | reserved |
| `eval_literal_expr` | yes | insert tests; DEFAULT reject | Literal; Unary ±; Binary/Column → Unsupported_Ast |
| `value_from_literal` | yes | insert + codec | Null/Int/Float/String/Blob |
| `unquote_sql_string` | yes | insert text values; DEFAULT `'x'` | quotes + `''` escape path via literals |
| `decode_sql_blob` / `hex_nibble` | yes | `test_insert_blob_literal_x_hex` (`X'ABCD'`) | even hex via INSERT bind |
| `encode_heap_row` | yes | codec + insert reopen | null bitmap + all tags |
| `decode_heap_row` | yes | codec + insert reopen; bad version | happy; bad version → Engine |
| `null_bitmap_*` / `field_payload_size` | yes | codec roundtrip | set/get via NULL column |

---

## INSERT bind/exec (`src/exec/dml_insert.odin`, `result.odin`, `exec.odin`) — 12 / 12

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `is_ipk_type_name` / `is_integer_primary_key` / `find_ipk_column` / `count_primary_key_columns` | yes | INT/INTEGER IPK tests; composite reject | sole INTEGER/INT PK; composite → no IPK |
| `validate_primary_key_shape` | yes | `test_create_rejects_composite_primary_key`; `test_create_rejects_non_integer_primary_key` | composite; TEXT/REAL/VARCHAR PK |
| `catalog_default_to_value` | yes | `test_insert_uses_column_default` | Integer default |
| `resolve_omitted_column` | yes | default insert; INT IPK omit; NOT NULL omit | default; IPK NULL; NOT NULL → Constraint |
| `bind_insert_column_map` | yes | named columns; Unknown_Column | implicit order; named; unknown |
| `build_insert_row_values` | yes | multi-row; NOT NULL; arity | arity mismatch; NOT NULL NULL |
| `allocate_rowid` | yes | auto IPK; INT IPK; explicit PK; next_rowid | NULL IPK; explicit; high-water |
| `exec_insert` | yes | all insert_* tests | happy; Unsupported_Ast shapes; Constraint; Unknown_*; multi-row rollback |
| `rows_affected_result` | yes | insert reopen / multi-row | kind=Rows_Affected + count |
| `exec_statement_ast` Insert arm | yes | insert + unsupported update | INSERT dispatched |

---

## DDL default + catalog helper — 5 / 5

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `column_from_def` Default arm | yes | `test_create_accepts_literal_default`; non-literal reject | literal/NULL ok; expr → Unsupported_Ast |
| `free_bound_columns` | yes | create paths (defer) | frees default_bytes |
| `catalog_update_next_rowid` | yes | `test_insert_rowid_allocation_persists_next_rowid` | durable across reopen |
| catalog encode/decode `Has_Default` | yes | create default + get entry | Integer + Text defaults |
| `catalog_default_payload_size` | yes | encode path via create default | sized correctly (roundtrip) |

---

## CLI E2 surface — 1 / 1

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `run_sql` INSERT path | yes | `test_run_sql_create_insert_survives_reopen` | CREATE+INSERT; `N rows`; reopen decode |

---

## Branch matrix (required)

| Branch | Asserted |
|--------|----------|
| encode/decode all value kinds + NULL | yes |
| insert → reopen → `table_get_row` + decode | yes |
| multi-row VALUES | yes |
| multi-row mid-statement failure → rollback (first row not durable) | yes — `test_insert_multi_row_mid_failure_rolls_back` |
| named column list (incl. reordered) | yes |
| NULL value | yes |
| NOT NULL violation → `Constraint` | yes |
| IPK autoallocate + `next_rowid` persist (`INTEGER` and `INT`) | yes |
| explicit IPK bumps `next_rowid` | yes |
| duplicate rowid → `Constraint` | yes |
| composite PRIMARY KEY → `Unsupported_Ast` | yes |
| non-integer PRIMARY KEY → `Unsupported_Ast` | yes |
| column DEFAULT literal used on omit | yes |
| `X'…'` blob literal INSERT | yes — `test_insert_blob_literal_x_hex` |
| `INSERT OR REPLACE` / `OR IGNORE` → `Unsupported_Ast` | yes |
| `INSERT … SELECT` → `Unsupported_Ast` | yes |
| `DEFAULT VALUES` → `Parse` | yes |
| Unknown column / table codes | yes |
| INSERT no longer in unsupported-kinds list | yes |
| CLI CREATE + INSERT durable | yes |

---

## New error codes (E2)

| Code | When |
|------|------|
| `Unknown_Column` | INSERT column list name missing from catalog |
| `Constraint` | NOT NULL; duplicate rowid; non-integer IPK value |
| `Unsupported_Ast` | (also) composite PK; non-`INTEGER`/`INT` single-column PK |

---

## Ratio

| Bucket | Covered | Total |
|--------|---------|-------|
| Row codec + Value | 18 | 19 |
| INSERT bind/exec | 12 | 12 |
| DDL default + catalog | 5 | 5 |
| CLI E2 | 1 | 1 |
| **Combined** | **36** | **37** |

**36/37 = 97.3% ≥ 80% → PASS**

(Uncovered: `clone_value` only.)
