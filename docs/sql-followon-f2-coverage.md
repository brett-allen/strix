# F2 Symbol Coverage Inventory

**Phase:** F2 (Composite `PRIMARY KEY`)  
**Plan:** [`sql-followon.md`](sql-followon.md) § Phase F2  
**Prior:** [`sql-compliance-s3-coverage.md`](sql-compliance-s3-coverage.md) (single-col PK / UNIQUE)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch.

**Coverage ratio:** **24 / 27 = 88.9%** (≥ 80% required)

---

## Bind / DDL (`ddl.odin` + `dml_insert.odin`) — 10 / 12

| Symbol / concern | Tested? | Test name(s) | Branches covered |
|------------------|---------|--------------|------------------|
| Table `PRIMARY KEY (c1, c2)` accept | yes | `test_create_accepts_composite_primary_key`; `test_composite_pk_crud_duplicate_and_null` | ≥2 cols; flags PK+NOT NULL |
| Composite unique autoindex created | yes | `test_create_accepts_composite_primary_key`; durable reopen | `strix_autoindex_<t>_1` unique; 2 cols |
| `collect_create_table_unique_sets` composite | yes | create + schema + CRUD | non-IPK multi-col set |
| Sole IPK skips autoindex | yes | `test_ipk_regression_no_autoindex` | unchanged (A) |
| Conflicting column PK + table PK | yes | `test_create_rejects_conflicting_primary_key` | `Invalid_Schema` |
| Multiple table `PRIMARY KEY` | no | — | second constraint untested |
| Duplicate col in `PRIMARY KEY (a, a)` | no | — | `Invalid_Schema` untested |
| Column-level multi PK → composite (not IPK) | yes | `test_composite_pk_never_aliases_rowid` | 2× `INTEGER PRIMARY KEY`; autoindex; NULL reject |
| `PRIMARY KEY` implies NOT NULL | yes | create accept + NULL insert | both cols |
| Unknown PK column name | yes | existing `test_create_rejects_unknown_pk_column` (ddl_test) | `Invalid_Schema` |
| Same-column column+table PK | yes | `test_create_accepts_non_integer_primary_key` (`t_tbl`) | still allowed |
| `validate_primary_key_shape` allows composite | yes | composite create/insert paths | no reject |

Uncovered (2): multiple table PRIMARY KEY; duplicate name inside PRIMARY KEY list.

---

## DML maintenance (`index_key` / insert / update / delete) — 7 / 7

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| INSERT maintains composite unique index | yes | `test_composite_pk_crud_duplicate_and_null` | success + dup `Constraint` |
| UPDATE PK collision | yes | same | `Constraint` |
| UPDATE non-PK column | yes | same (`SET n = 21`) | success |
| DELETE frees key for re-insert | yes | same | re-INSERT after DELETE |
| NULL in any PK column | yes | same | first and second col |
| Durable reopen + dup still fails | yes | `test_composite_pk_durable_reopen` | catalog index + Constraint |
| IPK INSERT/SELECT regression | yes | `test_ipk_regression_no_autoindex`; insert IPK tests | sole INTEGER PK |

---

## Schema / introspection — 3 / 3

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| `.schema` emits `PRIMARY KEY (a, b)` | yes | `test_composite_pk_schema_sql` | table constraint form |
| Hide composite PK autoindex in schema | yes | same | no `strix_autoindex_` |
| Multi-col UNIQUE in schema as `UNIQUE (…)` | yes | `test_multi_column_table_unique` | table constraint; no `strix_autoindex_*` dump |

---

## Rejects / regression — 4 / 5

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| IPK + different composite rejected | yes | `test_create_rejects_conflicting_primary_key` | `Invalid_Schema` |
| Composite never rowid alias | yes | `test_composite_pk_never_aliases_rowid` | no auto-NULL allocate |
| Single-col TEXT PK / UNIQUE unchanged | yes | existing unique_pk_test suite | S3 regression |
| DROP TABLE drops composite autoindex | yes | `test_composite_pk_crud_duplicate_and_null` | autoindex gone |
| Empty `PRIMARY KEY ()` | no | — | parser usually rejects first |

Uncovered (1): empty PRIMARY KEY list at exec (parser typically rejects).

---

## Branch matrix (required)

| Branch | Asserted |
|--------|----------|
| `CREATE TABLE … PRIMARY KEY (a, b)` | yes |
| Duplicate composite PK → `Constraint` | yes |
| NULL in PK col → `Constraint` | yes |
| INSERT/UPDATE/DELETE + index maintain | yes |
| Durable reopen | yes |
| IPK sole-column unchanged | yes |
| IPK + composite mix → `Invalid_Schema` | yes |
| Composite never aliases rowid | yes |

---

## New/changed error uses (F2)

| Code | When |
|------|------|
| `Constraint` | Duplicate composite PK; NULL in any PK column (same as UNIQUE / NOT NULL) |
| `Invalid_Schema` | Conflicting PRIMARY KEY constraints; multiple table PRIMARY KEY; duplicate col in PK list |
| ~~`Unsupported_Ast` composite PK~~ | **Removed** (F2 executes composite PK) |

**On-disk:** no format bump — column PK flags + index v2 column lists already sufficient ([`storage-format.md`](storage-format.md) unchanged).

---

## Ratio

| Bucket | Covered | Total |
|--------|---------|-------|
| Bind / DDL | 10 | 12 |
| DML maintenance | 7 | 7 |
| Schema / introspection | 3 | 3 |
| Rejects / regression | 4 | 5 |
| **Combined** | **24** | **27** |

**24/27 = 88.9% ≥ 80% → PASS**

Uncovered (3): multiple table PRIMARY KEY; duplicate col in PK list; empty PRIMARY KEY () at exec.
