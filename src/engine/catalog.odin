package engine

import "core:encoding/endian"
import "core:strings"
import dbfile "../dbfile"

// Catalog keys and row payloads — see docs/storage-format.md (table_prime).

CATALOG_ROW_VERSION_V1 :: u8(1)
CATALOG_ROW_VERSION_V2 :: u8(2)
CATALOG_KEY_TABLE_PREFIX :: "table:"
CATALOG_KEY_INDEX_PREFIX :: "index:"

Catalog_Kind :: enum u8 {
	Table = 1,
	Index = 2,
}

Catalog_Column_Flag :: enum u8 {
	Not_Null    = 0,
	Primary_Key = 1,
	Has_Default = 2,
	Desc        = 3, // index column DESC (catalog only; key bytes are ASC for v1)
}

// Catalog_Default_Kind mirrors heap / SQL literal kinds for persisted DEFAULT values.
Catalog_Default_Kind :: enum u8 {
	None    = 0,
	Null    = 1,
	Integer = 2,
	Float   = 3,
	Text    = 4,
	Blob    = 5,
}

Catalog_Column :: struct {
	name:          string,
	type_name:     string,
	flags:         bit_set[Catalog_Column_Flag; u8],
	default_kind:  Catalog_Default_Kind,
	default_i:     i64,
	default_f:     f64,
	default_bytes: string, // owned after decode for Text/Blob
}

Catalog_Entry :: struct {
	version:      u8,
	kind:         Catalog_Kind,
	root:         dbfile.Page_No,
	parent_table: string, // set for Index rows (owned after decode)
	next_rowid:   u64, // table v2
	columns:      []Catalog_Column, // table v2 / index v2; owned after decode
}

catalog_table_key :: proc(name: string, allocator := context.allocator) -> []u8 {
	s := strings.concatenate({CATALOG_KEY_TABLE_PREFIX, name}, allocator)
	return transmute([]u8)s
}

catalog_index_key :: proc(name: string, allocator := context.allocator) -> []u8 {
	s := strings.concatenate({CATALOG_KEY_INDEX_PREFIX, name}, allocator)
	return transmute([]u8)s
}

free_catalog_entry :: proc(entry: Catalog_Entry, allocator := context.allocator) {
	if entry.parent_table != "" {
		delete(entry.parent_table, allocator)
	}
	for c in entry.columns {
		if c.name != "" {
			delete(c.name, allocator)
		}
		if c.type_name != "" {
			delete(c.type_name, allocator)
		}
		if c.default_bytes != "" {
			delete(c.default_bytes, allocator)
		}
	}
	if entry.columns != nil {
		delete(entry.columns, allocator)
	}
}

catalog_default_payload_size :: proc(c: Catalog_Column) -> int {
	if .Has_Default not_in c.flags {
		return 0
	}
	switch c.default_kind {
	case .None, .Null:
		return 1 // kind byte only
	case .Integer, .Float:
		return 1 + 8
	case .Text, .Blob:
		return 1 + 4 + len(c.default_bytes)
	}
	return 1
}

encode_catalog_row :: proc(
	entry: Catalog_Entry,
	allocator := context.allocator,
) -> []u8 {
	parent := entry.parent_table
	if entry.kind == .Table {
		parent = ""
	}
	if entry.kind == .Index {
		if len(parent) == 0 {
			return nil
		}
		version := entry.version
		if version == 0 {
			version = len(entry.columns) > 0 ? CATALOG_ROW_VERSION_V2 : CATALOG_ROW_VERSION_V1
		}
		if version == CATALOG_ROW_VERSION_V1 {
			need := 8 + len(parent)
			buf := make([]u8, need, allocator)
			buf[0] = CATALOG_ROW_VERSION_V1
			buf[1] = u8(entry.kind)
			endian.put_u32(buf[2:6], .Little, u32(entry.root))
			endian.put_u16(buf[6:8], .Little, u16(len(parent)))
			copy(buf[8:], transmute([]u8)parent)
			return buf
		}
		// Index payload v2: version|kind|root|parent_len|parent|col_count|[name_len|name|flags]…
		need := 8 + len(parent) + 2
		for c in entry.columns {
			need += 2 + len(c.name) + 1
		}
		buf := make([]u8, need, allocator)
		buf[0] = CATALOG_ROW_VERSION_V2
		buf[1] = u8(entry.kind)
		endian.put_u32(buf[2:6], .Little, u32(entry.root))
		endian.put_u16(buf[6:8], .Little, u16(len(parent)))
		copy(buf[8:], transmute([]u8)parent)
		off := 8 + len(parent)
		endian.put_u16(buf[off:off + 2], .Little, u16(len(entry.columns)))
		off += 2
		for c in entry.columns {
			endian.put_u16(buf[off:off + 2], .Little, u16(len(c.name)))
			off += 2
			copy(buf[off:], transmute([]u8)c.name)
			off += len(c.name)
			flags := c.flags
			// Persist DESC only for index columns.
			flag_byte: u8 = 0
			if .Desc in flags {
				flag_byte = 1
			}
			buf[off] = flag_byte
			off += 1
		}
		return buf
	}

	version := entry.version
	if version == 0 {
		version = CATALOG_ROW_VERSION_V2
	}
	if version == CATALOG_ROW_VERSION_V1 {
		buf := make([]u8, 6, allocator)
		buf[0] = CATALOG_ROW_VERSION_V1
		buf[1] = u8(entry.kind)
		endian.put_u32(buf[2:6], .Little, u32(entry.root))
		return buf
	}

	// Table payload v2: version|kind|root|next_rowid|col_count|[columns…]
	// Column: name | type_name | flags | [default if Has_Default]
	need := 16
	for c in entry.columns {
		need += 2 + len(c.name) + 2 + len(c.type_name) + 1
		need += catalog_default_payload_size(c)
	}
	buf := make([]u8, need, allocator)
	buf[0] = CATALOG_ROW_VERSION_V2
	buf[1] = u8(entry.kind)
	endian.put_u32(buf[2:6], .Little, u32(entry.root))
	endian.put_u64(buf[6:14], .Little, entry.next_rowid)
	endian.put_u16(buf[14:16], .Little, u16(len(entry.columns)))
	off := 16
	for c in entry.columns {
		endian.put_u16(buf[off:off + 2], .Little, u16(len(c.name)))
		off += 2
		copy(buf[off:], transmute([]u8)c.name)
		off += len(c.name)
		endian.put_u16(buf[off:off + 2], .Little, u16(len(c.type_name)))
		off += 2
		copy(buf[off:], transmute([]u8)c.type_name)
		off += len(c.type_name)
		buf[off] = transmute(u8)c.flags
		off += 1
		if .Has_Default in c.flags {
			buf[off] = u8(c.default_kind)
			off += 1
			switch c.default_kind {
			case .None, .Null:
			case .Integer:
				endian.put_i64(buf[off:off + 8], .Little, c.default_i)
				off += 8
			case .Float:
				endian.put_f64(buf[off:off + 8], .Little, c.default_f)
				off += 8
			case .Text, .Blob:
				endian.put_u32(buf[off:off + 4], .Little, u32(len(c.default_bytes)))
				off += 4
				copy(buf[off:], transmute([]u8)c.default_bytes)
				off += len(c.default_bytes)
			}
		}
	}
	return buf
}

decode_catalog_row :: proc(payload: []u8, allocator := context.allocator) -> (Catalog_Entry, Engine_Error) {
	if len(payload) < 6 {
		return {}, .Corrupt
	}
	version := payload[0]
	if version != CATALOG_ROW_VERSION_V1 && version != CATALOG_ROW_VERSION_V2 {
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
	entry := Catalog_Entry{
		version = version,
		kind    = kind,
		root    = dbfile.Page_No(root),
	}

	if kind == .Index {
		if version != CATALOG_ROW_VERSION_V1 && version != CATALOG_ROW_VERSION_V2 {
			return {}, .Corrupt
		}
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
		off := 8 + int(plen)
		if version == CATALOG_ROW_VERSION_V1 {
			if off != len(payload) {
				free_catalog_entry(entry, allocator)
				return {}, .Corrupt
			}
			return entry, .None
		}
		// Index v2: col_count + [name_len|name|flags]…
		if off + 2 > len(payload) {
			free_catalog_entry(entry, allocator)
			return {}, .Corrupt
		}
		col_count, okc := endian.get_u16(payload[off:off + 2], .Little)
		if !okc {
			free_catalog_entry(entry, allocator)
			return {}, .Corrupt
		}
		off += 2
		cols := make([]Catalog_Column, col_count, allocator)
		for i in 0 ..< int(col_count) {
			if off + 2 > len(payload) {
				free_catalog_entry(Catalog_Entry{parent_table = entry.parent_table, columns = cols[:i]}, allocator)
				return {}, .Corrupt
			}
			nlen, okn := endian.get_u16(payload[off:off + 2], .Little)
			if !okn {
				free_catalog_entry(Catalog_Entry{parent_table = entry.parent_table, columns = cols[:i]}, allocator)
				return {}, .Corrupt
			}
			off += 2
			if off + int(nlen) + 1 > len(payload) {
				free_catalog_entry(Catalog_Entry{parent_table = entry.parent_table, columns = cols[:i]}, allocator)
				return {}, .Corrupt
			}
			name := strings.clone(string(payload[off:off + int(nlen)]), allocator)
			off += int(nlen)
			flag_byte := payload[off]
			off += 1
			flags: bit_set[Catalog_Column_Flag; u8]
			if (flag_byte & 1) != 0 {
				flags += {.Desc}
			}
			cols[i] = Catalog_Column{name = name, flags = flags}
		}
		if off != len(payload) {
			free_catalog_entry(Catalog_Entry{parent_table = entry.parent_table, columns = cols}, allocator)
			return {}, .Corrupt
		}
		entry.columns = cols
		return entry, .None
	}

	// Table
	if version == CATALOG_ROW_VERSION_V1 {
		entry.next_rowid = 1
		return entry, .None
	}

	if len(payload) < 16 {
		return {}, .Corrupt
	}
	next_rowid, ok3 := endian.get_u64(payload[6:14], .Little)
	if !ok3 {
		return {}, .Corrupt
	}
	col_count, ok4 := endian.get_u16(payload[14:16], .Little)
	if !ok4 {
		return {}, .Corrupt
	}
	entry.next_rowid = next_rowid
	cols := make([]Catalog_Column, col_count, allocator)
	off := 16
	for i in 0 ..< int(col_count) {
		if off + 2 > len(payload) {
			free_catalog_entry(Catalog_Entry{columns = cols[:i]})
			return {}, .Corrupt
		}
		nlen, ok_n := endian.get_u16(payload[off:off + 2], .Little)
		if !ok_n {
			free_catalog_entry(Catalog_Entry{columns = cols[:i]})
			return {}, .Corrupt
		}
		off += 2
		if off + int(nlen) + 2 > len(payload) {
			free_catalog_entry(Catalog_Entry{columns = cols[:i]})
			return {}, .Corrupt
		}
		name := strings.clone(string(payload[off:off + int(nlen)]), allocator)
		off += int(nlen)
		tlen, ok_t := endian.get_u16(payload[off:off + 2], .Little)
		if !ok_t {
			delete(name, allocator)
			free_catalog_entry(Catalog_Entry{columns = cols[:i]})
			return {}, .Corrupt
		}
		off += 2
		if off + int(tlen) + 1 > len(payload) {
			delete(name, allocator)
			free_catalog_entry(Catalog_Entry{columns = cols[:i]})
			return {}, .Corrupt
		}
		type_name := strings.clone(string(payload[off:off + int(tlen)]), allocator)
		off += int(tlen)
		flags := transmute(bit_set[Catalog_Column_Flag; u8])payload[off]
		off += 1
		col := Catalog_Column{name = name, type_name = type_name, flags = flags}
		if .Has_Default in flags {
			if off >= len(payload) {
				delete(name, allocator)
				delete(type_name, allocator)
				free_catalog_entry(Catalog_Entry{columns = cols[:i]})
				return {}, .Corrupt
			}
			col.default_kind = Catalog_Default_Kind(payload[off])
			off += 1
			switch col.default_kind {
			case .None, .Null:
			case .Integer:
				if off + 8 > len(payload) {
					delete(name, allocator)
					delete(type_name, allocator)
					free_catalog_entry(Catalog_Entry{columns = cols[:i]})
					return {}, .Corrupt
				}
				n, ok_i := endian.get_i64(payload[off:off + 8], .Little)
				if !ok_i {
					delete(name, allocator)
					delete(type_name, allocator)
					free_catalog_entry(Catalog_Entry{columns = cols[:i]})
					return {}, .Corrupt
				}
				col.default_i = n
				off += 8
			case .Float:
				if off + 8 > len(payload) {
					delete(name, allocator)
					delete(type_name, allocator)
					free_catalog_entry(Catalog_Entry{columns = cols[:i]})
					return {}, .Corrupt
				}
				f, ok_f := endian.get_f64(payload[off:off + 8], .Little)
				if !ok_f {
					delete(name, allocator)
					delete(type_name, allocator)
					free_catalog_entry(Catalog_Entry{columns = cols[:i]})
					return {}, .Corrupt
				}
				col.default_f = f
				off += 8
			case .Text, .Blob:
				if off + 4 > len(payload) {
					delete(name, allocator)
					delete(type_name, allocator)
					free_catalog_entry(Catalog_Entry{columns = cols[:i]})
					return {}, .Corrupt
				}
				blen, ok_b := endian.get_u32(payload[off:off + 4], .Little)
				if !ok_b || off + 4 + int(blen) > len(payload) {
					delete(name, allocator)
					delete(type_name, allocator)
					free_catalog_entry(Catalog_Entry{columns = cols[:i]})
					return {}, .Corrupt
				}
				off += 4
				col.default_bytes = strings.clone(string(payload[off:off + int(blen)]), allocator)
				off += int(blen)
			case:
				delete(name, allocator)
				delete(type_name, allocator)
				free_catalog_entry(Catalog_Entry{columns = cols[:i]})
				return {}, .Corrupt
			}
		}
		cols[i] = col
	}
	if off != len(payload) {
		free_catalog_entry(Catalog_Entry{columns = cols})
		return {}, .Corrupt
	}
	entry.columns = cols
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

// catalog_update_next_rowid persists a new high-water mark into a v2 table catalog row.
catalog_update_next_rowid :: proc(e: ^Engine, name: string, next_rowid: u64) -> Engine_Error {
	if err := require_txn(e); err != .None {
		return err
	}
	if len(name) == 0 || next_rowid == 0 {
		return .Invalid_Argument
	}
	prime, perr := table_prime_tree(e)
	if perr != .None {
		return perr
	}
	ckey := catalog_table_key(name)
	defer delete(ckey)
	payload, gerr := btree_get(&prime, ckey)
	if gerr != .None {
		return gerr
	}
	defer delete(payload)
	entry, derr := decode_catalog_row(payload)
	if derr != .None {
		return derr
	}
	defer free_catalog_entry(entry)
	if entry.kind != .Table || entry.version != CATALOG_ROW_VERSION_V2 {
		return .Corrupt
	}
	entry.next_rowid = next_rowid
	updated := encode_catalog_row(entry)
	if updated == nil {
		return .Corrupt
	}
	defer delete(updated)
	// Same-sized payload (next_rowid is fixed-width).
	return btree_update_payload(&prime, ckey, updated)
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
	defer free_catalog_entry(entry)
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

// catalog_register_table allocates a user table btree and records a v2 catalog row.
catalog_register_table :: proc(
	e: ^Engine,
	name: string,
	columns: []Catalog_Column = nil,
	next_rowid: u64 = 1,
) -> (root: dbfile.Page_No, err: Engine_Error) {
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

	payload := encode_catalog_row({
		version    = CATALOG_ROW_VERSION_V2,
		kind       = .Table,
		root       = root,
		next_rowid = next_rowid,
		columns    = columns,
	})
	defer delete(payload)
	if err = btree_insert(&prime, ckey, payload); err != .None {
		return 0, err
	}
	e.schema_cookie += 1
	return root, .None
}

// catalog_register_index allocates a secondary index btree and records parent table.
// When `columns` is non-empty, writes index catalog payload v2 (column list for maintenance).
// Empty/nil columns writes legacy v1 (no column list — UPDATE/DELETE cannot maintain).
catalog_register_index :: proc(
	e: ^Engine,
	index_name, table_name: string,
	columns: []Catalog_Column = nil,
) -> (root: dbfile.Page_No, err: Engine_Error) {
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

	version := CATALOG_ROW_VERSION_V1
	if len(columns) > 0 {
		version = CATALOG_ROW_VERSION_V2
	}
	payload := encode_catalog_row({
		version      = version,
		kind         = .Index,
		root         = root,
		parent_table = table_name,
		columns      = columns,
	})
	defer delete(payload)
	if err = btree_insert(&prime, ikey, payload); err != .None {
		return 0, err
	}
	e.schema_cookie += 1
	return root, .None
}

// catalog_get_table_entry loads a table catalog row (caller frees with free_catalog_entry).
catalog_get_table_entry :: proc(
	e: ^Engine,
	name: string,
	allocator := context.allocator,
) -> (Catalog_Entry, Engine_Error) {
	if err := require_open(e); err != .None {
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
	entry, derr := decode_catalog_row(payload, allocator)
	if derr != .None {
		return {}, derr
	}
	if entry.kind != .Table {
		free_catalog_entry(entry, allocator)
		return {}, .Not_Found
	}
	return entry, .None
}

// catalog_get_index_entry loads an index catalog row (caller frees with free_catalog_entry).
catalog_get_index_entry :: proc(
	e: ^Engine,
	name: string,
	allocator := context.allocator,
) -> (Catalog_Entry, Engine_Error) {
	if err := require_open(e); err != .None {
		return {}, err
	}
	prime, perr := table_prime_tree(e)
	if perr != .None {
		return {}, perr
	}
	ikey := catalog_index_key(name)
	defer delete(ikey)
	payload, gerr := btree_get(&prime, ikey)
	if gerr != .None {
		return {}, gerr
	}
	defer delete(payload)
	entry, derr := decode_catalog_row(payload, allocator)
	if derr != .None {
		return {}, derr
	}
	if entry.kind != .Index {
		free_catalog_entry(entry, allocator)
		return {}, .Not_Found
	}
	return entry, .None
}

// Catalog_Index_Ref is a named index entry for a parent table (caller frees with free_catalog_index_ref).
Catalog_Index_Ref :: struct {
	name:  string, // owned
	entry: Catalog_Entry, // owned
}

free_catalog_index_ref :: proc(ref: Catalog_Index_Ref, allocator := context.allocator) {
	if ref.name != "" {
		delete(ref.name, allocator)
	}
	free_catalog_entry(ref.entry, allocator)
}

free_catalog_index_refs :: proc(refs: []Catalog_Index_Ref, allocator := context.allocator) {
	for r in refs {
		free_catalog_index_ref(r, allocator)
	}
	if refs != nil {
		delete(refs, allocator)
	}
}

// catalog_indexes_on_table lists index catalog rows whose parent is table_name.
catalog_indexes_on_table :: proc(
	e: ^Engine,
	table_name: string,
	allocator := context.allocator,
) -> ([]Catalog_Index_Ref, Engine_Error) {
	if err := require_open(e); err != .None {
		return nil, err
	}
	prime, perr := table_prime_tree(e)
	if perr != .None {
		return nil, perr
	}
	out := make([dynamic]Catalog_Index_Ref, 0, 4, allocator)
	cur := btree_cursor_init(&prime)
	defer btree_cursor_close(&cur)
	prefix := transmute([]u8)string(CATALOG_KEY_INDEX_PREFIX)
	if err := btree_seek_ge(&cur, prefix); err != .None {
		delete(out)
		return nil, err
	}
	for btree_cursor_valid(&cur) {
		key := btree_cursor_key(&cur)
		if !strings.has_prefix(string(key), CATALOG_KEY_INDEX_PREFIX) {
			break
		}
		payload := btree_cursor_payload(&cur)
		entry, derr := decode_catalog_row(payload, allocator)
		if derr != .None {
			free_catalog_index_refs(out[:], allocator)
			return nil, derr
		}
		if entry.kind == .Index && entry.parent_table == table_name {
			name := strings.clone(string(key)[len(CATALOG_KEY_INDEX_PREFIX):], allocator)
			append(&out, Catalog_Index_Ref{name = name, entry = entry})
		} else {
			free_catalog_entry(entry, allocator)
		}
		if err := btree_next(&cur); err != .None {
			free_catalog_index_refs(out[:], allocator)
			return nil, err
		}
	}
	return out[:], .None
}

// catalog_unregister_index removes an index catalog row and best-effort frees its root page.
catalog_unregister_index :: proc(e: ^Engine, name: string) -> Engine_Error {
	if err := require_txn(e); err != .None {
		return err
	}
	if len(name) == 0 {
		return .Invalid_Argument
	}
	prime, perr := table_prime_tree(e)
	if perr != .None {
		return perr
	}
	ikey := catalog_index_key(name)
	defer delete(ikey)
	payload, gerr := btree_get(&prime, ikey)
	if gerr != .None {
		return gerr
	}
	entry, derr := decode_catalog_row(payload)
	delete(payload)
	if derr != .None {
		return derr
	}
	if entry.kind != .Index {
		free_catalog_entry(entry)
		return .Not_Found
	}
	root := entry.root
	free_catalog_entry(entry)

	if err := btree_delete(&prime, ikey); err != .None {
		return err
	}
	e.schema_cookie += 1
	if root != 0 {
		_ = page_free(e, root)
	}
	return .None
}

// catalog_table_has_indexes reports whether any index rows name this table as parent.
catalog_table_has_indexes :: proc(e: ^Engine, table_name: string) -> (bool, Engine_Error) {
	if err := require_open(e); err != .None {
		return false, err
	}
	prime, perr := table_prime_tree(e)
	if perr != .None {
		return false, perr
	}
	cur := btree_cursor_init(&prime)
	defer btree_cursor_close(&cur)
	prefix := transmute([]u8)string(CATALOG_KEY_INDEX_PREFIX)
	if err := btree_seek_ge(&cur, prefix); err != .None {
		return false, err
	}
	for btree_cursor_valid(&cur) {
		key := btree_cursor_key(&cur)
		if !strings.has_prefix(string(key), CATALOG_KEY_INDEX_PREFIX) {
			break
		}
		payload := btree_cursor_payload(&cur)
		entry, derr := decode_catalog_row(payload)
		if derr != .None {
			return false, derr
		}
		match := entry.parent_table == table_name
		free_catalog_entry(entry)
		if match {
			return true, .None
		}
		if err := btree_next(&cur); err != .None {
			return false, err
		}
	}
	return false, .None
}

// catalog_unregister_table removes the table catalog row.
// Rejects if indexes still reference the table (.Has_Indexes).
// Best-effort: frees the table root page (does not walk the full btree).
catalog_unregister_table :: proc(e: ^Engine, name: string) -> Engine_Error {
	if err := require_txn(e); err != .None {
		return err
	}
	if len(name) == 0 {
		return .Invalid_Argument
	}
	has_idx, herr := catalog_table_has_indexes(e, name)
	if herr != .None {
		return herr
	}
	if has_idx {
		return .Has_Indexes
	}

	prime, perr := table_prime_tree(e)
	if perr != .None {
		return perr
	}
	ckey := catalog_table_key(name)
	defer delete(ckey)
	payload, gerr := btree_get(&prime, ckey)
	if gerr != .None {
		return gerr
	}
	entry, derr := decode_catalog_row(payload)
	delete(payload)
	if derr != .None {
		return derr
	}
	if entry.kind != .Table {
		free_catalog_entry(entry)
		return .Not_Found
	}
	root := entry.root
	free_catalog_entry(entry)

	if err := btree_delete(&prime, ckey); err != .None {
		return err
	}
	e.schema_cookie += 1

	// Best-effort page reclaim of the heap root only.
	if root != 0 {
		_ = page_free(e, root)
	}
	return .None
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
	defer free_catalog_entry(entry)
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
	defer free_catalog_entry(entry)
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

// table_delete_row removes the heap row keyed by rowid.
table_delete_row :: proc(tree: ^Btree, rowid: u64) -> Engine_Error {
	key: [8]u8
	if err := rowid_key(rowid, key[:]); err != .None {
		return err
	}
	return btree_delete(tree, key[:])
}

// table_rewrite_row replaces payload for an existing rowid.
// Same-length payloads update in place; otherwise delete + insert (row rewrite).
table_rewrite_row :: proc(tree: ^Btree, rowid: u64, payload: []u8) -> Engine_Error {
	key: [8]u8
	if err := rowid_key(rowid, key[:]); err != .None {
		return err
	}
	uerr := btree_update_payload(tree, key[:], payload)
	if uerr == .None {
		return .None
	}
	if uerr != .Invalid_Argument {
		return uerr
	}
	// Length mismatch: delete then insert under the same rowid.
	if derr := btree_delete(tree, key[:]); derr != .None {
		return derr
	}
	return btree_insert(tree, key[:], payload)
}

// rowid_from_key decodes a big-endian u64 rowid key (exactly 8 bytes).
rowid_from_key :: proc(key: []u8) -> (u64, Engine_Error) {
	if len(key) != 8 {
		return 0, .Invalid_Argument
	}
	v, ok := endian.get_u64(key, .Big)
	if !ok {
		return 0, .Invalid_Argument
	}
	return v, .None
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

// index_delete_entry removes index_key+rowid from a secondary index.
index_delete_entry :: proc(tree: ^Btree, index_key: []u8, rowid: u64) -> Engine_Error {
	key, kerr := index_entry_key(index_key, rowid)
	if kerr != .None {
		return kerr
	}
	defer delete(key)
	return btree_delete(tree, key)
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

// index_collect_rowids returns all rowids whose index entry has exact index_key prefix.
index_collect_rowids :: proc(
	tree: ^Btree,
	index_key: []u8,
	allocator := context.allocator,
) -> ([]u64, Engine_Error) {
	out := make([dynamic]u64, 0, 4, allocator)
	seek_key, kerr := index_entry_key(index_key, 0)
	if kerr != .None {
		delete(out)
		return nil, kerr
	}
	defer delete(seek_key)

	cur := btree_cursor_init(tree)
	defer btree_cursor_close(&cur)
	if err := btree_seek_ge(&cur, seek_key); err != .None {
		delete(out)
		return nil, err
	}
	prefix_len := len(index_key)
	for btree_cursor_valid(&cur) {
		key := btree_cursor_key(&cur)
		if len(key) < prefix_len + 8 {
			break
		}
		match := true
		for i in 0 ..< prefix_len {
			if key[i] != index_key[i] {
				match = false
				break
			}
		}
		if !match {
			break
		}
		if len(key) != prefix_len + 8 {
			break
		}
		rowid, rerr := rowid_from_key(key[prefix_len:])
		if rerr != .None {
			delete(out)
			return nil, rerr
		}
		append(&out, rowid)
		if err := btree_next(&cur); err != .None {
			delete(out)
			return nil, err
		}
	}
	return out[:], .None
}

table_prime_root :: proc(e: ^Engine) -> dbfile.Page_No {
	if e == nil {
		return 0
	}
	return e.table_prime_root
}
