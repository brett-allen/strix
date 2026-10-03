package engine

import "core:encoding/endian"
import dbfile "../dbfile"

// B+tree page layout — see docs/storage-format.md (v0.3).
BTREE_PAGE_HEADER :: 12

BTREE_PAGE_LEAF :: u8(1)
BTREE_PAGE_INTERIOR :: u8(2)

// MAX_CATALOG_KEY fits "table:"/"index:" + name for write-through binding.
MAX_CATALOG_KEY :: 160

Btree_Bind :: enum u8 {
	None = 0,        // illegal for root-changing mutations → .Unbound_Root
	Caller_Root,     // root changes write through root_slot (^Page_No)
	Table_Prime,     // root changes update Engine.table_prime_root
	Catalog_Object,  // root changes update table_prime row at cat_key
}

Btree :: struct {
	engine:      ^Engine,
	root:        dbfile.Page_No,
	bind:        Btree_Bind,
	root_slot:   ^dbfile.Page_No, // required for Caller_Root
	cat_key_len: u16,
	cat_key:     [MAX_CATALOG_KEY]u8,
}

Btree_Cursor :: struct {
	tree:         ^Btree,
	page_no:      dbfile.Page_No,
	cell_index:   int,
	valid:        bool,
	key_buf:      [dynamic]u8,
	payload_buf:  [dynamic]u8,
}

Path_Slot :: struct {
	page_no:    dbfile.Page_No,
	child_slot: int, // child index we descended into (0..n_cells); n_cells => rightmost
}

key_compare :: proc(a, b: []u8) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	if len(a) < len(b) {
		return -1
	}
	if len(a) > len(b) {
		return 1
	}
	return 0
}

page_type :: proc(page: []u8) -> u8 {
	return page[0]
}

page_n_cells :: proc(page: []u8) -> u16 {
	n, _ := endian.get_u16(page[2:4], .Little)
	return n
}

page_cell_area :: proc(page: []u8) -> u16 {
	v, _ := endian.get_u16(page[4:6], .Little)
	return v
}

page_special :: proc(page: []u8) -> u32 {
	v, _ := endian.get_u32(page[8:12], .Little)
	return v
}

set_page_type :: proc(page: []u8, t: u8) {
	page[0] = t
	page[1] = 0
}

set_page_n_cells :: proc(page: []u8, n: u16) {
	endian.put_u16(page[2:4], .Little, n)
}

set_page_cell_area :: proc(page: []u8, off: u16) {
	endian.put_u16(page[4:6], .Little, off)
}

set_page_special :: proc(page: []u8, v: u32) {
	endian.put_u32(page[8:12], .Little, v)
}

init_empty_leaf :: proc(page: []u8) {
	for i in 0 ..< len(page) {
		page[i] = 0
	}
	set_page_type(page, BTREE_PAGE_LEAF)
	set_page_n_cells(page, 0)
	set_page_cell_area(page, u16(len(page)))
	set_page_special(page, 0)
}

init_empty_interior :: proc(page: []u8, rightmost: dbfile.Page_No) {
	for i in 0 ..< len(page) {
		page[i] = 0
	}
	set_page_type(page, BTREE_PAGE_INTERIOR)
	set_page_n_cells(page, 0)
	set_page_cell_area(page, u16(len(page)))
	set_page_special(page, u32(rightmost))
}

cell_ptr_offset :: proc(index: int) -> int {
	return BTREE_PAGE_HEADER + index * 2
}

get_cell_ptr :: proc(page: []u8, index: int) -> (u16, Engine_Error) {
	n := int(page_n_cells(page))
	if index < 0 || index >= n {
		return 0, .Corrupt
	}
	off := cell_ptr_offset(index)
	ptr, ok := endian.get_u16(page[off:off + 2], .Little)
	if !ok {
		return 0, .Corrupt
	}
	return ptr, .None
}

set_cell_ptr :: proc(page: []u8, index: int, ptr: u16) {
	off := cell_ptr_offset(index)
	endian.put_u16(page[off:off + 2], .Little, ptr)
}

free_space :: proc(page: []u8) -> int {
	n := int(page_n_cells(page))
	ptrs_end := BTREE_PAGE_HEADER + n * 2
	return int(page_cell_area(page)) - ptrs_end
}

leaf_cell_size :: proc(key_len, payload_len: int) -> int {
	return 4 + key_len + payload_len
}

interior_cell_size :: proc(key_len: int) -> int {
	return 4 + 2 + key_len // child u32 + key_len u16 + key
}

max_leaf_record :: proc(page_size: int) -> int {
	// One cell + one pointer on an otherwise empty page.
	return page_size - BTREE_PAGE_HEADER - 2 - 4
}

read_leaf_cell :: proc(page: []u8, index: int) -> (key, payload: []u8, err: Engine_Error) {
	ptr, perr := get_cell_ptr(page, index)
	if perr != .None {
		return nil, nil, perr
	}
	if int(ptr) + 4 > len(page) {
		return nil, nil, .Corrupt
	}
	klen, ok1 := endian.get_u16(page[ptr:ptr + 2], .Little)
	plen, ok2 := endian.get_u16(page[ptr + 2:ptr + 4], .Little)
	if !ok1 || !ok2 {
		return nil, nil, .Corrupt
	}
	start := int(ptr) + 4
	end := start + int(klen) + int(plen)
	if end > len(page) {
		return nil, nil, .Corrupt
	}
	key = page[start:start + int(klen)]
	payload = page[start + int(klen):end]
	return key, payload, .None
}

read_interior_cell :: proc(page: []u8, index: int) -> (child: dbfile.Page_No, key: []u8, err: Engine_Error) {
	ptr, perr := get_cell_ptr(page, index)
	if perr != .None {
		return 0, nil, perr
	}
	if int(ptr) + 6 > len(page) {
		return 0, nil, .Corrupt
	}
	ch, ok1 := endian.get_u32(page[ptr:ptr + 4], .Little)
	klen, ok2 := endian.get_u16(page[ptr + 4:ptr + 6], .Little)
	if !ok1 || !ok2 {
		return 0, nil, .Corrupt
	}
	start := int(ptr) + 6
	end := start + int(klen)
	if end > len(page) {
		return 0, nil, .Corrupt
	}
	return dbfile.Page_No(ch), page[start:end], .None
}

// Find first index with key >= target; n_cells if all smaller.
leaf_lower_bound :: proc(page: []u8, target: []u8) -> (index: int, exact: bool, err: Engine_Error) {
	n := int(page_n_cells(page))
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		k, _, e := read_leaf_cell(page, mid)
		if e != .None {
			return 0, false, e
		}
		c := key_compare(k, target)
		if c < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < n {
		k, _, e := read_leaf_cell(page, lo)
		if e != .None {
			return 0, false, e
		}
		if key_compare(k, target) == 0 {
			return lo, true, .None
		}
	}
	return lo, false, .None
}

// Child to follow for key on an interior page (B+tree separator rules).
interior_child_for_key :: proc(page: []u8, target: []u8) -> (child: dbfile.Page_No, slot: int, err: Engine_Error) {
	n := int(page_n_cells(page))
	for i in 0 ..< n {
		ch, k, e := read_interior_cell(page, i)
		if e != .None {
			return 0, 0, e
		}
		if key_compare(target, k) < 0 {
			return ch, i, .None
		}
	}
	return dbfile.Page_No(page_special(page)), n, .None
}

child_at_slot :: proc(page: []u8, slot: int) -> (dbfile.Page_No, Engine_Error) {
	n := int(page_n_cells(page))
	if slot < 0 || slot > n {
		return 0, .Corrupt
	}
	if slot == n {
		return dbfile.Page_No(page_special(page)), .None
	}
	ch, _, err := read_interior_cell(page, slot)
	return ch, err
}
