# Plan: Storage Stack (`dbfile` / `paging` / `engine`)

Comprehensive plan for Strix’s on-disk storage and orchestration layers.

| Package dir | Responsibility |
|-------------|----------------|
| `src/dbfile/` | On-disk **file format** and **disk I/O** |
| `src/paging/` | **Page cache + page alloc**; reads/writes pages via `dbfile` |
| `src/engine/` | **Orchestrator** — sessions, txns, **B+tree**, **`table_prime` catalog**; later SQL |

Companion docs: [`btrees.md`](btrees.md), [`sql-parser.md`](sql-parser.md).  
Byte layout: [`storage-format.md`](storage-format.md) (v0.1 freezes page 0).

---

## Decisions (locked)

| Topic | Choice |
|-------|--------|
| File compatibility | **Strix-native** format (SQLite is inspiration only, not byte-compatible) |
| Durability v1 | **Neither WAL nor rollback journal** — simple flush+fsync protocol (see below) |
| B+tree location | **`src/engine/`** (`btree_*.odin` etc.) |
| Page numbering | **0-based**; **page 0** is the **bootstrap page** |
| Catalog | **`table_prime`** — bootstrap table holding schema info; rooted from page 0 |
| Low-level package name | **`dbfile`** (not `database`) to avoid product/layer confusion |
| Packages | `package dbfile`, `package paging`, `package engine` (match `sql` style) |

### Still open (minor)

| Topic | Default unless you override |
|-------|-----------------------------|
| SQL inside engine for storage v1? | **No** — storage API first; SQL execute = [`sql-execute.md`](sql-execute.md) (S5) |
| Sync on commit | **fsync** the DB file after flushing dirty pages (correctness > speed) |
| Attached DBs / multi-file | **Out of scope** (one `.strix`/DB file only for now) |

---

## Goals

- Single-file, Strix-native, page-oriented storage.
- Clear layering: `dbfile` → `paging` → `engine` → (later) SQL.
- B+tree tables/indexes under `engine` (see `btrees.md`).
- **Simple durability**: transactional dirty-set in memory; commit writes pages then `fsync`. Honest about crash limits until WAL lands later.
- Bootstrap catalog via **page 0** + **`table_prime`**.
- Testable per layer; **no upward imports**.

## Non-goals (storage v1)

- WAL / rollback journal (deferred; design flush so they can plug in later).
- SQLite file compatibility.
- Multi-writer / MVCC.
- Network protocol.
- Full SQL execution (parser exists; binder/exec can wait).
- Encryption, replication.

---

## Layering

```text
                 ┌──────────────────────────────────────────┐
                 │  src/engine                              │
                 │  open/close, txn begin/commit/rollback,  │
                 │  B+tree, table_prime catalog, cursors,   │
                 │  later: bind + execute SQL               │
                 └─────────────────┬────────────────────────┘
                                   │
                 ┌─────────────────▼────────────────────────┐
                 │  src/paging                              │
                 │  cache, pin/unpin, dirty, evict,         │
                 │  alloc/free page_no, flush dirty set     │
                 └─────────────────┬────────────────────────┘
                                   │
                 ┌─────────────────▼────────────────────────┐
                 │  src/dbfile                              │
                 │  create/open/close file, page 0 meta I/O │
                 │  read/write page bytes, grow file, sync  │
                 │  checksums / VFS seam                    │
                 └─────────────────┬────────────────────────┘
                                   │
                              one DB file
```

**Import rule:** `dbfile` → core/OS only; `paging` → `dbfile`; `engine` → `paging` (and `dbfile` only for meta helpers if needed); never `dbfile`/`paging` → `engine`/`sql`.

---

## Durability v1 — “simple, not too simple”

**Not:** overwrite pages with no protocol and hope.  
**Not yet:** WAL or full rollback journal.

**Yes (v1):**

1. Mutations pin pages read/write and mark **dirty** in the pager (in-memory txn).
2. **Rollback** = drop dirty cache pages / reload from disk (no write).
3. **Commit** =
   - Optionally bump a **generation / commit counter** in a staging copy of page 0.
   - Write all dirty **data pages** (stable order, e.g. ascending `page_no`).
   - Write **page 0** last (bootstrap reflects new `page_count`, freelist, `table_prime` root, commit counter).
   - `dbfile.sync()` (`fsync`) once (or data then page 0 — document exact order in `storage-format.md`).
4. **Open** = validate magic/version; optionally verify page checksums; refuse clearly corrupt headers.

**Known limit:** a crash *during* multi-page flush can leave a torn file. Accept for early development; **API boundaries should make adding WAL later a `paging`+`dbfile` change**, not a btree rewrite.

**Not too simple:** still have real txns, pin cache, freelist, checksums, bootstrap catalog, deterministic flush order.

---

## Bootstrap: page 0 + `table_prime`

```text
Page 0 (bootstrap)
├── magic, format version
├── page_size, page_count
├── freelist head
├── commit_counter / schema_cookie
├── table_prime_root  →  page_no of table_prime B+tree root
├── checksum
└── reserved / padding

table_prime (B+tree table)
└── rows describing user schema: tables, indexes, roots, column meta, …
```

- **Page 0** is **meta**, not a general heap page. It is never a btree leaf for user data.
- **`table_prime`** is a normal **engine B+tree table** reserved for the catalog (name fixed). It is created empty-or-seeded at DB create time; its root page number is stored in page 0.
- User `CREATE TABLE` → insert row(s) into `table_prime` + allocate table root page(s).
- **Suggestion:** keep `table_prime` row format versioned and documented early (even if columns are minimal: `kind`, `name`, `root_page`, `sql_text` or structured blob).

---

## Package responsibilities

### `src/dbfile` — file format & disk I/O

**Owns**

- File lifecycle: create / open / close.
- **Page 0** read/write helpers (encode/decode bootstrap fields).
- `read_page` / `write_page` / `sync` / grow `page_count`.
- Little-endian; Strix magic.
- VFS seam for memory-backed tests.
- Optional page checksum encode/verify primitives.

**Does not own**

- Cache, pin counts, freelist *policy*, btree, `table_prime` row logic, WAL.

**Sketch API**

```odin
Db_File :: struct { /* fd, path, page_size, page_count, … */ }
Page_No :: u32  // 0 = bootstrap

open_create   :: proc(path: string, opts: Open_Options) -> (Db_File, Db_Error)
open_existing :: proc(path: string, opts: Open_Options) -> (Db_File, Db_Error)
close         :: proc(f: ^Db_File)

read_page  :: proc(f: ^Db_File, page_no: Page_No, dst: []u8) -> Db_Error
write_page :: proc(f: ^Db_File, page_no: Page_No, src: []u8) -> Db_Error
sync       :: proc(f: ^Db_File) -> Db_Error

// page 0 helpers
read_bootstrap  :: proc(f: ^Db_File) -> (Bootstrap, Db_Error)
write_bootstrap :: proc(f: ^Db_File, b: Bootstrap) -> Db_Error
```

### `src/paging` — pages via `dbfile`

**Owns**

- Buffer pool: get/pin/unpin, dirty, LRU (or clock) eviction.
- `alloc_page` / `free_page` (freelist; extend file via `dbfile` when empty).
- `flush(dirty set)` implementing the v1 commit write order (data pages, then page 0, then sync) — may take bootstrap fields from engine.
- Does not interpret btree cells.

**Sketch API**

```odin
Pager :: struct { /* file: Db_File, cache, freelist */ }

pager_open / pager_close
get_readonly / get_readwrite / unpin
alloc_page / free_page
flush :: proc(p: ^Pager, bootstrap: Bootstrap) -> Page_Error
```

### `src/engine` — orchestrator + btree + catalog

**Owns**

- Session: open path → `dbfile` + `paging`; ensure page 0 + `table_prime` exist.
- Txn begin / commit / rollback (commit → pager flush + sync).
- **B+tree** implementation and cursors.
- **`table_prime`** access API (list tables, register table/index, lookup root).
- Row/record encoding for leaf payloads.
- Later: SQL bind/execute.

**Sketch API**

```odin
Engine :: struct { /* pager, txn state, table_prime handle */ }

engine_open / engine_close
txn_begin / txn_commit / txn_rollback

catalog_lookup / catalog_register_table / catalog_register_index

btree_open(root) / seek_ge / next / insert / delete
```

---

## On-disk format (v1 draft)

| Area | Choice |
|------|--------|
| Compatibility | Strix-native |
| Pages | **0-based**; size default **4096**; frozen at create |
| Page 0 | Bootstrap meta + `table_prime_root` |
| Catalog | `table_prime` B+tree |
| Endian | Little-endian |
| Magic | e.g. `StrixDB\0` + u16 version |
| Durability files | **Single file only** (no `-wal` / `-journal` in v1) |
| Checksums | Header required; per-page recommended |

Freeze details in `docs/storage-format.md` during S0.

---

## Phased delivery

### Phase S0 — `dbfile`

- [x] Package `dbfile`: `Db_File`, `Page_No`, `Bootstrap`, errors
- [x] Create/open/close; page 0 magic/version/page_size/page_count
- [x] `read_page` / `write_page` / `sync`
- [x] Memory or temp-file tests; reject bad magic

**Exit:** create file, write page 0 + page N, reopen, read back.

### Phase S1 — `paging`

- [x] Cache + pin/unpin + dirty
- [x] `alloc_page` / `free_page`
- [x] `flush` write order (data then page 0) + `sync`
- [x] Tests: hit/miss, flush persists, rollback via discard dirty

**Exit:** engine-ready page API without btree.

### Phase S2 — Engine session + txns *(no WAL)*

- [x] `engine_open`/`close`; create initializes page 0
- [x] `txn_begin` / `commit` / `rollback`
- [x] Commit uses pager flush protocol
- [x] Tests: commit persists across reopen; rollback does not

**Exit:** transactional page updates (even if test-only “payload” pages).

### Phase S3 — B+tree in `engine/`

- [x] Leaf/interior formats; insert/split/search; cursors
- [x] Oracle tests vs map; reopen durability
- [x] Simple delete (merge can wait)

**Exit:** durable key/value btree.

### Phase S4 — `table_prime` + user tables

- [x] Create DB → init empty `table_prime` + store root in page 0
- [x] Register user table/index rows in `table_prime`
- [x] Open user table by name → root → btree
- [x] Secondary index btree (key + rowid)
- [x] Catalog / `table_prime` root write-through after root split + reopen tests

**Exit:** catalog-backed tables/indexes with durable root identity after growth.

### Phase S5 — SQL DDL/DML slice (stretch)

Superseded by **[`docs/sql-execute.md`](sql-execute.md)** (bind + execute on `feature/sql-execute`).

- [x] See execute plan phases E1–E4 (CREATE/DROP → INSERT → SELECT → UPDATE/DELETE + CLI `sql`) — done in [`sql-execute.md`](sql-execute.md)

---

## Testing strategy

| Layer | Focus |
|-------|--------|
| `dbfile` | Header, page R/W, bad magic, grow |
| `paging` | Cache, freelist, flush order, dirty discard |
| `engine` | Txns, btree oracle, `table_prime`, reopen |
| Later | Crash-tear documentation tests; WAL when added |

Extend `./build.sh test` with `src/test/dbfile`, `src/test/paging`, `src/test/engine`.

---

## Definition of done (storage v1)

- [x] S0–S4 complete; tests green
- [x] Create DB → `table_prime` → user table → insert/seek/scan → reopen
- [x] Commit/rollback behave as specified; flush+fsync on commit
- [x] Layering + naming (`dbfile`) respected
- [x] `storage-format.md` describes page 0 + page types + `table_prime` row shape
- [x] WAL explicitly listed as **future work**, not half-implemented

---

## Future work (explicitly deferred)

- WAL or rollback journal + true crash-atomic multi-page commit
- Multi-reader concurrency while writer exists
- Vacuum / packing; attached databases
- SQL binder/executor — see [`sql-execute.md`](sql-execute.md)

---

## Immediate next steps

1. Scaffold `src/dbfile` (S0) + `src/test/dbfile`.
2. Author `docs/storage-format.md` v0.1 for page 0 / `Bootstrap`.
3. S1 pager → S2 engine txns → S3 btree → S4 `table_prime`.
