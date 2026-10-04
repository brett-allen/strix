package engine

import dbfile "../dbfile"
import paging "../paging"

Engine_Error :: enum {
	None = 0,
	Closed,
	Io,
	No_Txn,
	In_Txn,
	Invalid_Argument,
	Page_Out_Of_Range,
	Pinned,
	Already_Free,
	Exists,
	Not_Found,
	Has_Indexes,
	Catalog_Missing,
	Too_Large,
	Corrupt,
	Flush_Failed,
	Unbound_Root,
	Paging,
	Db,
}

ok :: proc(err: Engine_Error) -> bool {
	return err == .None
}

has_error :: proc(err: Engine_Error) -> bool {
	return err != .None
}

error_string :: proc(err: Engine_Error) -> string {
	switch err {
	case .None:              return ""
	case .Closed:            return "engine is closed"
	case .Io:                return "I/O error"
	case .No_Txn:            return "no active transaction"
	case .In_Txn:            return "transaction already active"
	case .Invalid_Argument:  return "invalid argument"
	case .Page_Out_Of_Range: return "page number out of range"
	case .Pinned:            return "page is pinned"
	case .Already_Free:      return "page is already on the freelist"
	case .Exists:            return "key already exists"
	case .Not_Found:         return "key not found"
	case .Has_Indexes:       return "table still has indexes"
	case .Catalog_Missing:   return "table_prime catalog is not initialized"
	case .Too_Large:         return "key or payload too large for page"
	case .Corrupt:           return "corrupt btree page"
	case .Flush_Failed:      return "partial flush failed; recovery flush required — retry COMMIT (close refused)"
	case .Unbound_Root:      return "btree root split without root ownership bind"
	case .Paging:            return "paging error"
	case .Db:                return "database error"
	}
	return "unknown engine error"
}

from_page_error :: proc(err: paging.Page_Error) -> Engine_Error {
	if err == .None {
		return .None
	}
	#partial switch err {
	case .Closed:
		return .Closed
	case .Io:
		return .Io
	case .Invalid_Argument:
		return .Invalid_Argument
	case .Page_Out_Of_Range:
		return .Page_Out_Of_Range
	case .Pinned:
		return .Pinned
	case .Already_Free:
		return .Already_Free
	case .Flush_Failed:
		return .Flush_Failed
	case .Db:
		return .Db
	}
	return .Paging
}
