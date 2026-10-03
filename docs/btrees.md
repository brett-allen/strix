# B-Trees for Database Storage

A detailed guide to B-trees: why they exist, how they work in theory, how they are implemented on disk, and what that means for an engine like Strix (SQLite-shaped, durable, page-oriented).

This is a **storage-layer** document. It assumes the SQL parser already exists; the binder/planner will eventually ask the storage engine to look up and mutate keys inside structures like these.

---

## 1. Introduction

### 1.1 The problem databases actually have

A database must support:

- **Point lookup** — “find the row with `id = 42`”
- **Range scan** — “find all keys where `created_at >= … AND created_at < …`”
- **Ordered traversal** — indexes and `ORDER BY` / merge joins often need sorted order
- **Durable updates** — inserts, updates, deletes that survive crashes
- **Large data** — far more than fits in RAM, living on SSD/HDD

If the working set lived only in memory, a balanced binary tree (AVL, red-black) could work. On disk, those trees are a poor fit: they are **deep**, and every edge-follow can become a **random I/O**. Disk (and even SSD) rewards **few, large, sequential-ish reads**, not millions of pointer chases.

### 1.2 What a B-tree optimizes for

A **B-tree** is a self-balancing multiway search tree designed so that:

1. **Fanout is high** — each node holds many keys and child pointers (tens to hundreds+).
2. **Height stays small** — often 3–4 levels for huge tables, so a lookup costs a handful of page reads.
3. **Nodes map to pages** — node size ≈ disk page / filesystem block / DB page (e.g. 4 KiB, 8 KiB, 16 KiB).
4. **All leaves sit at the same depth** — balance is structural, not “mostly balanced.”

In short: **minimize I/Os per operation** by maximizing useful work per I/O.

### 1.3 B-tree vs B+tree (read this early)

Both are balanced multiway search trees with high fanout and equal leaf depth. The distinction is **where data lives** and **how you walk a range**.

#### Classic B-tree

- **Every node** (internal and leaf) can store **keys and associated records** (payloads).
- An internal node is both a **routing table** and a **data store**: finding key \(k\) may finish at an internal node without ever reaching a leaf.
- Children of an internal node with keys \(k_1 < \cdots < k_m\) are the subtrees for keys outside those exact values (the keys \(k_i\) themselves “live” in that node).

```text
Classic B-tree (keys+payloads in all levels):

              [ 20→row | 40→row ]           ← hit possible HERE
             /         |         \
    [5→r|10→r]   [25→r|30→r]   [50→r]       ← or HERE
```

**Range scan pain:** keys in one contiguous key-range may sit in **internal nodes and several disconnected leaves**. A range query cannot simply “start at a leaf and walk right”; the walk must traverse the tree in order (in-order walk of a multiway tree), jumping between levels. That is awkward on disk and cache-hostile.

#### B+tree

- **All records live in leaves.** Internal nodes hold **separator (routing) keys** and child pointers only — typically **no row payloads**.
- Separator keys may be **copies** of leaf keys (or short separators derived from them). The “real” entry for a key is in a leaf.
- Leaves are usually linked in key order (**sibling / next-leaf pointers**), so a range is: find the first leaf, then follow next links until past the high bound.

```text
B+tree (payloads in leaves only):

              [ 20 | 40 ]                   ← separators only (no rows)
             /     |     \
    [5→r|10→r] [20→r|25→r] [40→r|50→r]     ← ALL rows HERE
         ←--------→←--------→               ← leaf sibling links
```

Search for `25`: always descend to a leaf (even if `25` appears as a separator somewhere above). Range `20…40`: land on the leaf containing `20`, scan right via sibling links.

#### Side-by-side

| | Classic B-tree | B+tree |
|--|----------------|--------|
| **Where payloads live** | Internal nodes **and** leaves | **Leaves only** |
| **Internal node contents** | Keys + payloads + child pointers | Keys (separators) + child pointers |
| **Point lookup** | May stop at internal node | Always ends at a leaf |
| **Range scan** | In-order tree walk across levels | Leaf walk via sibling pointers |
| **Internal node size budget** | Shared with payloads → **lower fanout** | Separators only → **higher fanout** → usually **shallower** tree |
| **Insert / split** | Middle key often **moves up** (leaves that level) | Middle/separator often **copied up**; **full entries stay in leaves** |
| **Duplicate / multi-attr keys** | Various | Very common: leaf key = `(indexed cols…, rowid)` |

#### Why databases prefer B+trees

1. **Range queries and ordered scans** dominate real workloads (`BETWEEN`, index scans, merge joins, `ORDER BY` via index). Leaf linkage makes that cheap.
2. **Higher fanout** — internals without fat payloads pack more routing keys per page → fewer levels → fewer I/Os per lookup.
3. **Uniform leaf format** — one place to define row/index record layout, overflow, and cursors.

Classic B-trees still matter historically and in some textbooks / in-memory structures; they are rarely the on-disk index shape in modern RDBMSs.

#### Terminology trap

People (and product docs) often say **“B-tree”** when they mean **B+tree-shaped** storage:

- **SQLite** officially calls its structures “b-trees,” but table/index trees keep row data in **leaf** pages (with overflow); interior pages are for navigation — i.e. closer to B+tree practice.
- Papers and APIs likewise blur the name.

**In this document:**

- **§1–theory “B-tree”** means the balanced multiway family in general.
- **Practical / implementation sections** mean the **B+tree-style** design (leaf payloads + separator internals), unless explicitly labeled “classic B-tree.”
- When implementing Strix, default to **B+tree rules**: payloads in leaves, separators above, leaf sibling links for cursors.

---

## 2. Core vocabulary

| Term | Meaning |
|------|---------|
| **Key** | Ordered value used for search (e.g. primary key, index column tuple) |
| **Payload / value** | Associated data (full row, rowid pointer, or index columns) |
| **Node / page** | One tree node, typically one fixed-size **page** on disk |
| **Root** | Top node; may be leaf if the tree is tiny |
| **Internal (branch) node** | Has children; guides search |
| **Leaf node** | No children; holds the entries you ultimately want |
| **Fanout** | Average number of children per internal node |
| **Order / branching factor** | Textbook parameter limiting keys/children per node (definitions vary by author) |
| **Occupancy** | How full a page is (affects split/merge) |
| **Separator key** | Key in a parent that decides which child to follow |

### Ordering

Keys must be **totally ordered** (or ordered with a well-defined comparison that matches query semantics). Composite keys compare lexicographically. NULLs need an explicit policy (SQLite: NULL sorts first in ASC indexes by default — engine-defined, not optional chaos).

---

## 3. Theory

### 3.1 Search tree idea

Like a binary search tree, a B-tree keeps the invariant:

> For a node with keys \(k_1 < k_2 < \cdots < k_m\) and children \(c_0, c_1, \ldots, c_m\):
>
> - all keys in subtree \(c_0\) are \(< k_1\)
> - all keys in subtree \(c_i\) are \(> k_i\) and \(< k_{i+1}\) (with obvious edges for first/last)

Exact boundary rules (“≤ vs <”) are an implementation choice, but must be **consistent** for search, insert, and split.

### 3.2 Balance invariant

All leaves are at the **same depth**. That is the defining balance property. You do not “rebalance rotations” like AVL; you **split** and **merge/redistribute** nodes so height changes only at the root (grow/shrink by one level).

### 3.3 Occupancy invariants (textbook)

A typical formulation for a B-tree of **minimum degree** \(t\):

- Every node other than root has at least \(t - 1\) keys.
- Every node has at most \(2t - 1\) keys.
- Root has at least 1 key if the tree is non-empty (unless empty tree special-cased).
- An internal node with \(k\) keys has \(k + 1\) children.

Exact constants differ by source (“order m” vs “minimum degree t”). **Do not memorize one textbook’s m**; implement **page-capacity** constraints instead (see practice).

### 3.4 Height and I/O

Roughly, if every internal page holds \(F\) child pointers (fanout), then \(N\) leaf entries need height about \(\log_F N\).

Example: \(F = 100\), \(N = 10^9\) → height ≈ 4–5. That is why B-trees dominate disk indexes: **logarithmic in a large base**.

### 3.5 Algorithms (conceptual)

#### Search

1. Start at root.
2. Binary-search keys inside the page (or linear scan if small).
3. Follow the appropriate child pointer (load that page).
4. Repeat until leaf; scan leaf for the key / range start.

#### Insert

1. Search to the leaf that should hold the key.
2. If there is room, insert in sorted order; write the page.
3. If full, **split**:
   - Divide keys into left and right (and possibly a middle separator).
   - Promote separator to parent (B-tree) or copy separator up (B+tree variants).
   - If parent is full, split parent recursively.
   - If root splits, allocate a new root → height increases by 1.

#### Delete

1. Find the key; remove it.
2. If occupancy falls below minimum, **rebalance**:
   - **Borrow** (redistribute) from a sibling, updating separator in parent, or
   - **Merge** with a sibling and pull separator down; if parent underflows, continue upward.
3. If root becomes empty of keys and has one child, that child becomes the new root → height decreases.

Deletes are harder than inserts; many engines defer aggressive merging or use free-space reserve to reduce churn.

#### Range scan (B+tree)

1. Find the leaf for the low bound.
2. Iterate keys in that leaf.
3. Follow **leaf sibling pointers** (next-page link) until past the high bound.

This is why B+trees win for `BETWEEN`, table scans via indexes, and ordered iteration.

---

## 4. Diagrams

### 4.1 Tiny B+tree shape

```text
                    [  20  |  40  ]          ← internal (separators only)
                   /       |       \
          [5|10|15]   [20|25|30]  [40|50]   ← leaves (keys + payloads)
           ↔           ↔           ↔       ← sibling links (common)
```

Search for `25`: root → middle child → leaf hit.

### 4.2 Leaf split (insert into full leaf)

```text
Before (leaf full):  [10|20|30|40|50]     parent separator … → this leaf

Insert 35 → split:

Left:  [10|20|30]     Right: [35|40|50]
Parent gains separator 35 (details vary by B vs B+)
```

### 4.3 Page as a node

```text
┌──────────────────────────────────────────┐
│ page header (type, n_cells, free space)  │
│ cell pointer array →                     │
│ … free space …                           │
│                     ← cells (key+payload)│
└──────────────────────────────────────────┘
```

On-disk layouts vary, but this “header + slotted cells growing toward each other” pattern is classic (SQLite uses a slotted-page style).

---

## 5. In practice (database engines)

### 5.1 Pages are the unit of I/O and caching

- The engine reads/writes **whole pages**.
- A **page cache (buffer pool)** keeps hot pages in memory.
- Correctness under crash → **WAL** or **shadow paging** / journaling so partial updates do not corrupt the tree.

B-tree code rarely “malloc a node” in the abstract sense for durable trees; it **allocate a page number**, pin it in cache, mutate, mark dirty, flush according to the durability protocol.

### 5.2 Choosing page size

| Larger pages | Smaller pages |
|--------------|---------------|
| Higher fanout, shallower trees | Less waste for small rows |
| Better sequential scan throughput | Less contention / write amplification per tiny update |
| More wasted space from fragmentation | More I/Os for large rows / range scans |

Common defaults: 4 KiB or 8 KiB; SQLite default page size is historically 4096 (configurable).

### 5.3 What is stored in an index leaf?

Typical designs:

1. **Primary key / table B-tree** — key = rowid or PK; payload = row columns (possibly overflow).
2. **Secondary index** — key = indexed column(s) + rowid (for uniqueness/ordering); payload empty or includes rowid only.

Looking up by secondary index often means: **index B-tree search → rowid → table B-tree search** (index-only scans avoid the second hop when covering).

### 5.4 Variable-length keys and payloads

Real keys are not fixed 8-byte integers only:

- Need **comparable encodings** (memcmp-friendly where possible).
- Large payloads → **overflow pages** (SQLite) or TOAST-like storage.
- Page packing: slotted pages, fragmented free space, occasional **defragment / vacuum**.

### 5.5 Concurrency

Multiple transactions touching one B-tree need a policy:

- **Latch / lock per page** (or lock coupling: hold parent latch until child latched).
- **Optimistic** methods / versioned pages (harder).
- **WAL + page-level** granularity interacting with MVCC (Postgres heap is separate from index B-trees; InnoDB clusters differently).

For Strix’s early SQLite-like path, **single-writer** (SQLite’s classic model) postpones a lot of latch coupling complexity.

### 5.6 Crashes and atomicity

A split touches **multiple pages** (leaf, sibling, parent, maybe new root). Without care, a crash mid-split yields a corrupt tree.

Approaches:

- **WAL**: log intended page images / changes, then checkpoint.
- **Journal**: before overwrite, save old pages.
- Careful write ordering + checksums.

The B-tree algorithm and the **recovery protocol** are inseparable in a durable DB.

### 5.7 Free space and page allocation

Deleted keys leave holes; merged pages return to a **freelist**. Allocating a new node pulls from freelist or extends the file. Truncation / vacuum can shrink files later.

### 5.8 SQLite-shaped notes (relevant to Strix)

SQLite’s file format is documented and worth studying as a concrete B-tree:

- Database = header + pages.
- **Table b-trees** and **index b-trees**.
- Leaves hold records with a defined record format.
- Interior pages hold navigation keys + child page numbers.
- Overflow for big payloads.
- Truncated / redefined details over versions — treat the official file-format doc as source of truth when implementing.

Studying SQLite is valuable even if Strix’s on-disk format diverges: the **problems** (slotted pages, overflow, freelist, WAL) reappear.

---

## 6. B-tree vs alternatives

| Structure | Strength | Weakness for OLTP DB files |
|-----------|----------|----------------------------|
| **Hash index** | O(1) point lookup | No ranges/order; harder on disk resizing |
| **BST / red-black** | Simple memory maps | Too many I/Os on disk |
| **B+tree** | Ranges + point + disk-friendly | Write amplification on splits; concurrency complexity |
| **LSM-tree** (RocksDB, etc.) | Fast writes, sequential disk use | Read amplification; compaction; different tradeoffs |
| **TRIE / ART** | Great in-memory CPU behavior | Not a drop-in durable page design |

Engines sometimes **combine** them (LSM for storage, B-trees for memory components, etc.). For Strix’s SQLite-first parity goal, **page B-trees + WAL** is the natural default.

---

## 7. Implementation sketch (engine checklist)

When you implement storage, expect roughly these layers:

```text
┌─────────────────────────────┐
│  Binder / executor           │  “open index I, seek key K”
├─────────────────────────────┤
│  B-tree API                  │  seek, next, insert, delete
├─────────────────────────────┤
│  Page cache + locks          │  pin/unpin, dirty, eviction
├─────────────────────────────┤
│  Pager / freelist            │  alloc/free page numbers
├─────────────────────────────┤
│  WAL / journal + VFS         │  durability + crash recovery
├─────────────────────────────┤
│  OS file                     │
└─────────────────────────────┘
```

### Suggested build order for Strix

1. **Pager** — fixed-size pages, read/write by page number, freelist.
2. **Page cache** — pin/dirty/evict (can start single-threaded).
3. **WAL or rollback journal** — before trusting mutations.
4. **Leaf-only B+tree** — search + insert + split; defer fancy delete merge.
5. **Table + index** use cases — row format, overflow.
6. **Cursor API** — `seek` / `next` for executors and range scans.
7. **Delete/rebalance** — when churn demands it; vacuum later.

### API shape (illustrative)

```text
bt_open(table_or_index_id) -> Tree
bt_seek(tree, key) -> Cursor      # position at first >= key (policy TBD)
bt_next(cursor) -> (key, payload) | EOF
bt_insert(tree, key, payload) -> ok | constraint_conflict
bt_delete(tree, key) -> ok | not_found
```

Cursors must define behavior under concurrent modification (SQLite: carefully defined; early Strix: single writer simplifies this).

---

## 8. Correctness pitfalls

1. **Inconsistent comparison** — insert uses one order, search another → lost entries.
2. **Separator vs leaf key mismatch** after split (off-by-one which key moves up).
3. **Forgetting to update sibling links** on split/merge (breaks range scan).
4. **Root split without new root page** → truncated height logic bugs.
5. **Durability**: publishing a page pointer before the page hits stable storage according to your recovery rules.
6. **Endianness / alignment** when pages move across machines (usually pin a file endian).
7. **Integer key encodings** that are not memcmp-sortable (signed ints, decimals).
8. **Unique vs non-unique indexes** — always disambiguate with rowid/tid in the key.
9. **Underflow handling** that livelocks or leaves empty pages reachable.
10. **Testing only random inserts** — also test descending inserts, duplicates, delete-all, re-insert, crash mid-split (recovery tests).

---

## 9. Performance intuition

- **Cache hit rate** dominates. A shallow tree with hot root/internal pages means most lookups are 1 leaf I/O (or 0 if leaf cached).
- **Sequential inserts** (append-only increasing keys) often split only the right edge — friendly pattern; random keys cause more splits and fragmentation.
- **Fill factor**: leaving slack on split (e.g. 50/50 vs pack left) trades space for future inserts.
- **Compression / prefix truncation** of keys in internals increases fanout (advanced).
- **Covering indexes** avoid table lookups — planner concern, storage enables it.

Measure with: tree height, pages read per query, split rate, cache miss rate, write amplification.

---

## 10. How to test a B-tree

| Test class | Intent |
|------------|--------|
| Unit: page packing | Cell insert/delete inside one page |
| Unit: split math | Separator choice, left/right counts |
| Property: model oracle | Mirror tree vs in-memory `map`/`btree` reference |
| Adversarial keys | Empty, max-length, duplicates, random, monotonic |
| Durability | Kill process mid-write; recover; compare |
| Cursor | Range scan equals sorted filter of model |
| Space | Delete heavy → freelist reuse; no unreachable pages |

An in-memory model (sorted array or std map) as an **oracle** catches almost all structural bugs early—before WAL complexity.

---

## 11. Glossary of nearby ideas

- **Clustered index** — table data stored in the B-tree leaves (InnoDB PK).
- **Heap + secondary indexes** — rows in heap file; indexes point to tid (Postgres).
- **Covering index** — index leaf has all columns needed for a query.
- **Covered query / index-only scan** — no heap/table fetch.
- **Bloom filters / fence keys** — LSM and advanced B-tree variants.
- **Copy-on-write B-trees** — LMDB/Bolt-style; great for readers, different write path.

---

## 12. Suggested reading

- Bayer & McCreight, *Organization and Maintenance of Large Ordered Indexes* (origin).
- Comer, *The Ubiquitous B-Tree* (survey).
- SQLite [Database File Format](https://www.sqlite.org/fileformat.html) (practical B-tree pages).
- PostgreSQL docs on index access methods (B-tree behavior in a heap world).
- *Database System Concepts* / *Readings in Database Systems* chapters on storage & indexing.
- Rustlin / CMU 15-445 lecture notes on B+trees (excellent diagrams and homework-style clarity).

---

## 13. Relevance to Strix

Strix’s parser produces ASTs for DDL/DML. Storage must eventually:

- Implement **table storage** (likely a table B-tree keyed by rowid/PK).
- Implement **indexes** from `CREATE INDEX` (already parsed).
- Support executor operations: insert row, seek PK, range scan for `WHERE` / joins later.

Recommended stance:

1. Treat **B+tree leaves + page cache + WAL** as the default architecture.
2. Keep on-disk format **explicitly versioned** and documented (future `docs/storage-format.md`).
3. Use SQLite as a **behavioral and structural reference**, not necessarily a byte-for-byte clone.
4. Land a **cursor-based** API early so the executor never depends on materializing whole tables.

When you start coding storage, split work into pager → WAL → b-tree → row format, and keep an oracle test harness from day one.

---

## 14. Summary

B-trees (in practice, B+trees) are the standard answer to “how do we keep sorted data on disk with fast point and range access?” They stay shallow by packing many keys per page, balance via splits/merges, and only work as a durable database structure when paired with a pager, cache, and recovery protocol. For Strix, they are the natural backbone of tables and indexes once execution leaves the SQL AST and touches real bytes.
