package paging

import "core:slice"
import dbfile "../dbfile"

// pager_open_create creates a new DB file and attaches a pager.
pager_open_create :: proc(path: string, opts: Pager_Options = {}, db_opts: dbfile.Open_Options = {}) -> (p: Pager, err: Page_Error) {
	file, derr := dbfile.open_create(path, db_opts)
	if derr != .None {
		return {}, from_db_error(derr)
	}
	return pager_attach(file, opts, true)
}

// pager_open_existing opens an existing DB file and attaches a pager.
pager_open_existing :: proc(path: string, opts: Pager_Options = {}) -> (p: Pager, err: Page_Error) {
	file, derr := dbfile.open_existing(path)
	if derr != .None {
		return {}, from_db_error(derr)
	}
	return pager_attach(file, opts, true)
}

// pager_open_memory creates an in-memory DB + pager (tests).
pager_open_memory :: proc(opts: Pager_Options = {}, db_opts: dbfile.Open_Options = {}) -> (p: Pager, err: Page_Error) {
	file, derr := dbfile.open_memory(db_opts)
	if derr != .None {
		return {}, from_db_error(derr)
	}
	return pager_attach(file, opts, true)
}

pager_attach :: proc(file: dbfile.Db_File, opts: Pager_Options, owns_file: bool) -> (p: Pager, err: Page_Error) {
	nframes := opts.cache_frames
	if nframes <= 0 {
		nframes = DEFAULT_CACHE_FRAMES
	}

	f := file
	boot, berr := dbfile.read_bootstrap(&f)
	if berr != .None {
		if owns_file {
			dbfile.close(&f)
		}
		return {}, from_db_error(berr)
	}

	p = Pager{
		file                    = f,
		owns_file               = owns_file,
		closed                  = false,
		page_size               = boot.page_size,
		page_count              = boot.page_count,
		freelist_head           = boot.freelist_head,
		committed_page_count    = boot.page_count,
		committed_freelist_head = boot.freelist_head,
		free_pages              = make(map[dbfile.Page_No]bool),
		frames                  = make([]Frame, nframes),
		page_index              = make(map[dbfile.Page_No]int),
	}

	for i in 0 ..< nframes {
		p.frames[i].data = make([]u8, p.page_size)
	}
	// Validate freelist once at open; membership checks are O(1) thereafter.
	if verr := freelist_rebuild_set(&p); verr != .None {
		_ = pager_close(&p)
		return {}, verr
	}
	return p, .None
}

pager_close :: proc(p: ^Pager) -> Page_Error {
	if p == nil || p.closed {
		return .None
	}
	// Never tear down cache/file over a live flush fence — dirty frames are the
	// only recovery state for a retry flush. Callers must flush successfully first.
	if p.flush_failed {
		return .Flush_Failed
	}
	for i in 0 ..< len(p.frames) {
		if p.frames[i].data != nil {
			delete(p.frames[i].data)
			p.frames[i].data = nil
		}
	}
	delete(p.frames)
	p.frames = nil
	delete(p.page_index)
	delete(p.free_pages)

	err: Page_Error = .None
	if p.owns_file {
		err = from_db_error(dbfile.close(&p.file))
	}
	p.closed = true
	return err
}

// pager_flush_failed reports whether a partial-flush fence is active.
pager_flush_failed :: proc(p: ^Pager) -> bool {
	return p != nil && !p.closed && p.flush_failed
}

// get_readonly pins a data page for reading (loads from disk on miss).
// Page 0 is not available through the cache — use flush/bootstrap APIs.
get_readonly :: proc(p: ^Pager, page_no: dbfile.Page_No) -> (data: []u8, err: Page_Error) {
	return get_page(p, page_no, false)
}

// get_readwrite pins a data page and marks it dirty.
get_readwrite :: proc(p: ^Pager, page_no: dbfile.Page_No) -> (data: []u8, err: Page_Error) {
	return get_page(p, page_no, true)
}

get_page :: proc(p: ^Pager, page_no: dbfile.Page_No, write: bool) -> (data: []u8, err: Page_Error) {
	if e := require_open(p); e != .None {
		return nil, e
	}
	if page_no == 0 {
		return nil, .Invalid_Argument
	}
	if u32(page_no) >= p.page_count {
		return nil, .Page_Out_Of_Range
	}

	if idx, found := p.page_index[page_no]; found && p.frames[idx].valid {
		p.cache_hits += 1
		fr := &p.frames[idx]
		fr.pin_count += 1
		if write {
			fr.dirty = true
		}
		touch_frame(p, fr)
		return fr.data, .None
	}

	p.cache_misses += 1
	idx, aerr := frame_acquire_empty(p, page_no)
	if aerr != .None {
		return nil, aerr
	}
	fr := &p.frames[idx]
	ensure_frame_buf(p, fr)

	// Newly extended pages (beyond committed file size) are zero-filled in cache
	// by alloc_page; if we land here for a page within the on-disk range, load it.
	if u32(page_no) < p.file.page_count {
		derr := dbfile.read_page(&p.file, page_no, fr.data)
		if derr != .None {
			invalidate_frame(p, idx)
			return nil, from_db_error(derr)
		}
	} else {
		// Logical page exists in pager but not yet on disk (alloc extend, pre-flush).
		slice.zero(fr.data)
	}

	fr.valid = true
	fr.pin_count = 1
	fr.dirty = write
	touch_frame(p, fr)
	return fr.data, .None
}

unpin :: proc(p: ^Pager, page_no: dbfile.Page_No) -> Page_Error {
	if e := require_open(p); e != .None {
		return e
	}
	idx, found := p.page_index[page_no]
	if !found || !p.frames[idx].valid {
		return .Not_Pinned
	}
	fr := &p.frames[idx]
	if fr.pin_count <= 0 {
		return .Not_Pinned
	}
	fr.pin_count -= 1
	touch_frame(p, fr)
	return .None
}

/*
	flush persists the dirty set using the v1 write order:

	  0. if any dirty data pages: set page-0 flush-in-progress fence + sync
	  1. dirty data pages (page_no >= 1) in ascending page_no order
	  2. page 0 bootstrap (clears fence; pager supplies page_count + freelist_head)
	  3. dbfile.sync()

	`bootstrap` supplies caller-owned meta (commit_counter, schema_cookie,
	table_prime_root). page_size / format_version / page_count / freelist_head
	are taken from the pager.

	Returns .Pinned if any cache frame is still pinned.
	On partial failure after the fence is set (or any data page write), sets
	flush_failed and returns an error; discard_dirty is then refused until a
	flush succeeds (H2). A crash with the fence still set refuses reopen (.Torn_Flush).
*/
flush :: proc(p: ^Pager, bootstrap: dbfile.Bootstrap) -> Page_Error {
	if e := require_open(p); e != .None {
		return e
	}

	// Refuse flush while any frame is pinned (mirrors discard_dirty).
	for i in 0 ..< len(p.frames) {
		fr := &p.frames[i]
		if fr.valid && fr.pin_count > 0 {
			return .Pinned
		}
	}

	dirty_nos := make([dynamic]dbfile.Page_No, 0, 16)
	defer delete(dirty_nos)
	for i in 0 ..< len(p.frames) {
		fr := &p.frames[i]
		if fr.valid && fr.dirty && fr.page_no != 0 {
			append(&dirty_nos, fr.page_no)
		}
	}
	slice.sort(dirty_nos[:])

	// Durable fence before in-place overwrites so a crash mid-flush refuses reopen
	// rather than serving a torn prior commit (v1: no WAL / rollback journal).
	marked := false
	if len(dirty_nos) > 0 {
		merr := dbfile.mark_flush_in_progress(&p.file)
		if merr != .None {
			return from_db_error(merr)
		}
		marked = true
	}

	wrote_data := 0
	for page_no in dirty_nos {
		idx := p.page_index[page_no]
		fr := &p.frames[idx]
		derr := dbfile.write_page(&p.file, page_no, fr.data)
		if derr != .None {
			if marked || wrote_data > 0 {
				p.flush_failed = true
			}
			return from_db_error(derr)
		}
		wrote_data += 1
		if p.flush_fail_after_data_writes > 0 && wrote_data >= p.flush_fail_after_data_writes {
			p.flush_failed = true
			return .Flush_Failed
		}
	}

	boot := bootstrap
	boot.format_version = dbfile.FORMAT_VERSION
	boot.page_size = p.page_size
	boot.page_count = p.page_count
	boot.freelist_head = p.freelist_head
	// Keep caller's commit_counter, schema_cookie, table_prime_root.
	// write_bootstrap zeros page-0 reserved bytes → clears flush-in-progress fence.

	derr := dbfile.write_bootstrap(&p.file, boot)
	if derr != .None {
		if marked || wrote_data > 0 {
			p.flush_failed = true
		}
		return from_db_error(derr)
	}
	derr = dbfile.sync(&p.file)
	if derr != .None {
		// Bootstrap may already be on disk; treat as flush fence.
		p.flush_failed = true
		return from_db_error(derr)
	}

	for i in 0 ..< len(p.frames) {
		if p.frames[i].valid {
			p.frames[i].dirty = false
		}
	}
	p.committed_page_count = p.page_count
	p.committed_freelist_head = p.freelist_head
	// Align dbfile's in-memory page_count with bootstrap (write_page may have grown it).
	p.file.page_count = p.page_count
	p.flush_failed = false
	return .None
}

// discard_dirty rolls back the in-memory txn: drop dirty frames and restore
// page_count / freelist_head to the last successful flush (or open).
// Refused with .Flush_Failed if a prior flush partially wrote data pages.
discard_dirty :: proc(p: ^Pager) -> Page_Error {
	if e := require_open(p); e != .None {
		return e
	}
	if p.flush_failed {
		return .Flush_Failed
	}

	for i in 0 ..< len(p.frames) {
		fr := &p.frames[i]
		if !fr.valid {
			continue
		}
		if fr.pin_count > 0 {
			return .Pinned
		}
		if fr.dirty {
			invalidate_frame(p, i)
		} else if u32(fr.page_no) >= p.committed_page_count {
			// Clean frame for a page that only existed in the aborted txn.
			invalidate_frame(p, i)
		}
	}

	p.page_count = p.committed_page_count
	p.freelist_head = p.committed_freelist_head
	// Rebuild membership from the restored chain (aborted frees dropped with dirty frames).
	return freelist_rebuild_set(p)
}

page_size :: proc(p: ^Pager) -> u32 {
	return p.page_size if p != nil else 0
}

logical_page_count :: proc(p: ^Pager) -> u32 {
	return p.page_count if p != nil else 0
}
