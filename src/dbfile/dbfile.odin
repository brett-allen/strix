package dbfile

import "core:os"
import "core:strings"

/*
	dbfile — on-disk file format and page I/O for Strix.

	Page numbers are 0-based; page 0 is the bootstrap page.
	See docs/storage-format.md for the frozen byte layout.
*/

// open_create creates a new Strix database file at `path`.
// Fails if the path already exists. Writes page 0 and syncs.
open_create :: proc(path: string, opts: Open_Options = {}) -> (f: Db_File, err: Db_Error) {
	page_size, ps_err := resolve_page_size(opts)
	if ps_err != .None {
		return {}, ps_err
	}

	file, os_err := os.open(path, {.Read, .Write, .Create, .Excl})
	if os_err != nil && os_err != os.ERROR_NONE {
		if os_err == os.General_Error.Exist {
			return {}, .Exist
		}
		return {}, .Io
	}

	vfs, vfs_err := vfs_from_os_file(file)
	if vfs_err != .None {
		os.close(file)
		os.remove(path)
		return {}, vfs_err
	}

	f = Db_File{
		vfs        = vfs,
		path       = strings.clone(path),
		page_size  = page_size,
		page_count = 1,
		closed     = false,
	}

	boot := default_bootstrap(page_size)
	if err = write_bootstrap(&f, boot); err != .None {
		close(&f)
		os.remove(path)
		return {}, err
	}
	if err = sync(&f); err != .None {
		close(&f)
		os.remove(path)
		return {}, err
	}
	return f, .None
}

// open_existing opens an existing Strix database file and validates page 0.
open_existing :: proc(path: string, opts: Open_Options = {}) -> (f: Db_File, err: Db_Error) {
	_ = opts // reserved; page size is taken from the on-disk header

	file, os_err := os.open(path, {.Read, .Write})
	if os_err != nil && os_err != os.ERROR_NONE {
		if os_err == os.General_Error.Not_Exist {
			return {}, .Not_Exist
		}
		return {}, .Io
	}

	vfs, vfs_err := vfs_from_os_file(file)
	if vfs_err != .None {
		os.close(file)
		return {}, vfs_err
	}

	f = Db_File{
		vfs    = vfs,
		path   = strings.clone(path),
		closed = false,
	}

	if err = load_bootstrap_meta(&f); err != .None {
		close(&f)
		return {}, err
	}
	return f, .None
}

// open_memory creates an in-memory database (VFS seam for tests).
open_memory :: proc(opts: Open_Options = {}) -> (f: Db_File, err: Db_Error) {
	page_size, ps_err := resolve_page_size(opts)
	if ps_err != .None {
		return {}, ps_err
	}

	vfs, vfs_err := open_memory_vfs()
	if vfs_err != .None {
		return {}, vfs_err
	}

	f = Db_File{
		vfs        = vfs,
		path       = "",
		page_size  = page_size,
		page_count = 1,
		closed     = false,
	}

	boot := default_bootstrap(page_size)
	if err = write_bootstrap(&f, boot); err != .None {
		close(&f)
		return {}, err
	}
	return f, .None
}

close :: proc(f: ^Db_File) -> Db_Error {
	if f == nil || f.closed {
		return .None
	}
	err: Db_Error = .None
	if f.vfs.close != nil {
		err = f.vfs.close(&f.vfs)
	}
	if f.path != "" {
		delete(f.path)
		f.path = ""
	}
	f.closed = true
	f.page_size = 0
	f.page_count = 0
	return err
}

read_page :: proc(f: ^Db_File, page_no: Page_No, dst: []u8) -> Db_Error {
	if err := require_open(f); err != .None {
		return err
	}
	if u32(len(dst)) != f.page_size {
		return .Invalid_Argument
	}
	if u32(page_no) >= f.page_count {
		return .Page_Out_Of_Range
	}
	offset := i64(page_no) * i64(f.page_size)
	return f.vfs.read_at(&f.vfs, offset, dst)
}

write_page :: proc(f: ^Db_File, page_no: Page_No, src: []u8) -> Db_Error {
	if err := require_open(f); err != .None {
		return err
	}
	if u32(len(src)) != f.page_size {
		return .Invalid_Argument
	}

	// Grow the file when writing past the current page_count.
	need_count := u32(page_no) + 1
	if need_count > f.page_count {
		new_size := i64(need_count) * i64(f.page_size)
		if err := f.vfs.truncate(&f.vfs, new_size); err != .None {
			return err
		}
		f.page_count = need_count
	}

	offset := i64(page_no) * i64(f.page_size)
	return f.vfs.write_at(&f.vfs, offset, src)
}

sync :: proc(f: ^Db_File) -> Db_Error {
	if err := require_open(f); err != .None {
		return err
	}
	return f.vfs.sync(&f.vfs)
}

read_bootstrap :: proc(f: ^Db_File) -> (Bootstrap, Db_Error) {
	if err := require_open(f); err != .None {
		return {}, err
	}
	buf := make([]u8, f.page_size)
	defer delete(buf)
	if err := read_page(f, 0, buf); err != .None {
		return {}, err
	}
	return decode_bootstrap(buf, true)
}

write_bootstrap :: proc(f: ^Db_File, b: Bootstrap) -> Db_Error {
	if err := require_open(f); err != .None {
		return err
	}
	if !valid_page_size(b.page_size) {
		return .Bad_Page_Size
	}
	// Page size is frozen after the file is initialized.
	if f.page_size != 0 && b.page_size != f.page_size {
		return .Bad_Page_Size
	}
	if b.page_count < 1 {
		return .Invalid_Argument
	}
	if b.format_version != FORMAT_VERSION {
		return .Bad_Version
	}

	buf := make([]u8, b.page_size)
	defer delete(buf)

	boot := b
	_, enc_err := encode_bootstrap(boot, buf[:BOOTSTRAP_HEADER_SIZE])
	if enc_err != .None {
		return enc_err
	}

	// Ensure the store is large enough for the declared page count.
	need := max(f.page_count, b.page_count)
	need = max(need, 1)
	new_size := i64(need) * i64(b.page_size)
	if err := f.vfs.truncate(&f.vfs, new_size); err != .None {
		return err
	}

	f.page_size = b.page_size
	f.page_count = max(f.page_count, b.page_count)

	if err := f.vfs.write_at(&f.vfs, 0, buf); err != .None {
		return err
	}
	return .None
}

require_open :: proc(f: ^Db_File) -> Db_Error {
	if f == nil || f.closed || f.vfs.impl == nil {
		return .Closed
	}
	return .None
}

load_bootstrap_meta :: proc(f: ^Db_File) -> Db_Error {
	// Peek at the fixed header size first to learn page_size, then re-read a full page.
	hdr: [BOOTSTRAP_HEADER_SIZE]u8
	if err := f.vfs.read_at(&f.vfs, 0, hdr[:]); err != .None {
		return err
	}
	boot, err := decode_bootstrap(hdr[:], true)
	if err != .None {
		return err
	}

	file_size, size_err := f.vfs.size(&f.vfs)
	if size_err != .None {
		return size_err
	}
	expected := i64(boot.page_count) * i64(boot.page_size)
	if file_size < expected {
		return .Short_Read
	}

	f.page_size = boot.page_size
	f.page_count = boot.page_count
	return .None
}
