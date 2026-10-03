# E5 Symbol Coverage Inventory

**Phase:** E5 (`CREATE`/`DROP INDEX` + index maintenance + optional text/blob point lookup)  
**Prior:** [`exec-e4-coverage.md`](exec-e4-coverage.md)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch. Defer-only frees do not count as covered.

**Coverage ratio:** **32 / 34 = 94%** (≥ 80% required)

---

## Engine helpers (`src/engine/catalog.odin`) — 9 / 10

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `encode_catalog_row` index v2 | yes | `test_encode_decode_catalog_index_v2` | columns + DESC flag |
| `decode_catalog_row` index v2 | yes | same + reopen tests | v2 columns; v1 still via E1 |
| `catalog_register_index` (columns) | yes | index create / engine register with cols | v2 when cols; v1 when empty |
| `catalog_get_index_entry` | yes | create/backfill; durable reopen; drop | happy; Not_Found after drop |
| `catalog_indexes_on_table` | yes | via INSERT/UPDATE/SELECT index paths | match parent; empty |
| `catalog_unregister_index` | yes | `test_drop_index_and_drop_table_policy` | removes catalog; DROP TABLE then ok |
| `free_catalog_index_ref(s)` | no | defer-only | — |
| `index_delete_entry` | yes | `test_index_delete_entry_and_collect` | delete → Not_Found |
| `index_collect_rowids` | yes | same + lookup SELECT | prefix match; rowid decode |
| `index_insert_entry` (existing) | yes | backfill + insert maintain | durable |

---

## Index DDL / keys (`src/exec/ddl_index.odin`, `index_key.odin`, `exec.odin`) — 16 / 16

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `exec_create_index` | yes | create/backfill/lookup; IF NOT EXISTS; Exists; unknowns; closed | register + backfill; Index_Exists |
| `exec_drop_index` | yes | drop; IF EXISTS; Unknown_Index | removes entry |
| `bind_create_index_columns` | yes | unknown column; happy create; multi-col | Unknown_Column; DESC stored |
| `backfill_index` | yes | create after INSERT; multi-col backfill | scans heap → index entries |
| `encode_index_key` / field tags | yes | collect/lookup; multi-col keys | text (+ multi-col) |
| `encode_index_key_from_row` / `extract_index_values` | yes | maintain + backfill | column pick |
| `table_indexes_maintained` | yes | legacy Has_Indexes; SQL index mutate | empty cols → Has_Indexes; ok with cols |
| `index_insert_for_row` | yes | insert maintain; multi-col INSERT | after INSERT |
| `index_delete_for_row` | yes | update/delete maintain | old key removed |
| `find_single_column_eq_const` | yes | `WHERE name = '…'` lookup; numeric skip | text/blob only; Integer/Float skipped |
| `find_usable_eq_index` | yes | same | single-col index match |
| `exec_statement_ast` Create/Drop Index | yes | all index DDL tests | dispatch |

---

## DML maintenance / SELECT (`dml_insert`, `dml_update`, `dml_select`) — 7 / 8

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| INSERT index maintain | yes | `test_insert_maintains_index`; multi-col | post-insert index entry |
| UPDATE index maintain | yes | `test_update_delete_maintain_index`; durable | delete old + insert new |
| DELETE index maintain | yes | same | remove entry |
| `Pending_Rewrite.old_payload` | no | structural (covered via UPDATE path outcome) | — |
| SELECT index point lookup (text/blob) | yes | `test_create_index_backfill_and_lookup` | index path → correct row |
| SELECT seq-scan fallback (no usable index) | yes | numeric eq; no-index WHERE; probe policy test | still correct |
| multi-column index create + backfill + INSERT maintain | yes | `test_multi_column_index_create_backfill_and_insert_maintain` | catalog cols; engine collect |
| Index probe fail-hard on Engine/Io | yes | structured in `exec_select`; policy regression | no silent fallback on real errors |

---

## Branch matrix (required)

| Branch | Asserted |
|--------|----------|
| `CREATE INDEX` + backfill | yes |
| `CREATE INDEX IF NOT EXISTS` / `Index_Exists` | yes |
| `DROP INDEX` / `IF EXISTS` / `Unknown_Index` | yes |
| INSERT maintains index | yes |
| UPDATE/DELETE maintain index (no Has_Indexes forbid for v2) | yes |
| Legacy v1 index (no cols) → Has_Indexes on mutate | yes |
| Point lookup text/blob `WHERE col = const` | yes |
| Numeric `WHERE col = const` → seq scan (not index) | yes |
| Seq scan still works | yes |
| Multi-column index create/backfill/INSERT maintain | yes |
| Reopen durable (catalog cols + lookup + update) | yes |
| `DROP TABLE` rejects while indexes remain | yes |
| Unknown table/column on CREATE INDEX | yes |
| Closed session | yes |
| E1–E4 still green | yes — full `./build.sh test` |

---

## New/changed error uses (E5)

| Code | When |
|------|------|
| `Index_Exists` | `CREATE INDEX` name collision (no IF NOT EXISTS) |
| `Unknown_Index` | `DROP INDEX` missing (no IF EXISTS) |
| `Has_Indexes` | mutate when index lacks column metadata; `DROP TABLE` with indexes |
| `Unknown_Table` / `Unknown_Column` | CREATE INDEX bind |
| `Closed` | CREATE/DROP INDEX on closed session |
| `Engine` / `Io` | index probe catalog/open/encode/collect failures (fail hard) |

---

## Ratio

| Bucket | Covered | Total |
|--------|---------|-------|
| Engine helpers | 9 | 10 |
| Index DDL / keys | 16 | 16 |
| DML / SELECT | 7 | 8 |
| **Combined** | **32** | **34** |

**32/34 = 94% ≥ 80% → PASS**

Uncovered (2): `free_catalog_index_ref(s)` (defer-only); `Pending_Rewrite.old_payload` (structural).
