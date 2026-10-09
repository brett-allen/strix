package dbfile

import "core:encoding/endian"
import "core:hash"

// encode_bootstrap writes the 40-byte bootstrap header into `dst` (must be at
// least BOOTSTRAP_HEADER_SIZE). Computes and stores CRC-32 checksum.
// Returns the checksum that was written.
encode_bootstrap :: proc(b: Bootstrap, dst: []u8) -> (checksum: u32, err: Db_Error) {
	if len(dst) < BOOTSTRAP_HEADER_SIZE {
		return 0, .Invalid_Argument
	}
	for i in 0 ..< BOOTSTRAP_HEADER_SIZE {
		dst[i] = 0
	}

	copy(dst[0:8], MAGIC_STR)
	if !endian.put_u16(dst[8:10], .Little, b.format_version) {
		return 0, .Invalid_Argument
	}
	// reserved0 at bytes 10..12 — must remain zero (cleared by the loop above).
	if !endian.put_u32(dst[12:16], .Little, b.page_size) {
		return 0, .Invalid_Argument
	}
	if !endian.put_u32(dst[16:20], .Little, b.page_count) {
		return 0, .Invalid_Argument
	}
	if !endian.put_u32(dst[20:24], .Little, u32(b.freelist_head)) {
		return 0, .Invalid_Argument
	}
	if !endian.put_u32(dst[24:28], .Little, b.commit_counter) {
		return 0, .Invalid_Argument
	}
	if !endian.put_u32(dst[28:32], .Little, b.schema_cookie) {
		return 0, .Invalid_Argument
	}
	if !endian.put_u32(dst[32:36], .Little, u32(b.table_prime_root)) {
		return 0, .Invalid_Argument
	}

	checksum = hash.crc32(dst[0:BOOTSTRAP_CHECKSUM_LEN])
	if !endian.put_u32(dst[36:40], .Little, checksum) {
		return 0, .Invalid_Argument
	}
	return checksum, .None
}

// decode_bootstrap parses the bootstrap header from `src`.
// When `verify_checksum` is true, rejects a mismatched CRC-32.
decode_bootstrap :: proc(src: []u8, verify_checksum := true) -> (b: Bootstrap, err: Db_Error) {
	if len(src) < BOOTSTRAP_HEADER_SIZE {
		return {}, .Invalid_Argument
	}

	if string(src[0:8]) != MAGIC_STR {
		return {}, .Bad_Magic
	}

	ok: bool
	b.format_version, ok = endian.get_u16(src[8:10], .Little)
	if !ok {
		return {}, .Invalid_Argument
	}
	if b.format_version != FORMAT_VERSION {
		return {}, .Bad_Version
	}

	// reserved0 at bytes 10..12 must be zero (v0.1).
	reserved0, rok := endian.get_u16(src[10:12], .Little)
	if !rok {
		return {}, .Invalid_Argument
	}
	if reserved0 != 0 {
		return {}, .Invalid_Argument
	}

	b.page_size, ok = endian.get_u32(src[12:16], .Little)
	if !ok {
		return {}, .Invalid_Argument
	}
	if !valid_page_size(b.page_size) {
		return {}, .Bad_Page_Size
	}

	b.page_count, ok = endian.get_u32(src[16:20], .Little)
	if !ok {
		return {}, .Invalid_Argument
	}
	if b.page_count < 1 {
		return {}, .Bad_Page_Size
	}

	head: u32
	head, ok = endian.get_u32(src[20:24], .Little)
	if !ok {
		return {}, .Invalid_Argument
	}
	b.freelist_head = Page_No(head)
	if b.freelist_head != 0 && u32(b.freelist_head) >= b.page_count {
		return {}, .Invalid_Argument
	}

	b.commit_counter, ok = endian.get_u32(src[24:28], .Little)
	if !ok {
		return {}, .Invalid_Argument
	}
	b.schema_cookie, ok = endian.get_u32(src[28:32], .Little)
	if !ok {
		return {}, .Invalid_Argument
	}

	root: u32
	root, ok = endian.get_u32(src[32:36], .Little)
	if !ok {
		return {}, .Invalid_Argument
	}
	b.table_prime_root = Page_No(root)
	if b.table_prime_root != 0 && u32(b.table_prime_root) >= b.page_count {
		return {}, .Invalid_Argument
	}

	b.checksum, ok = endian.get_u32(src[36:40], .Little)
	if !ok {
		return {}, .Invalid_Argument
	}

	if verify_checksum {
		// Recompute over a copy with checksum bytes zeroed.
		hdr: [BOOTSTRAP_CHECKSUM_LEN]u8
		copy(hdr[:], src[0:BOOTSTRAP_CHECKSUM_LEN])
		want := hash.crc32(hdr[:])
		if want != b.checksum {
			return {}, .Bad_Checksum
		}
	}
	return b, .None
}

valid_page_size :: proc(page_size: u32) -> bool {
	if page_size < MIN_PAGE_SIZE || page_size > MAX_PAGE_SIZE {
		return false
	}
	// Must be a power of two.
	return page_size & (page_size - 1) == 0
}

resolve_page_size :: proc(opts: Open_Options) -> (u32, Db_Error) {
	ps := opts.page_size
	if ps == 0 {
		ps = DEFAULT_PAGE_SIZE
	}
	if !valid_page_size(ps) {
		return 0, .Bad_Page_Size
	}
	return ps, .None
}

default_bootstrap :: proc(page_size: u32) -> Bootstrap {
	return Bootstrap{
		format_version   = FORMAT_VERSION,
		page_size        = page_size,
		page_count       = 1,
		freelist_head    = 0,
		commit_counter   = 0,
		schema_cookie    = 0,
		table_prime_root = 0,
		checksum         = 0,
	}
}

flush_in_progress_set :: proc(marker_le: []u8) -> bool {
	if len(marker_le) < 4 {
		return false
	}
	v, ok := endian.get_u32(marker_le[0:4], .Little)
	return ok && v == FLUSH_IN_PROGRESS_MAGIC
}

// mark_flush_in_progress sets the durable flush fence in page-0 reserved bytes
// and syncs. Call before in-place dirty data page overwrites.
mark_flush_in_progress :: proc(f: ^Db_File) -> Db_Error {
	if err := require_open(f); err != .None {
		return err
	}
	if f.page_size < FLUSH_IN_PROGRESS_OFFSET + 4 {
		return .Invalid_Argument
	}
	buf := make([]u8, f.page_size)
	defer delete(buf)
	if err := read_page(f, 0, buf); err != .None {
		return err
	}
	if _, derr := decode_bootstrap(buf, true); derr != .None {
		return derr
	}
	if !endian.put_u32(buf[FLUSH_IN_PROGRESS_OFFSET:FLUSH_IN_PROGRESS_OFFSET + 4], .Little, FLUSH_IN_PROGRESS_MAGIC) {
		return .Invalid_Argument
	}
	if err := f.vfs.write_at(&f.vfs, 0, buf); err != .None {
		return err
	}
	return sync(f)
}
