# F3 Symbol Coverage Inventory

**Phase:** F3 (Native `BOOLEAN` + typed `UUID`)  
**Plan:** [`sql-followon.md`](sql-followon.md) § Phase F3  
**Prior:** S1/S2 type/`CAST` inventories; F2 PK  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch. Docs-only notes and stretch goals are listed under Deferred and are **not** in the denominator.

**Coverage ratio:** **39 / 39 = 100%** (≥ 80% required)

Section sums: Value 9 + Lexer 3 + Bind 8 + Eval 10 + Index 5 + Polish 4 = **39**. Covered cells: all **39**. Ratio **39/39 = 100%**.

**Storage choices (locked):**
- `Value_Kind.Boolean` — heap/index tag `5`, payload u8 0/1; `TRUE`/`FALSE` keywords
- `Value_Kind.Uuid` — heap/index tag `6`, fixed 16 bytes; canonical lowercase 8-4-4-4-12 I/O
- Catalog `DEFAULT` kinds: Boolean=`6` (u8), Uuid=`7` (16 bytes) — see [`storage-format.md`](storage-format.md)
- No ambient affinity; UUID column string bind is typed validate→store (documented)

---

## Value / codec (`value.odin` + `row.odin`) — 9 / 9

| Symbol / concern | Tested? | Test name(s) | Branches covered |
|------------------|---------|--------------|------------------|
| `Value_Kind.Boolean` / `value_boolean` | yes | `test_boolean_*`; heap codec | TRUE/FALSE |
| `Value_Kind.Uuid` / `value_uuid` | yes | `test_uuid_*`; heap codec | 16-byte |
| `parse_uuid_text` hyphenated | yes | insert/select + index encode | 8-4-4-4-12 |
| `parse_uuid_text` 32-hex | yes | `test_parse_uuid_text_32_hex` | accept path + INSERT |
| `format_uuid_canonical` | yes | round-trip display lowercase | mixed-case insert |
| Heap encode/decode Boolean | yes | `test_heap_row_boolean_uuid_codec` | tags 5 |
| Heap encode/decode Uuid | yes | same + `test_uuid_typed_roundtrip_and_pk` | tag 6 |
| Corrupt Boolean byte >1 | yes | `test_corrupt_heap_boolean_byte` | Engine reject |
| `clone_value` / `free_value` Uuid | yes | round-trip paths | owned bytes |

---

## Lexer / parser — 3 / 3

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| `TRUE` / `FALSE` keywords | yes | `test_expr_literals` | `.Boolean` |
| Parse as literal | yes | same + exec projection | case fold |
| INSERT/WHERE/projection | yes | `test_boolean_true_false_literals_and_column` | all three |

---

## Bind / DML (`declared_storage_kind` / coerce) — 8 / 8

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| `BOOLEAN` → Boolean kind | yes | boolean insert/select | enforced |
| `UUID` → Uuid kind | yes | uuid PK round-trip | enforced |
| Integer → BOOLEAN reject | yes | `test_boolean_kind_mismatch_and_cast` | `Constraint` |
| Text → UUID coerce OK | yes | uuid insert | typed store |
| Malformed UUID string | yes | `test_uuid_malformed_and_wrong_kind` | `Constraint` |
| Wrong kind into UUID | yes | same (`VALUES (1,…)`) | `Constraint` |
| UPDATE SET + coerce | yes | `CAST(1 AS BOOLEAN)` SET | success |
| `BOOL` alias | yes | `test_bool_alias_declared_storage` | `declared_storage_kind` |

---

## Eval / CAST / compare — 10 / 10

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| Bool context Boolean | yes | `WHERE ok` / `NOT ok` | keep/drop |
| `CAST` Integer→Boolean | yes | SET + projection | TRUE |
| `CAST` Boolean→Integer/Text | yes | projection | 1 / TRUE |
| `CAST` Text→UUID / UUID→Text | yes | `test_cast_happy_paths_projection` | canonical |
| `CAST` invalid UUID text | yes | cast reject + malformed test | `Unsupported_Ast` |
| Boolean = Boolean | yes | `WHERE ok = TRUE` | match |
| Boolean = Integer reject | yes | `WHERE ok = 1` | `Unsupported_Ast` |
| Uuid = Text string form | yes | `WHERE id = '…'` | PK lookup |
| `CAST` Blob→UUID (16) | yes | `test_cast_text_boolean_and_blob_uuid` | matrix cell |
| `CAST` Text TRUE/FALSE → Boolean | yes | same | matrix cell |

---

## Index / durable — 5 / 5

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| `encode_index_key` Uuid+Boolean | yes | `test_uuid_index_key_encode` | tags 5/6 |
| UUID PK unique index | yes | dup insert `Constraint` | autoindex |
| Durable reopen Boolean/UUID | yes | `test_boolean_uuid_durable_reopen` | DEFAULT TRUE |
| Index point lookup UUID | yes | `WHERE id = '…'` after reopen/PK tests | coerce Text→Uuid |
| `CREATE INDEX` on BOOLEAN | yes | `test_create_index_on_boolean` | secondary + WHERE |

---

## Polish / DEFAULT — 4 / 4

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| `SUM(i64)` overflow | yes | `test_sum_i64_overflow_fail_closed` | `Unsupported_Ast` |
| DEFAULT TRUE | yes | durable reopen omit `ok` | TRUE |
| DEFAULT UUID string | yes | `test_default_uuid_and_schema_print` | catalog Uuid default |
| Schema print Boolean/UUID default | yes | same (`schema_sql`) | introspect |

---

## Branch matrix (required)

| Branch | Asserted |
|--------|----------|
| `CREATE TABLE … (ok BOOLEAN, id UUID PRIMARY KEY)` | yes |
| `TRUE`/`FALSE` projection / WHERE / INSERT | yes |
| Typed Uuid heap (not Text) | yes |
| Malformed UUID → `Constraint` | yes |
| CAST matrix BOOLEAN/UUID | yes (incl. Text→Boolean, Blob→UUID) |
| Index tags + durable reopen | yes |
| SUM i64 overflow fail-closed | yes |
| No Integer→BOOLEAN affinity | yes |

---

## Deferred / out of scope

- UUID version/variant validation beyond parse
- Three-valued BOOLEAN beyond NULL
- Ambient affinity / SQLite-style coerce
- F4 prepared `?` binding
- Migrating pre-F3 on-disk Text-tagged “UUID” rows automatically (docs-only dialect note; not a coverage cell)
- Composite PK including UUID (stretch; F2 composite PK already covered without UUID column)
