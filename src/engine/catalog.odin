package engine

import "core:encoding/endian"
import "core:strings"
import dbfile "../dbfile"

// Catalog keys and row payloads — see docs/storage-format.md (table_prime v0.4).

CATALOG_ROW_VERSION :: u8(1)
CATALOG_KEY_TABLE_PREFIX :: "table:"
CATALOG_KEY_INDEX_PREFIX :: "index:"

Catalog_Kind :: enum u8 {
	Table = 1,
	Index = 2,
}

Catalog_Entry :: struct {
	kind:         Catalog_Kind,
	root:         dbfile.Page_No,
	parent_table: string, // set for Index rows
}

catalog_table_key :: proc(name: string, allocator := context.allocator) -> []u8 {
	s := strings.concatenate({CATALOG_KEY_TABLE_PREFIX, name}, allocator)
	return transmute([]u8)s
}

catalog_index_key :: proc(name: string, allocator := context.allocator) -> []u8 {
	s := strings.concatenate({CATALOG_KEY_INDEX_PREFIX, name}, allocator)
	return transmute([]u8)s
}

encode_catalog_row :: proc(
	entry: Catalog_Entry,
	allocator := context.allocator,
) -> []u8 {
	parent := entry.parent_table
	if entry.kind == .Table {
		parent = ""
	}
	if entry.kind == .Index && len(parent) == 0 {
		return nil
	}
	need := 6 + (2 + len(parent) if entry.kind == .Index else 0)
	buf := make([]u8, need, allocator)
	buf[0] = CATALOG_ROW_VERSION
	buf[1] = u8(entry.kind)
	endian.put_u32(buf[2:6], .Little, u32(entry.root))
	if entry.kind == .Index {
		endian.put_u16(buf[6:8], .Little, u16(len(parent)))
		copy(buf[8:], transmute([]u8)parent)
	}
	return buf
}

decode_catalog_row :: proc(payload: []u8, allocator := context.allocator) -> (Catalog_Entry, Engine_Error) {
	if len(payload) < 6 {
		return {}, .Corrupt
	}
	if payload[0] != CATALOG_ROW_VERSION {
		return {}, .Corrupt
	}
	kind := Catalog_Kind(payload[1])
	if kind != .Table && kind != .Index {
		return {}, .Corrupt
	}
	root, ok := endian.get_u32(payload[2:6], .Little)
	if !ok {
		return {}, .Corrupt
	}
	entry := Catalog_Entry{kind = kind, root = dbfile.Page_No(root)}
	if kind == .Index {
		if len(payload) < 8 {
			return {}, .Corrupt
		}
		plen, ok2 := endian.get_u16(payload[6:8], .Little)
		if !ok2 {
			return {}, .Corrupt
		}
		if int(8 + plen) > len(payload) {
			return {}, .Corrupt
		}
		entry.parent_table = strings.clone(string(payload[8:8 + plen]), allocator)
	}
	return entry, .None
}

table_prime_tree :: proc(e: ^Engine) -> (Btree, Engine_Error) {
	if e.table_prime_root == 0 {
		return {}, .Catalog_Missing
	}
	tree, err := btree_open(e, &e.table_prime_root)
	if err != .None {
		return {}, err
	}
	btree_bind_prime(&tree)
	return tree, .None
}

// catalog_update_root write-through: persist a new object root into its table_prime row.
catalog_update_root :: proc(e: ^Engine, catalog_key: []u8, new_root: dbfile.Page_No) -> Engine_Error {
	if err := require_txn(e); err != .None {
		return err
	}
	if len(catalog_key) == 0 || new_root == 0 {
		return .Invalid_Argument
	}
	prime, perr := table_prime_tree(e)
	if perr != .None {
		return perr
	}
	payload, gerr := btree_get(&prime, catalog_key)
	if gerr != .None {
		return gerr
	}
	defer delete(payload)
	if len(payload) < 6 {
		return .Corrupt
	}
	entry, derr := decode_catalog_row(payload)
	if derr != .None {
		return derr
	}
	defer {
		if entry.parent_table != "" {
			delete(entry.parent_table)
		}
	}
	entry.root = new_root
	updated := encode_catalog_row(entry)
	if updated == nil {
		return .Corrupt
	}
	defer delete(updated)
	// Same-sized payload: in-place update (avoids delete+insert hole on failure).
	return btree_update_payload(&prime, catalog_key, updated)
}

// engine_ensure_catalog creates an empty table_prime on first use (create / memory).
engine_ensure_catalog :: proc(e: ^Engine) -> Engine_Error {
	if e.table_prime_root != 0 {
		return .None
	}
	if err := txn_begin(e); err != .None {
		return err
	}
	prime, err := btree_create(e, &e.table_prime_root)
	if err != .None {
		_ = txn_rollback(e)
		return err
	}
	btree_bind_prime(&prime)
	return txn_commit(e)
}

// catalog_register_table allocates a user table btree and records it in table_prime.
catalog_register_table :: proc(e: ^Engine, name: string) -> (root: dbfile.Page_No, err: Engine_Error) {
	if err = require_txn(e); err != .None {
		return 0, err
	}
	if len(name) == 0 {
		return 0, .Invalid_Argument
	}
	prime, perr := table_prime_tree(e)
	if perr != .None {
		return 0, perr
	}

	ckey := catalog_table_key(name)
	defer delete(ckey)
	if existing, gerr := btree_get(&prime, ckey); gerr == .None {
		delete(existing)
		return 0, .Exists
	} else if gerr != .Not_Found {
		return 0, gerr
	}

	user, cerr := btree_create(e, &root)
	if cerr != .None {
		return 0, cerr
	}
	_ = user

	payload := encode_catalog_row({kind = .Table, root = root})
	defer delete(payload)
	if err = btree_insert(&prime, ckey, payload); err != .None {
		return 0, err
	}
	e.schema_cookie += 1
	return root, .None
}

// catalog_register_index allocates a secondary index btree and records parent table.
catalog_register_index :: proc(e: ^Engine, index_name, table_name: string) -> (root: dbfile.Page_No, err: Engine_Error) {
	if err = require_txn(e); err != .None {
		return 0, err
	}
	if len(index_name) == 0 || len(table_name) == 0 {
		return 0, .Invalid_Argument
	}
	prime, perr := table_prime_tree(e)
	if perr != .None {
		return 0, perr
	}

	tkey := catalog_table_key(table_name)
	defer delete(tkey)
	table_payload, tgerr := btree_get(&prime, tkey)
	if tgerr == .Not_Found {
		return 0, .Not_Found
	}
	if tgerr != .None {
		return 0, tgerr
	}
	delete(table_payload)

	ikey := catalog_index_key(index_name)
	defer delete(ikey)
	if existing, gerr := btree_get(&prime, ikey); gerr == .None {
		delete(existing)
		return 0, .Exists
	} else if gerr != .Not_Found {
		return 0, gerr
	}

	idx, cerr := btree_create(e, &root)
	if cerr != .None {
		return 0, cerr
	}
	_ = idx

	payload := encode_catalog_row({
		kind         = .Index,
		root         = root,
		parent_table = table_name,
	})
	defer delete(payload)
	if err = btree_insert(&prime, ikey, payload); err != .None {
		return 0, err
	}
	e.schema_cookie += 1
	return root, .None
}

// catalog_open_table returns a btree handle for a registered user table.
catalog_open_table :: proc(e: ^Engine, name: string) -> (tree: Btree, err: Engine_Error) {
	if err = require_open(e); err != .None {
		return {}, err
	}
	prime, perr := table_prime_tree(e)
	if perr != .None {
		return {}, perr
	}
	ckey := catalog_table_key(name)
	defer delete(ckey)
	payload, gerr := btree_get(&prime, ckey)
	if gerr != .None {
		return {}, gerr
	}
	defer delete(payload)
	entry, derr := decode_catalog_row(payload)
	if derr != .None {
		return {}, derr
	}
	defer {
		if entry.parent_table != "" {
			delete(entry.parent_table)
		}
	}
	if entry.kind != .Table {
		return {}, .Not_Found
	}
	// Attach then upgrade to Catalog_Object (clears ephemeral root_slot).
	root_holder := entry.root
	opened, oerr := btree_open(e, &root_holder)
	if oerr != .None {
		return {}, oerr
	}
	if berr := btree_bind_catalog_key(&opened, ckey); berr != .None {
		return {}, berr
	}
	return opened, .None
}

// catalog_open_index returns a btree handle for a registered secondary index.
catalog_open_index :: proc(e: ^Engine, index_name: string) -> (tree: Btree, err: Engine_Error) {
	if err = require_open(e); err != .None {
		return {}, err
	}
	prime, perr := table_prime_tree(e)
	if perr != .None {
		return {}, perr
	}
	ikey := catalog_index_key(index_name)
	defer delete(ikey)
	payload, gerr := btree_get(&prime, ikey)
	if gerr != .None {
		return {}, gerr
	}
	defer delete(payload)
	entry, derr := decode_catalog_row(payload)
	if derr != .None {
		return {}, derr
	}
	defer {
		if entry.parent_table != "" {
			delete(entry.parent_table)
		}
	}
	if entry.kind != .Index {
		return {}, .Not_Found
	}
	root_holder := entry.root
	opened, oerr := btree_open(e, &root_holder)
	if oerr != .None {
		return {}, oerr
	}
	if berr := btree_bind_catalog_key(&opened, ikey); berr != .None {
		return {}, berr
	}
	return opened, .None
}

// catalog_lookup_table_root returns the root page for a table name without opening a handle.
catalog_lookup_table_root :: proc(e: ^Engine, name: string) -> (dbfile.Page_No, Engine_Error) {
	tree, err := catalog_open_table(e, name)
	if err != .None {
		return 0, err
	}
	return btree_root(&tree), .None
}

// --- user row / index key helpers (memcmp-ordered) ---

// rowid_key writes big-endian rowid for lexicographic numeric order.
rowid_key :: proc(rowid: u64, dst: []u8) -> Engine_Error {
	if len(dst) < 8 {
		return .Invalid_Argument
	}
	if !endian.put_u64(dst[0:8], .Big, rowid) {
		return .Invalid_Argument
	}
	return .None
}

// index_entry_key is secondary-index key: index_key bytes || rowid (BE u64).
index_entry_key :: proc(index_key: []u8, rowid: u64, allocator := context.allocator) -> ([]u8, Engine_Error) {
	out := make([]u8, len(index_key) + 8, allocator)
	copy(out, index_key)
	if !endian.put_u64(out[len(index_key):], .Big, rowid) {
		delete(out)
		return nil, .Invalid_Argument
	}
	return out, .None
}

// table_insert_row inserts payload keyed by rowid into a user table btree.
table_insert_row :: proc(tree: ^Btree, rowid: u64, payload: []u8) -> Engine_Error {
	key: [8]u8
	if err := rowid_key(rowid, key[:]); err != .None {
		return err
	}
	return btree_insert(tree, key[:], payload)
}

// table_get_row reads payload for rowid from a user table btree.
table_get_row :: proc(tree: ^Btree, rowid: u64, allocator := context.allocator) -> ([]u8, Engine_Error) {
	key: [8]u8
	if err := rowid_key(rowid, key[:]); err != .None {
		return nil, err
	}
	return btree_get(tree, key[:], allocator)
}

// index_insert_entry inserts index_key+rowid into a secondary index (empty payload).
index_insert_entry :: proc(tree: ^Btree, index_key: []u8, rowid: u64) -> Engine_Error {
	key, kerr := index_entry_key(index_key, rowid)
	if kerr != .None {
		return kerr
	}
	defer delete(key)
	return btree_insert(tree, key, nil)
}

// index_lookup_rowid finds rowid for exact index key (first match if duplicates — unique index assumed).
index_lookup_rowid :: proc(tree: ^Btree, index_key: []u8, rowid: u64) -> Engine_Error {
	key, kerr := index_entry_key(index_key, rowid)
	if kerr != .None {
		return kerr
	}
	defer delete(key)
	payload, err := btree_get(tree, key)
	if err == .None {
		delete(payload)
	}
	return err
}

table_prime_root :: proc(e: ^Engine) -> dbfile.Page_No {
	if e == nil {
		return 0
	}
	return e.table_prime_root
}
