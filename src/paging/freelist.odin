package paging

import "core:encoding/endian"
import "core:slice"
import dbfile "../dbfile"

// Freelist trunk page layout (S1): first 4 bytes = next free Page_No (LE); 0 = end.
// See docs/storage-format.md.
FREELIST_NEXT_OFFSET :: 0

read_freelist_next :: proc(data: []u8) -> (dbfile.Page_No, Page_Error) {
	if len(data) < 4 {
		return 0, .Invalid_Argument
	}
	next, ok := endian.get_u32(data[0:4], .Little)
	if !ok {
		return 0, .Invalid_Argument
	}
	return dbfile.Page_No(next), .None
}

write_freelist_next :: proc(data: []u8, next: dbfile.Page_No) -> Page_Error {
	if len(data) < 4 {
		return .Invalid_Argument
	}
	if !endian.put_u32(data[0:4], .Little, u32(next)) {
		return .Invalid_Argument
	}
	return .None
}

// alloc_page returns a free page number, zero-filled in the cache and marked dirty.
// Prefer freelist; otherwise extend the logical page_count (file grows on flush).
alloc_page :: proc(p: ^Pager) -> (page_no: dbfile.Page_No, err: Page_Error) {
	if e := require_open(p); e != .None {
		return 0, e
	}

	if p.freelist_head != 0 {
		page_no = p.freelist_head
		data, gerr := get_readwrite(p, page_no)
		if gerr != .None {
			return 0, gerr
		}
		defer unpin(p, page_no)

		next, nerr := read_freelist_next(data)
		if nerr != .None {
			return 0, nerr
		}
		// Reject self-loop / out-of-range / cyclic remainder (M3).
		if next == page_no {
			return 0, .Io
		}
		if next != 0 && u32(next) >= p.page_count {
			return 0, .Io // corrupt freelist
		}
		if verr := freelist_validate_chain(p, next); verr != .None {
			return 0, verr
		}
		p.freelist_head = next
		slice.zero(data)
		return page_no, .None
	}

	// Extend: new page number is current page_count.
	page_no = dbfile.Page_No(p.page_count)
	p.page_count += 1

	idx, ferr := frame_acquire_empty(p, page_no)
	if ferr != .None {
		p.page_count -= 1
		return 0, ferr
	}
	fr := &p.frames[idx]
	slice.zero(fr.data)
	fr.dirty = true
	fr.pin_count = 0
	touch_frame(p, fr)
	// Leave unpinned; caller will get_readwrite if needed.
	return page_no, .None
}

// free_page pushes page_no onto the freelist and marks the trunk page dirty.
// Rejects pages already on the freelist (prevents cycles from double-free).
free_page :: proc(p: ^Pager, page_no: dbfile.Page_No) -> Page_Error {
	if e := require_open(p); e != .None {
		return e
	}
	if page_no == 0 {
		return .Invalid_Argument
	}
	if u32(page_no) >= p.page_count {
		return .Page_Out_Of_Range
	}

	if idx, found := p.page_index[page_no]; found {
		if p.frames[idx].valid && p.frames[idx].pin_count > 0 {
			return .Pinned
		}
	}

	on_list, cerr := freelist_contains(p, page_no)
	if cerr != .None {
		return cerr
	}
	if on_list {
		return .Already_Free
	}

	data, gerr := get_readwrite(p, page_no)
	if gerr != .None {
		return gerr
	}
	defer unpin(p, page_no)

	slice.zero(data)
	if err := write_freelist_next(data, p.freelist_head); err != .None {
		return err
	}
	p.freelist_head = page_no
	return .None
}

// freelist_validate_chain walks from start with a step bound; rejects cycles / OOR.
freelist_validate_chain :: proc(p: ^Pager, start: dbfile.Page_No) -> Page_Error {
	cur := start
	steps := 0
	limit := int(p.page_count) + 1
	for cur != 0 {
		steps += 1
		if steps > limit {
			return .Io
		}
		if u32(cur) >= p.page_count {
			return .Io
		}
		next, nerr := peek_freelist_next(p, cur)
		if nerr != .None {
			return nerr
		}
		if next == cur {
			return .Io // self-loop
		}
		if next != 0 && u32(next) >= p.page_count {
			return .Io
		}
		cur = next
	}
	return .None
}

// freelist_contains walks the in-memory freelist chain (cache, else disk).
freelist_contains :: proc(p: ^Pager, page_no: dbfile.Page_No) -> (found: bool, err: Page_Error) {
	cur := p.freelist_head
	steps := 0
	limit := int(p.page_count) + 1
	for cur != 0 {
		if cur == page_no {
			return true, .None
		}
		steps += 1
		if steps > limit {
			return false, .Io // cycle / corrupt freelist
		}
		next, nerr := peek_freelist_next(p, cur)
		if nerr != .None {
			return false, nerr
		}
		if next == cur {
			return false, .Io
		}
		if next != 0 && u32(next) >= p.page_count {
			return false, .Io
		}
		cur = next
	}
	return false, .None
}

// peek_freelist_next reads next_free without permanently changing pin state.
peek_freelist_next :: proc(p: ^Pager, page_no: dbfile.Page_No) -> (dbfile.Page_No, Page_Error) {
	if idx, ok := p.page_index[page_no]; ok && p.frames[idx].valid {
		return read_freelist_next(p.frames[idx].data)
	}
	if u32(page_no) >= p.file.page_count {
		return 0, .Io
	}
	buf := make([]u8, p.page_size)
	defer delete(buf)
	derr := dbfile.read_page(&p.file, page_no, buf)
	if derr != .None {
		return 0, from_db_error(derr)
	}
	return read_freelist_next(buf)
}

require_open :: proc(p: ^Pager) -> Page_Error {
	if p == nil || p.closed {
		return .Closed
	}
	return .None
}

frame_acquire_empty :: proc(p: ^Pager, page_no: dbfile.Page_No) -> (idx: int, err: Page_Error) {
	// Reuse existing slot for this page_no if present.
	if existing, found := p.page_index[page_no]; found {
		fr := &p.frames[existing]
		if fr.pin_count > 0 {
			return -1, .Pinned
		}
		fr.valid = true
		fr.page_no = page_no
		fr.dirty = false
		touch_frame(p, fr)
		return existing, .None
	}

	// Free invalid slot.
	for i in 0 ..< len(p.frames) {
		if !p.frames[i].valid {
			bind_frame(p, i, page_no)
			return i, .None
		}
	}

	// Evict clean unpinned frame (LRU).
	victim := -1
	best_tick: u64 = ~u64(0)
	for i in 0 ..< len(p.frames) {
		fr := &p.frames[i]
		if fr.pin_count != 0 || fr.dirty {
			continue
		}
		if fr.lru_tick < best_tick {
			best_tick = fr.lru_tick
			victim = i
		}
	}
	if victim < 0 {
		return -1, .Cache_Full
	}

	old := p.frames[victim].page_no
	delete_key(&p.page_index, old)
	bind_frame(p, victim, page_no)
	return victim, .None
}

bind_frame :: proc(p: ^Pager, idx: int, page_no: dbfile.Page_No) {
	fr := &p.frames[idx]
	fr.page_no = page_no
	fr.valid = true
	fr.dirty = false
	fr.pin_count = 0
	touch_frame(p, fr)
	p.page_index[page_no] = idx
}

touch_frame :: proc(p: ^Pager, fr: ^Frame) {
	p.lru_clock += 1
	fr.lru_tick = p.lru_clock
}

// Ensure frame data buffer exists (allocated once per frame slot).
ensure_frame_buf :: proc(p: ^Pager, fr: ^Frame) {
	if fr.data == nil {
		fr.data = make([]u8, p.page_size)
	}
}

invalidate_frame :: proc(p: ^Pager, idx: int) {
	fr := &p.frames[idx]
	if !fr.valid {
		return
	}
	delete_key(&p.page_index, fr.page_no)
	fr.valid = false
	fr.dirty = false
	fr.pin_count = 0
	fr.page_no = 0
}
