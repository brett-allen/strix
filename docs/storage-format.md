# Strix Storage Format

**Version:** 0.4.5  
**Status:** B+tree pages (S3); `table_prime` catalog + mandatory root ownership (S4); table catalog payload **v2** (E1); heap row payload (E2); index catalog payload **v2** + index key tags (E5)  
**Companion:** [`storage-engine.md`](storage-engine.md), [`btrees.md`](btrees.md), [`sql-execute.md`](sql-execute.md)

Strix uses a **native** single-file, page-oriented format. It is **not** SQLite-compatible.

---

## Global rules

| Rule | Value |
|------|--------|
| Endianness | Little-endian |
| Page numbering | **0-based** |
| Page 0 | Bootstrap meta page (not a B+tree leaf) |
| Default page size | **4096** bytes |
| Page size | Power of two in `[512, 65536]`; **frozen at create** |
| Durability files (v1) | Single DB file only (no `-wal` / `-journal`) |

---

## Page 0 — bootstrap header (v0.1 / still current)

The first **40** bytes of page 0 are the bootstrap header. The remainder of page 0 is **reserved** and must be zero through format v0.2.

| Offset | Size | Type | Field | Notes |
|--------|------|------|-------|-------|
| 0 | 8 | bytes | `magic` | ASCII `StrixDB` + `0x00` |
| 8 | 2 | u16 | `format_version` | `1` for this document |
| 10 | 2 | u16 | `reserved0` | Must be `0` (rejected on open if non-zero) |
| 12 | 4 | u32 | `page_size` | Frozen at create |
| 16 | 4 | u32 | `page_count` | Includes page 0; at least `1`. **Owned by pager** — updated on `flush` |
| 20 | 4 | u32 | `freelist_head` | `Page_No`; `0` = empty freelist |
| 24 | 4 | u32 | `commit_counter` | Monotonic commit generation (S2); `0` until used |
| 28 | 4 | u32 | `schema_cookie` | Catalog change counter; bumped in-txn on register; persisted on commit; restored on rollback |
| 32 | 4 | u32 | `table_prime_root` | `Page_No` of current `table_prime` root; `0` = unset; must be `< page_count` if non-zero |
| 36 | 4 | u32 | `checksum` | CRC-32 of bytes `[0..36)` (checksum field not included in input) |
| 40 | `page_size - 40` | bytes | `reserved` | Must be zero through v0.2 |

### Magic

```text
Offset:  0  1  2  3  4  5  6  7
Bytes:  53 74 72 69 78 44 42 00
ASCII:   S  t  r  i  x  D  B \0
```

### Checksum

- Algorithm: CRC-32 (`core:hash.crc32`, IEEE polynomial, seed `0`).
- Input: header bytes `[0 .. 36)` exactly (magic through `table_prime_root`).
- On open, `dbfile` rejects a mismatched checksum (`.Bad_Checksum`).
- On open, bad magic yields `.Bad_Magic`; unsupported `format_version` yields `.Bad_Version`.
- Non-zero `reserved0` yields `.Invalid_Argument`.

### Open validation

1. Read at least the 40-byte header from offset 0.
2. Verify magic, `format_version == 1`, `reserved0 == 0`, valid power-of-two `page_size`, `page_count >= 1`.
3. Verify checksum.
4. Require file byte length `>= page_count * page_size`.

### Page count contract (S1)

- `dbfile.write_page` may grow the physical file and its in-memory `page_count`.
- The **authoritative durable** `page_count` and `freelist_head` are written by `paging.flush` into page 0.
- Until flush, the pager tracks logical `page_count` / `freelist_head` in memory (txn state).

---

## Freelist trunk pages (v0.2 / S1)

Free pages form a singly-linked list headed by bootstrap `freelist_head`.

| Offset | Size | Type | Field |
|--------|------|------|-------|
| 0 | 4 | u32 | `next_free` — next free `Page_No`, or `0` for end of list |
| 4 | `page_size - 4` | bytes | unused (zeroed on free in S1) |

Rules:

- Page 0 is never on the freelist.
- `alloc_page`: pop `freelist_head` if non-zero; else extend logical `page_count`.
- `free_page`: push page onto the list (write `next_free = old head`, set head = page).
- Freelist trunk bytes are persisted with other dirty data pages on flush.

---

## B+tree pages (v0.3 / S3)

B+tree nodes occupy normal data pages (`page_no >= 1`). Payloads live in **leaves only**; interiors hold separator keys + child page numbers. Leaves are linked via `next_leaf` for range scans.

### Common header (12 bytes)

| Offset | Size | Type | Field |
|--------|------|------|-------|
| 0 | 1 | u8 | `page_type` — `1` = leaf, `2` = interior |
| 1 | 1 | u8 | `flags` — must be `0` in v0.3 |
| 2 | 2 | u16 | `n_cells` |
| 4 | 2 | u16 | `cell_area` — byte offset where cell heap starts |
| 6 | 2 | u16 | `reserved` — `0` |
| 8 | 4 | u32 | `special` — leaf: `next_leaf` page_no (`0` = none); interior: rightmost child page_no |

Cell pointer array: `n_cells` × u16 LE at offset 12, each pointing to a cell within the page.  
Cells grow downward from the end of the page; pointers grow upward from the header (slotted page).

### Leaf cell

| Field | Size | Notes |
|-------|------|-------|
| `key_len` | u16 | |
| `payload_len` | u16 | |
| `key` | `key_len` | memcmp / lexicographic byte order |
| `payload` | `payload_len` | opaque bytes |

### Interior cell

| Field | Size | Notes |
|-------|------|-------|
| `left_child` | u32 | child page for keys **strictly less than** this separator |
| `key_len` | u16 | |
| `key` | `key_len` | separator (copy of first key of the right subtree) |

Children of an interior with cells `k0..k_{n-1}` and rightmost `R`:

- `left_child(k_i)` holds keys in `[k_{i-1}, k_i)` (with `k_{-1} = −∞`)
- `R` holds keys `>= k_{n-1}`

### Split rules (v0.3)

- **Leaf split:** size-aware mid so **both** halves fit; pack both images in scratch before publishing; separator = first key of the right leaf; update `next_leaf` links. If no safe mid exists, insert fails with `.Too_Large` and **no** btree pages are left wiped/partial.
- **Interior split:** same scratch-then-publish discipline; promote a separator chosen so both sides fit.
- **Root split:** allocate new interior root (height + 1) only after the root image packs successfully.
- **Delete:** remove leaf cell only (no merge / borrow yet).

Trees are addressed by **root page_no**. User tables and indexes are registered in **`table_prime`** (S4). Mutations require an engine transaction; durability is the existing flush protocol.

---

## `table_prime` catalog (v0.4 / S4)

`table_prime` is a reserved B+tree whose root page number is stored in bootstrap **`table_prime_root`**. It is created empty on `engine_create` / `engine_open_memory` and must be non-zero on `engine_open`.

### Catalog btree keys (memcmp order)

| Object | Key format | Example |
|--------|------------|---------|
| User table | `table:` + UTF-8 name | `table:users` |
| Secondary index | `index:` + UTF-8 name | `index:users_by_name` |

Names are case-sensitive. Keys sort with all `index:` entries before `table:` (`i` < `t`).

### Catalog row payload

All multi-byte integers are **little-endian**.

#### Index rows v1 (legacy)

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0 | 1 | `version` | `1` |
| 1 | 1 | `kind` | `2` = index |
| 2 | 4 | `root_page` | Index btree root |
| 6 | 2 | `parent_name_len` | Byte length of parent table name |
| 8 | `parent_name_len` | `parent_table` | UTF-8 table name |

Legacy index rows are `8 + parent_name_len` (no column list). Readers still accept v1. SQL `CREATE INDEX` (E5) writes **v2**. Indexes without column metadata cannot be maintained by UPDATE/DELETE/INSERT — the executor rejects those mutations with `Has_Indexes`.

#### Index rows v2 (current — E5)

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0 | 1 | `version` | `2` |
| 1 | 1 | `kind` | `2` = index |
| 2 | 4 | `root_page` | Index btree root |
| 6 | 2 | `parent_name_len` | Byte length of parent table name |
| 8 | `parent_name_len` | `parent_table` | UTF-8 table name |
| 8+N | 2 | `col_count` | Number of indexed columns |
| … | … | `columns[]` | Repeated `col_count` times (below) |

Each index column record:

| Field | Size | Notes |
|-------|------|-------|
| `name_len` | u16 LE | |
| `name` | `name_len` | UTF-8 column name (must exist on parent table) |
| `flags` | u8 | bit0 = `DESC` (catalog only; key bytes are always ASC-encoded for v1 keys) |

#### Table rows v1 (legacy)

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0 | 1 | `version` | `1` |
| 1 | 1 | `kind` | `1` = table |
| 2 | 4 | `root_page` | Heap btree root |

Legacy **6-byte** table rows (roots only). Readers still accept v1; new `CREATE TABLE` / `catalog_register_table` writes **v2**.

#### Table rows v2 (current)

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0 | 1 | `version` | `2` |
| 1 | 1 | `kind` | `1` = table |
| 2 | 4 | `root_page` | Heap btree root |
| 6 | 8 | `next_rowid` | High-water for implicit / IPK (`INTEGER` or `INT PRIMARY KEY`) rowid allocation; starts at `1` |
| 14 | 2 | `col_count` | Number of columns |
| 16 | … | `columns[]` | Repeated `col_count` times (see below) |

Each column record:

| Field | Size | Notes |
|-------|------|-------|
| `name_len` | u16 | |
| `name` | `name_len` | UTF-8 column name |
| `type_name_len` | u16 | `0` if type omitted |
| `type_name` | `type_name_len` | UTF-8 type name string (affinity later) |
| `flags` | u8 | bit0 = `NOT NULL`, bit1 = `PRIMARY KEY`, bit2 = `Has_Default` |
| `default` | … | Present only when `Has_Default` is set (see below) |

Default payload (when `Has_Default`):

| Field | Size | Notes |
|-------|------|-------|
| `default_kind` | u8 | `1`=NULL, `2`=integer, `3`=float, `4`=text, `5`=blob |
| payload | … | NULL: empty; integer: i64 LE; float: f64 LE; text/blob: u32 LE length + bytes |

Columns without `Has_Default` omit the default trailer (same layout as E1 v2 columns). Empty tables (engine register with no schema) use `col_count = 0` and still store `next_rowid`. Root / `next_rowid` updates rewrite the same version/size in place.

### User table data btree

- **Key:** 8-byte **big-endian** `rowid` (`u64`) for memcmp numeric order.
- **Payload:** heap row record (below).

### Heap row payload (E2)

Leaf payloads for user tables are encoded by `src/exec` (`encode_heap_row` / `decode_heap_row`). All multi-byte integers in the payload are **little-endian**.

```text
version u8 | col_count u16 | null_bitmap | concatenated field encodings
```

| Field | Size | Notes |
|-------|------|-------|
| `version` | u8 | `1` |
| `col_count` | u16 LE | Number of columns (matches catalog order) |
| `null_bitmap` | `ceil(col_count / 8)` bytes | Bit `i` set ⇒ column `i` is NULL |
| fields | … | One encoding per **non-NULL** column, in column index order |

Non-NULL field encoding:

| `tag` (u8) | Payload |
|------------|---------|
| `1` Integer | i64 LE |
| `2` Float | f64 LE |
| `3` Text | u32 LE byte length + UTF-8 bytes |
| `4` Blob | u32 LE byte length + bytes |

NULL columns appear only in the null bitmap (no tag/payload). A sole `INTEGER` or `INT PRIMARY KEY` column (IPK) aliases the btree rowid key; the column value is still stored in the payload when present. Composite / non-integer PRIMARY KEY shapes are rejected by the executor until UNIQUE enforcement exists.

### Secondary index btree

- **Key:** `index_key_bytes` || **8-byte BE rowid** (composite unique key).
- **Payload:** empty in v1 (rowid is in the key suffix).

Registration and opens go through `engine` catalog APIs (`catalog_register_*`, `catalog_open_*`, `catalog_unregister_index`).

#### Secondary index key bytes (E5)

`index_key_bytes` is the concatenation of one tagged field per indexed column (ASC encoding; `DESC` is catalog metadata only):

| Tag (u8) | Payload |
|----------|---------|
| `0` NULL | (none) |
| `1` Integer | u64 BE of `i64` bits with high bit flipped (signed memcmp order) |
| `2` Float | u64 BE of IEEE-754 bits after SQLite-style order transform (positive: flip sign bit; negative: flip all bits) so `memcmp` matches numeric order |
| `3` Text | u32 BE length + UTF-8 bytes + `0x00` |
| `4` Blob | u32 BE length + bytes + `0x00` |

Executor helpers: `encode_index_key` / `index_insert_entry` / `index_delete_entry` / `index_collect_rowids`.

### Root ownership rule (mandatory)

A B+tree handle **must** have root ownership before a root-changing split:

| Bind | How obtained | On root split |
|------|----------------|---------------|
| `Caller_Root` | `btree_create(e, root: ^Page_No)` / `btree_open(e, root: ^Page_No)` | Writes new root into caller’s `^Page_No` |
| `Table_Prime` | `table_prime_tree` / `engine_ensure_catalog` | Updates `Engine.table_prime_root` (page 0 on commit) |
| `Catalog_Object` | `catalog_open_table` / `catalog_open_index` | Updates that object’s `table_prime` row `root_page` |
| `None` | Invalid for growth | Root split returns `.Unbound_Root` (no silent orphan) |

Catalog-backed tables/indexes **must** be opened via `catalog_open_*` (not a bare page number with forgotten slot). Ephemeral/test trees **must** keep the caller `^Page_No` alive for the handle’s lifetime.

**`schema_cookie`:** incremented in-transaction when catalog rows are registered; written to page 0 on commit; restored from the txn-begin snapshot on rollback.

---

## Freelist vs btree pages

A page is either on the freelist **or** in a btree (or unused after rollback). Freelist trunk format (above) is unrelated to btree headers — do not interpret freelist pages as btree nodes.

On open, `freelist_head` and `table_prime_root` must be `0` or strictly less than `page_count`.

---

## Commit write order (enforced by `paging.flush`)

1. Write dirty **data pages** (`page_no >= 1`) in ascending `page_no` order.
2. Write **page 0** last (updated `page_count`, `freelist_head`, caller meta, checksum).
3. `dbfile.sync()` (`fsync`) once.

Crash during a multi-page flush may leave a torn file in v1 (no WAL yet).

If flush fails after writing one or more data pages, the pager sets a **`flush_failed` fence**: `discard_dirty` / `txn_rollback` / `pager_close` return `.Flush_Failed` until a subsequent flush succeeds (v1 recovery: retry flush / `COMMIT` / `txn_commit` **on the still-open session**; no WAL). Auto-commit flush failure promotes the session to `explicit_txn` so SQL can retry `COMMIT` (see [`sql-execute.md`](sql-execute.md)).

`engine_close` / `session_close` / `shell_state_destroy` must **refuse to close** while the fence is live — they return `.Flush_Failed` and leave the pager, dirty frames, and file handle intact so recovery `COMMIT` can retry. They must never `pager_close` over a live fence (that would destroy the only recovery state). There is no default “surface then close” path.

Rollback (no durability, and only when not fenced): `paging.discard_dirty` drops dirty cache frames and restores `page_count` / `freelist_head` to the last successful flush (or open). The engine also restores `schema_cookie` and `table_prime_root` from the txn-begin snapshot.

**DROP TABLE / DROP INDEX:** unregister removes the catalog row and walks the object btree to return **all** pages (not only the root) to the freelist.

---

## Package mapping

| Concern | Package |
|---------|---------|
| Header encode/decode, page R/W, sync | `src/dbfile` (`package dbfile`) |
| Cache / freelist / flush | `src/paging` (`package paging`) |
| Txns, btree, `table_prime` | `src/engine` (`package engine`) |

---

## Changelog

| Ver | Date | Notes |
|-----|------|-------|
| 0.1 | 2026-10-02 | Freeze page 0 layout for Phase S0 |
| 0.2 | 2026-10-02 | Freelist trunk page shape; page_count owned by pager flush (S1) |
| 0.3 | 2026-10-02 | B+tree leaf/interior slotted page format (S3) |
| 0.4 | 2026-10-02 | `table_prime` catalog keys and row payload v1 (S4) |
| 0.4.1 | 2026-10-03 | Root write-through; schema_cookie txn semantics; flush_failed fence |
| 0.4.2 | 2026-10-03 | Mandatory root ownership (`Caller_Root` / catalog bind / `.Unbound_Root`) |
| 0.4.3 | 2026-10-03 | Table catalog payload v2 (`columns[]` + `next_rowid`); index rows remain v1 |
| 0.4.4 | 2026-10-03 | Heap row payload v1; optional column `Has_Default` trailer on catalog v2 |
| 0.4.5 | 2026-10-03 | Index catalog payload v2 (`columns[]` + DESC flag); index key byte tags (E5) |
