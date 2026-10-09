# S2 Symbol Coverage Inventory

**Phase:** S2 (scalar `CAST`)  
**Plan:** [`sql-compliance.md`](sql-compliance.md) § Phase S2  
**Prior:** [`sql-compliance-s1-coverage.md`](sql-compliance-s1-coverage.md)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch.

**Coverage ratio:** **16 / 18 = 88.9%** (≥ 80% required)

---

## CAST eval (`src/exec/expr.odin`) — 14 / 16

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `eval_expr` `.Cast` → `eval_cast` | yes | `test_cast_happy_paths_projection`; WHERE/SET tests | projection, WHERE, SET |
| `eval_cast` | yes | happy + reject | NULL→NULL; target resolve; inner eval |
| `cast_target_kind` | yes | happy aliases; `CAST(… AS BOOLEAN)` reject | INT/REAL/TEXT/BLOB/UUID; unknown → error |
| `cast_value` identity | yes | `CAST(i AS INTEGER)` / `CAST(s AS TEXT)` / `CAST(b AS BLOB)` | same-kind clone |
| `cast_to_integer` Float→Int | yes | `CAST(f AS INTEGER)` → `3` from `3.5` | truncate toward zero |
| `cast_to_integer` Text→Int | yes | `CAST(s AS INT)`; whitespace/sign test; reject matrix; overflow rejects | digits+sign; reject garbage/`10x`/`10.5`/`0x10`/empty; reject `i64` max+1/min−1/oversized |
| `cast_to_integer` Blob→Int | yes | `CAST(b AS INTEGER)` | `Unsupported_Ast` |
| `cast_to_float` Int/Text | yes | `CAST(i AS REAL)`; `CAST(' 3.25 ' AS REAL)` | ok paths |
| `cast_to_float` Blob / bad text | yes | `CAST(b AS REAL)`; `CAST('nope' AS REAL)` | `Unsupported_Ast` |
| `cast_to_text` Int/Float/Blob | yes | `CAST(i AS TEXT)`; `CAST(f AS FLOAT)` display; `CAST(b AS TEXT)` → `AB` | format + blob-as-UTF-8 |
| `cast_to_text` VARCHAR/UUID | yes | `CAST(i AS VARCHAR)`; `CAST(s AS UUID)` | aliases → Text |
| `cast_to_blob` Text | yes | `CAST(s AS BLOB)` → `X'3939'` | UTF-8 bytes |
| `cast_to_blob` numeric reject | yes | `CAST(1 AS BLOB)`; `CAST(f AS BLOB)` | `Unsupported_Ast` |
| `parse_cast_integer_text` | yes | whitespace/sign happy; reject matrix; `test_cast_text_integer_overflow_rejects` | trim; `+/-`; digits only; `Out_Of_Range` (no wrap) |

Uncovered (2): `cast_to_integer` non-finite / out-of-range REAL (NaN/Inf/`f64` beyond `i64`); dedicated Float→BLOB already covered via column path.

---

## Declared-type shared mapping — 1 / 1

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `declared_storage_kind` UUID→Text | yes | `CAST(s AS UUID)` | UUID target accepted as Text |

---

## S1 interaction / regression — 1 / 1

| Concern | Tested? | Test name(s) | Branches covered |
|---------|---------|--------------|------------------|
| Text↔numeric still requires CAST | yes | `test_cast_s1_compare_still_rejects_without_cast` | bare `s = 10` → `Unsupported_Ast`; `CAST(s AS INTEGER) = 10` ok |

---

## Branch matrix (required)

| Branch | Asserted |
|--------|----------|
| `CAST` in projection | yes |
| `CAST` in `WHERE` | yes |
| `CAST` in `UPDATE SET` | yes |
| NULL → NULL | yes |
| Integer↔Text / Integer↔Real / Real→Integer truncate | yes |
| Text→Integer strict decimal (whitespace, sign) | yes |
| Text→Integer reject: garbage, partial, fractional, hex, empty | yes |
| Text→Integer reject: `i64` overflow (max+1, min−1, oversized) | yes |
| Text↔Blob | yes |
| Blob→numeric reject | yes |
| Numeric→Blob reject | yes |
| Unknown target (`BOOLEAN`) → `Unsupported_Ast` | yes |
| Type aliases: INT, FLOAT, DOUBLE, VARCHAR, UUID | yes |
| S1 compare without CAST still errors | yes |
| E1–E6 + S1 still green | yes — full `./build.sh test` |

---

## New/changed error uses (S2)

| Code | When |
|------|------|
| `Unsupported_Ast` | Unknown CAST target; invalid Text→numeric; Text→Integer out-of-`i64`-range; Blob↔numeric; numeric→Blob; non-finite/out-of-range Real→Integer (untested extremes) |

Invalid casts **never** become NULL (no affinity).

---

## Ratio

| Bucket | Covered | Total |
|--------|---------|-------|
| CAST eval | 14 | 16 |
| Declared-type UUID | 1 | 1 |
| S1 interaction | 1 | 1 |
| **Combined** | **16** | **18** |

**16/18 = 88.9% ≥ 80% → PASS**

Uncovered (2): Real→Integer NaN/Inf/range extremes (code present; same error class as other invalid casts).
