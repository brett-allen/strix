package engine

import "core:encoding/endian"
import "core:slice"
import dbfile "../dbfile"
import paging "../paging"

Leaf_Record :: struct {
	key:     []u8,
	payload: []u8,
}

Interior_Record :: struct {
	child: dbfile.Page_No,
	key:   []u8,
}

write_leaf_cell_bytes :: proc(dst: []u8, key, payload: []u8) -> int {
	endian.put_u16(dst[0:2], .Little, u16(len(key)))
	endian.put_u16(dst[2:4], .Little, u16(len(payload)))
	copy(dst[4:], key)
	copy(dst[4 + len(key):], payload)
	return 4 + len(key) + len(payload)
}

write_interior_cell_bytes :: proc(dst: []u8, child: dbfile.Page_No, key: []u8) -> int {
	endian.put_u32(dst[0:4], .Little, u32(child))
	endian.put_u16(dst[4:6], .Little, u16(len(key)))
	copy(dst[6:], key)
	return 6 + len(key)
}

leaf_packed_bytes :: proc(records: []Leaf_Record) -> int {
	total := BTREE_PAGE_HEADER
	for r in records {
		total += 2 + leaf_cell_size(len(r.key), len(r.payload))
	}
	return total
}

interior_packed_bytes :: proc(records: []Interior_Record) -> int {
	total := BTREE_PAGE_HEADER
	for r in records {
		total += 2 + interior_cell_size(len(r.key))
	}
	return total
}

leaf_fits_page :: proc(page_size: int, records: []Leaf_Record) -> bool {
	return leaf_packed_bytes(records) <= page_size
}

interior_fits_page :: proc(page_size: int, records: []Interior_Record) -> bool {
	return interior_packed_bytes(records) <= page_size
}

// choose_leaf_split_mid picks mid in [1, n) so both halves fit; prefers byte-balanced split.
choose_leaf_split_mid :: proc(page_size: int, all: []Leaf_Record) -> (mid: int, ok: bool) {
	n := len(all)
	if n < 2 {
		return 0, false
	}
	best_mid := -1
	best_diff := int(1 << 30)
	for m in 1 ..< n {
		if !leaf_fits_page(page_size, all[:m]) || !leaf_fits_page(page_size, all[m:]) {
			continue
		}
		ld := leaf_packed_bytes(all[:m])
		rd := leaf_packed_bytes(all[m:])
		diff := ld - rd if ld >= rd else rd - ld
		if diff < best_diff {
			best_diff = diff
			best_mid = m
		}
	}
	if best_mid < 0 {
		return 0, false
	}
	return best_mid, true
}

// choose_interior_split_mid picks promoted index mid in [0, n) so left=recs[:mid]
// and right=recs[mid+1:] both fit.
choose_interior_split_mid :: proc(page_size: int, recs: []Interior_Record) -> (mid: int, ok: bool) {
	n := len(recs)
	if n < 2 {
		return 0, false
	}
	best_mid := -1
	best_diff := int(1 << 30)
	for m in 0 ..< n {
		if !interior_fits_page(page_size, recs[:m]) || !interior_fits_page(page_size, recs[m + 1:]) {
			continue
		}
		ld := interior_packed_bytes(recs[:m])
		rd := interior_packed_bytes(recs[m + 1:])
		diff := ld - rd if ld >= rd else rd - ld
		if diff < best_diff {
			best_diff = diff
			best_mid = m
		}
	}
	if best_mid < 0 {
		return 0, false
	}
	return best_mid, true
}

// pack_leaf_scratch builds a full leaf page image into dst (must be page-sized).
// Does not touch any other buffer. Fails without partial writes beyond dst.
pack_leaf_scratch :: proc(dst: []u8, records: []Leaf_Record, next_leaf: dbfile.Page_No) -> Engine_Error {
	if !leaf_fits_page(len(dst), records) {
		return .Too_Large
	}
	init_empty_leaf(dst)
	set_page_special(dst, u32(next_leaf))
	cell_area := len(dst)
	for i in 0 ..< len(records) {
		sz := leaf_cell_size(len(records[i].key), len(records[i].payload))
		cell_area -= sz
		write_leaf_cell_bytes(dst[cell_area:], records[i].key, records[i].payload)
		set_cell_ptr(dst, i, u16(cell_area))
	}
	set_page_n_cells(dst, u16(len(records)))
	set_page_cell_area(dst, u16(cell_area))
	return .None
}

pack_interior_scratch :: proc(dst: []u8, records: []Interior_Record, rightmost: dbfile.Page_No) -> Engine_Error {
	if !interior_fits_page(len(dst), records) {
		return .Too_Large
	}
	init_empty_interior(dst, rightmost)
	cell_area := len(dst)
	for i in 0 ..< len(records) {
		sz := interior_cell_size(len(records[i].key))
		cell_area -= sz
		write_interior_cell_bytes(dst[cell_area:], records[i].child, records[i].key)
		set_cell_ptr(dst, i, u16(cell_area))
	}
	set_page_n_cells(dst, u16(len(records)))
	set_page_cell_area(dst, u16(cell_area))
	return .None
}

// rebuild_leaf packs into scratch first, then copies over `page` only on success.
rebuild_leaf :: proc(page: []u8, records: []Leaf_Record, next_leaf: dbfile.Page_No) -> Engine_Error {
	scratch := make([]u8, len(page))
	defer delete(scratch)
	if err := pack_leaf_scratch(scratch, records, next_leaf); err != .None {
		return err
	}
	copy(page, scratch)
	return .None
}

rebuild_interior :: proc(page: []u8, records: []Interior_Record, rightmost: dbfile.Page_No) -> Engine_Error {
	scratch := make([]u8, len(page))
	defer delete(scratch)
	if err := pack_interior_scratch(scratch, records, rightmost); err != .None {
		return err
	}
	copy(page, scratch)
	return .None
}

collect_leaf_records :: proc(page: []u8, allocator := context.allocator) -> ([]Leaf_Record, Engine_Error) {
	n := int(page_n_cells(page))
	out := make([]Leaf_Record, n, allocator)
	for i in 0 ..< n {
		k, p, err := read_leaf_cell(page, i)
		if err != .None {
			for j in 0 ..< i {
				delete(out[j].key)
				delete(out[j].payload)
			}
			delete(out)
			return nil, err
		}
		out[i] = Leaf_Record{
			key     = slice.clone(k, allocator),
			payload = slice.clone(p, allocator),
		}
	}
	return out, .None
}

free_leaf_records :: proc(recs: []Leaf_Record) {
	for r in recs {
		delete(r.key)
		delete(r.payload)
	}
	delete(recs)
}

collect_interior_records :: proc(page: []u8, allocator := context.allocator) -> ([]Interior_Record, Engine_Error) {
	n := int(page_n_cells(page))
	out := make([]Interior_Record, n, allocator)
	for i in 0 ..< n {
		ch, k, err := read_interior_cell(page, i)
		if err != .None {
			for j in 0 ..< i {
				delete(out[j].key)
			}
			delete(out)
			return nil, err
		}
		out[i] = Interior_Record{
			child = ch,
			key   = slice.clone(k, allocator),
		}
	}
	return out, .None
}

free_interior_records :: proc(recs: []Interior_Record) {
	for r in recs {
		delete(r.key)
	}
	delete(recs)
}

leaf_insert_nosplit :: proc(page: []u8, key, payload: []u8) -> Engine_Error {
	idx, exact, err := leaf_lower_bound(page, key)
	if err != .None {
		return err
	}
	if exact {
		return .Exists
	}
	return leaf_insert_inplace(page, idx, key, payload)
}

leaf_insert_inplace :: proc(page: []u8, idx: int, key, payload: []u8) -> Engine_Error {
	n := int(page_n_cells(page))
	sz := leaf_cell_size(len(key), len(payload))
	if free_space(page) < 2 + sz {
		return .Too_Large
	}
	cell_area := int(page_cell_area(page)) - sz
	write_leaf_cell_bytes(page[cell_area:], key, payload)

	for i := n; i > idx; i -= 1 {
		ptr, _ := get_cell_ptr(page, i - 1)
		set_cell_ptr(page, i, ptr)
	}
	set_cell_ptr(page, idx, u16(cell_area))
	set_page_n_cells(page, u16(n + 1))
	set_page_cell_area(page, u16(cell_area))
	return .None
}

leaf_remove_at :: proc(page: []u8, idx: int) -> Engine_Error {
	recs, err := collect_leaf_records(page)
	if err != .None {
		return err
	}
	defer free_leaf_records(recs)
	if idx < 0 || idx >= len(recs) {
		return .Not_Found
	}
	next := dbfile.Page_No(page_special(page))
	kept := make([dynamic]Leaf_Record, 0, len(recs) - 1)
	defer {
		for r in kept {
			delete(r.key)
			delete(r.payload)
		}
		delete(kept)
	}
	for i in 0 ..< len(recs) {
		if i == idx {
			continue
		}
		append(&kept, Leaf_Record{
			key     = slice.clone(recs[i].key),
			payload = slice.clone(recs[i].payload),
		})
	}
	return rebuild_leaf(page, kept[:], next)
}

pin_rw :: proc(e: ^Engine, page_no: dbfile.Page_No) -> ([]u8, Engine_Error) {
	data, err := paging.get_readwrite(&e.pager, page_no)
	return data, from_page_error(err)
}

pin_ro :: proc(e: ^Engine, page_no: dbfile.Page_No) -> ([]u8, Engine_Error) {
	data, err := paging.get_readonly(&e.pager, page_no)
	return data, from_page_error(err)
}

unpin_page :: proc(e: ^Engine, page_no: dbfile.Page_No) {
	_ = paging.unpin(&e.pager, page_no)
}

publish_page :: proc(e: ^Engine, page_no: dbfile.Page_No, image: []u8) -> Engine_Error {
	data, err := pin_rw(e, page_no)
	if err != .None {
		return err
	}
	if len(data) != len(image) {
		unpin_page(e, page_no)
		return .Corrupt
	}
	copy(data, image)
	unpin_page(e, page_no)
	return .None
}
