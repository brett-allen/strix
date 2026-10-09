# S3 Symbol Coverage Inventory

**Phase:** S3 (`UNIQUE` + TEXT/UUID PK)  
**Plan:** [`sql-compliance.md`](sql-compliance.md) § Phase S3  
**Prior:** [`sql-compliance-s2-coverage.md`](sql-compliance-s2-coverage.md)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch.

**Coverage ratio:** **26 / 29 = 89.7%** (≥ 80% required)

---

## PK shape / bind (`src/exec/dml_insert.odin`, `ddl.odin`) — 8 / 9

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `validate_primary_key_shape` | yes | `test_create_accepts_non_integer_primary_key`; `test_composite_pk_still_rejected` | zero/single PK ok; composite → `Unsupported_Ast` |
| `find_ipk_column` / IPK path | yes | `test_ipk_regression_no_autoindex`; `test_ipk_unique_skips_redundant_autoindex` | sole INTEGER PK; no autoindex; IPK+UNIQUE skips redundant autoindex |
| `column_from_def` `.Unique` | yes | `test_column_and_table_unique_enforced`; schema tests | Unique flag set |
| `bind_create_table_columns` PK → NOT NULL | yes | `test_create_accepts_non_integer_primary_key`; `test_text_pk_crud_and_null_reject` | Not_Null implied; NULL insert → `Constraint` |
| `bind_create_table_columns` table UNIQUE | yes | `test_column_and_table_unique_enforced`; `test_schema_sql_shows_table_level_single_unique`; `test_multi_column_table_unique` | single-col sets `.Unique`; multi-col index only |
| `collect_create_table_unique_sets` | yes | TEXT PK / UNIQUE / IPK tests | non-IPK PK; column UNIQUE; skip IPK; dedupe |
| `register_system_unique_indexes` | yes | `test_create_accepts_non_integer_primary_key`; durable reopen | `strix_autoindex_<table>_1` unique |
| `system_autoindex_name` / `is_system_autoindex_name` | yes | schema + DROP + reserved-prefix tests | naming; case-insensitive prefix; skip in `.schema` for single-col |

Uncovered (1): `append_unique_set_if_new` explicit duplicate UNIQUE+PK same column path (dedupe exercised implicitly when both declared; no dedicated assert).

---

## Unique index maintain (`src/exec/index_key.odin`, `ddl_index.odin`) — 8 / 9

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `catalog_index_is_unique` | yes | create unique index; TEXT PK reopen | Unique flag round-trip |
| `check_unique_index_collision` | yes | duplicate PK/UNIQUE/CREATE UNIQUE INDEX | other rowid → `Constraint`; same rowid ok on UPDATE |
| `index_key_has_null` | yes | `test_unique_allows_multiple_nulls` | NULL key skips uniqueness probe |
| `index_insert_for_row` unique path | yes | insert/update unique violation tests | probe + insert |
| `backfill_index` unique | yes | `test_create_unique_index_enforced` (pre-existing dups) | backfill → `Constraint` |
| `exec_create_index` `unique=true` | yes | `test_create_unique_index_enforced`; parse test | `CREATE UNIQUE INDEX` |
| `exec_create_index` reserved `strix_autoindex_` | yes | `test_create_index_rejects_system_autoindex_prefix` | case-insensitive prefix → `Invalid_Schema` |
| `drop_system_autoindexes_for_table` | yes | `test_text_pk_update_unique_and_drop_table` | DROP TABLE succeeds; autoindex gone |

Uncovered (1): `index_insert_for_row` btree `.Exists` after probe (rowid-suffix collision edge; same error class as Constraint).

---

## End-to-end / schema — 8 / 8

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| TEXT PK CRUD | yes | `test_text_pk_crud_and_null_reject` | insert/select/update/delete |
| TEXT PK durable reopen | yes | `test_text_pk_durable_reopen` | unique index persists; duplicate after reopen |
| UUID-as-TEXT PK | yes | `test_uuid_type_as_text_pk` | `UUID PRIMARY KEY` |
| `.schema` column PK/UNIQUE | yes | `test_schema_sql_shows_text_pk_and_unique` | PRIMARY KEY; column UNIQUE; hide single-col autoindex; emit user `CREATE UNIQUE INDEX` |
| `.schema` table-level single UNIQUE | yes | `test_schema_sql_shows_table_level_single_unique` | `UNIQUE (a)` → column UNIQUE in schema (no lost constraint) |
| Multi-col UNIQUE in schema | yes | `test_multi_column_table_unique` | emit table `UNIQUE (a, b)`; no `strix_autoindex_*` |
| `DROP INDEX` reserved autoindex | yes | `test_drop_index_rejects_system_autoindex` | case-insensitive; uniqueness still enforced |
| UPDATE PK collision | yes | `test_text_pk_update_unique_and_drop_table` | SET id to existing → `Constraint` |
| UPDATE TEXT PK to NULL | yes | `test_text_pk_update_null_constraint` | SET id = NULL → `Constraint` |

Note: table-level `PRIMARY KEY (col)` on TEXT is covered in `test_create_accepts_non_integer_primary_key` (`t_tbl`) under bind — not double-counted here.

---

## Parser — 2 / 3

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `CREATE UNIQUE INDEX` parse | yes | `test_create_unique_index_parse` | unique=true; IF NOT EXISTS; print |
| `CREATE INDEX` unique=false | yes | `test_create_index` | unchanged non-unique |
| `CREATE UNIQUE` without INDEX | no | — | error path untested |

---

## Branch matrix (required)

| Branch | Asserted |
|--------|----------|
| TEXT / VARCHAR / UUID single-column PK create | yes |
| NULL PK insert → `Constraint` | yes |
| Duplicate PK → `Constraint` | yes |
| Column UNIQUE violation | yes |
| Table UNIQUE (single + multi-col) | yes |
| `CREATE UNIQUE INDEX` + backfill collision | yes |
| UNIQUE allows multiple NULLs | yes |
| IPK unchanged (no autoindex; rowid dup Constraint) | yes |
| IPK + UNIQUE skips redundant autoindex | yes |
| Composite PK still rejected | yes |
| Durable reopen of TEXT PK + unique index | yes |
| DROP TABLE drops system autoindexes | yes |
| `.schema` shows PK/UNIQUE honestly (column + table-level single) | yes |
| Reserved `strix_autoindex_` index names rejected (CREATE + DROP) | yes |
| UPDATE TEXT PK to NULL → `Constraint` | yes |
| E1–E6 + S1–S2 still green | yes — full `./build.sh test` |

---

## New/changed error uses (S3)

| Code | When |
|------|------|
| `Constraint` | Duplicate PK/UNIQUE / unique index key; NULL on PK (`NOT NULL`); UNIQUE backfill collision |
| `Invalid_Schema` | `CREATE INDEX` / `CREATE UNIQUE INDEX` / `DROP INDEX` name starts with reserved `strix_autoindex_` (case-insensitive) |
| `Unsupported_Ast` | Composite PRIMARY KEY (unchanged) |

---

## Ratio

| Bucket | Covered | Total |
|--------|---------|-------|
| PK shape / bind | 8 | 9 |
| Unique index maintain | 8 | 9 |
| End-to-end / schema | 8 | 8 |
| Parser | 2 | 3 |
| **Combined** | **26** | **29** |

**26/29 = 89.7% ≥ 80% → PASS**

Uncovered (3): explicit PK+UNIQUE same-column dedupe assert; btree `.Exists` after unique probe; `CREATE UNIQUE` without `INDEX` parse error.
