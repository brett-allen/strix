package paging

import dbfile "../dbfile"

Page_Error :: enum {
	None = 0,
	Io,
	Closed,
	Invalid_Argument,
	Page_Out_Of_Range,
	Cache_Full,
	Pinned,
	Not_Pinned,
	Already_Free,
	Flush_Failed,
	Db,
}

ok :: proc(err: Page_Error) -> bool {
	return err == .None
}

has_error :: proc(err: Page_Error) -> bool {
	return err != .None
}

error_string :: proc(err: Page_Error) -> string {
	switch err {
	case .None:              return ""
	case .Io:                return "I/O error"
	case .Closed:            return "pager is closed"
	case .Invalid_Argument:  return "invalid argument"
	case .Page_Out_Of_Range: return "page number out of range"
	case .Cache_Full:        return "page cache full (cannot evict)"
	case .Pinned:            return "page is pinned"
	case .Not_Pinned:        return "page is not pinned"
	case .Already_Free:      return "page is already on the freelist"
	case .Flush_Failed:      return "partial flush failed; discard refused until flush succeeds"
	case .Db:                return "database file error"
	}
	return "unknown paging error"
}

from_db_error :: proc(err: dbfile.Db_Error) -> Page_Error {
	if err == .None {
		return .None
	}
	#partial switch err {
	case .Closed:
		return .Closed
	case .Invalid_Argument:
		return .Invalid_Argument
	case .Page_Out_Of_Range:
		return .Page_Out_Of_Range
	case .Io, .Short_Read, .Short_Write:
		return .Io
	}
	return .Db
}
