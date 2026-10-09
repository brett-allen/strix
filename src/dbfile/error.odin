package dbfile

Db_Error :: enum {
	None = 0,
	Io,
	Bad_Magic,
	Bad_Version,
	Bad_Checksum,
	Bad_Page_Size,
	Page_Out_Of_Range,
	Short_Read,
	Short_Write,
	Invalid_Argument,
	Closed,
	Exist,
	Not_Exist,
	Torn_Flush, // page-0 flush-in-progress fence set; refuse open
}

ok :: proc(err: Db_Error) -> bool {
	return err == .None
}

has_error :: proc(err: Db_Error) -> bool {
	return err != .None
}

error_string :: proc(err: Db_Error) -> string {
	switch err {
	case .None:             return ""
	case .Io:               return "I/O error"
	case .Bad_Magic:        return "bad database magic"
	case .Bad_Version:      return "unsupported format version"
	case .Bad_Checksum:     return "bootstrap checksum mismatch"
	case .Bad_Page_Size:    return "invalid page size"
	case .Page_Out_Of_Range: return "page number out of range"
	case .Short_Read:       return "short read"
	case .Short_Write:      return "short write"
	case .Invalid_Argument: return "invalid argument"
	case .Closed:           return "database file is closed"
	case .Exist:            return "file already exists"
	case .Not_Exist:        return "file does not exist"
	case .Torn_Flush:       return "incomplete flush (torn commit); database refused"
	}
	return "unknown dbfile error"
}
