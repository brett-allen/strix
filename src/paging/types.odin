package paging

import dbfile "../dbfile"

DEFAULT_CACHE_FRAMES :: 64

Pager_Options :: struct {
	cache_frames: int, // 0 → DEFAULT_CACHE_FRAMES
}

Frame :: struct {
	page_no:   dbfile.Page_No,
	data:      []u8,
	pin_count: int,
	dirty:     bool,
	valid:     bool,
	lru_tick:  u64,
}

/*
	Pager — buffer pool + freelist over a dbfile.Db_File.

	Owns the logical page_count and freelist_head for the open session.
	On-disk bootstrap is updated only in flush() (data pages first, then page 0, then sync).
	Page 0 is not cached here; callers pass Bootstrap meta into flush.
*/
Pager :: struct {
	file:                     dbfile.Db_File,
	owns_file:                bool,
	closed:                   bool,
	page_size:                u32,
	page_count:               u32, // current (txn) logical count, includes page 0
	freelist_head:            dbfile.Page_No,
	committed_page_count:     u32,
	committed_freelist_head:  dbfile.Page_No,
	// free_pages: in-memory membership set for O(1) double-free checks.
	// Rebuilt from the on-disk/cache chain at open and after discard_dirty;
	// kept in sync on alloc_page / free_page. On-disk format unchanged.
	free_pages:               map[dbfile.Page_No]bool,
	frames:                   []Frame,
	page_index:               map[dbfile.Page_No]int, // page_no → frame index
	lru_clock:                u64,
	cache_hits:               u64,
	cache_misses:             u64,
	// H2: set when flush wrote some pages then failed. Blocks discard_dirty until
	// a successful flush clears it. Test hook: flush_fail_after_data_writes.
	flush_failed:                  bool,
	flush_fail_after_data_writes:  int, // 0 = off; N = fail after N successful data page writes
}
