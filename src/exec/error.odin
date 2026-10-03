package exec

import "core:fmt"
import "core:strings"
import engine "../engine"
import sql "../sql"

Exec_Error_Code :: enum {
	None = 0,
	Parse,
	Unsupported_Ast,
	Unknown_Table,
	Table_Exists,
	Has_Indexes,
	Invalid_Schema,
	Engine,
	Io,
	Closed,
}

Exec_Error :: struct {
	code:    Exec_Error_Code,
	message: string, // owned
	span:    sql.Span,
}

ok_error :: proc() -> Exec_Error {
	return Exec_Error{code = .None}
}

has_error :: proc(err: Exec_Error) -> bool {
	return err.code != .None || err.message != ""
}

free_error :: proc(err: Exec_Error, allocator := context.allocator) {
	if err.message != "" {
		delete(err.message, allocator)
	}
}

make_error :: proc(
	code: Exec_Error_Code,
	format: string,
	args: ..any,
	span: sql.Span = {},
	allocator := context.allocator,
) -> Exec_Error {
	return Exec_Error{
		code    = code,
		message = fmt.aprintf(format, ..args, allocator = allocator),
		span    = span,
	}
}

error_at :: proc(
	code: Exec_Error_Code,
	message: string,
	span: sql.Span = {},
	allocator := context.allocator,
) -> Exec_Error {
	return Exec_Error{
		code    = code,
		message = strings.clone(message, allocator),
		span    = span,
	}
}

from_parse_error :: proc(perr: sql.Parse_Error, allocator := context.allocator) -> Exec_Error {
	if !sql.has_error(perr) {
		return ok_error()
	}
	msg := perr.message
	if msg == "" {
		msg = "parse error"
	}
	return Exec_Error{
		code    = .Parse,
		message = strings.clone(msg, allocator),
		span    = perr.span,
	}
}

from_engine_error :: proc(err: engine.Engine_Error, span: sql.Span = {}, allocator := context.allocator) -> Exec_Error {
	if err == .None {
		return ok_error()
	}
	code := Exec_Error_Code.Engine
	#partial switch err {
	case .Exists:
		code = .Table_Exists
	case .Not_Found:
		code = .Unknown_Table
	case .Has_Indexes:
		code = .Has_Indexes
	case .Closed:
		code = .Closed
	case .Io:
		code = .Io
	case .Invalid_Argument:
		code = .Invalid_Schema
	}
	return Exec_Error{
		code    = code,
		message = strings.clone(engine.error_string(err), allocator),
		span    = span,
	}
}

format_error :: proc(err: Exec_Error, allocator := context.allocator) -> string {
	if !has_error(err) {
		return ""
	}
	if err.span.line != 0 {
		return fmt.aprintf(
			"%d:%d: %s",
			err.span.line,
			err.span.column,
			err.message,
			allocator = allocator,
		)
	}
	return strings.clone(err.message, allocator)
}
