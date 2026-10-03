package engine

import "core:slice"
import dbfile "../dbfile"
import paging "../paging"

// page_alloc allocates a data page; requires an active transaction.
page_alloc :: proc(e: ^Engine) -> (page_no: dbfile.Page_No, err: Engine_Error) {
	if err = require_txn(e); err != .None {
		return 0, err
	}
	pn, perr := paging.alloc_page(&e.pager)
	return pn, from_page_error(perr)
}

// page_free returns a page to the freelist; requires an active transaction.
page_free :: proc(e: ^Engine, page_no: dbfile.Page_No) -> Engine_Error {
	if err := require_txn(e); err != .None {
		return err
	}
	return from_page_error(paging.free_page(&e.pager, page_no))
}

// page_write copies src (must be page_size bytes) into a data page; requires txn.
page_write :: proc(e: ^Engine, page_no: dbfile.Page_No, src: []u8) -> Engine_Error {
	if err := require_txn(e); err != .None {
		return err
	}
	if u32(len(src)) != e.pager.page_size {
		return .Invalid_Argument
	}
	data, perr := paging.get_readwrite(&e.pager, page_no)
	if perr != .None {
		return from_page_error(perr)
	}
	defer paging.unpin(&e.pager, page_no)
	copy(data, src)
	return .None
}

// page_read copies a data page into dst (must be page_size). Allowed inside or
// outside a txn (sees dirty state if a txn has mutated the page).
page_read :: proc(e: ^Engine, page_no: dbfile.Page_No, dst: []u8) -> Engine_Error {
	if err := require_open(e); err != .None {
		return err
	}
	if u32(len(dst)) != e.pager.page_size {
		return .Invalid_Argument
	}
	data, perr := paging.get_readonly(&e.pager, page_no)
	if perr != .None {
		return from_page_error(perr)
	}
	defer paging.unpin(&e.pager, page_no)
	copy(dst, data)
	return .None
}

// page_zero_write zeros a page then writes the leading prefix from src.
// Convenience for tests that do not want to allocate a full page buffer.
page_write_prefix :: proc(e: ^Engine, page_no: dbfile.Page_No, src: []u8) -> Engine_Error {
	if err := require_txn(e); err != .None {
		return err
	}
	if len(src) > int(e.pager.page_size) {
		return .Invalid_Argument
	}
	data, perr := paging.get_readwrite(&e.pager, page_no)
	if perr != .None {
		return from_page_error(perr)
	}
	defer paging.unpin(&e.pager, page_no)
	slice.zero(data)
	copy(data, src)
	return .None
}
