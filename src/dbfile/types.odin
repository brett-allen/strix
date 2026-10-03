package dbfile

// On-disk magic: ASCII "StrixDB" + NUL. See docs/storage-format.md.
MAGIC_STR :: "StrixDB\x00"
#assert(len(MAGIC_STR) == 8)

FORMAT_VERSION :: u16(1)
DEFAULT_PAGE_SIZE :: u32(4096)

// Fixed bootstrap header size (bytes 0..39). Remainder of page 0 is reserved/zero.
BOOTSTRAP_HEADER_SIZE :: 40
BOOTSTRAP_CHECKSUM_LEN :: 36 // bytes [0..36) hashed with checksum field zeroed

// Minimum / maximum allowed page sizes (power-of-two, frozen at create).
MIN_PAGE_SIZE :: u32(512)
MAX_PAGE_SIZE :: u32(65536)

Page_No :: u32 // 0 = bootstrap page

Bootstrap :: struct {
	format_version:   u16,
	page_size:        u32,
	page_count:       u32,
	freelist_head:    Page_No, // 0 = empty freelist; trunk pages linked by paging
	commit_counter:   u32,     // monotonic commit generation (engine txn_commit)
	schema_cookie:    u32,     // catalog change counter (bumped in-txn; persisted on commit)
	table_prime_root: Page_No, // 0 = unset; root of table_prime B+tree
	checksum:         u32,     // CRC-32 of header bytes [0..36) with this field zeroed
}

Open_Options :: struct {
	page_size: u32, // 0 → DEFAULT_PAGE_SIZE; only used by create / memory open
}

Db_File :: struct {
	vfs:        Vfs,
	path:       string, // empty for memory-backed files
	page_size:  u32,
	page_count: u32,
	closed:     bool,
}
