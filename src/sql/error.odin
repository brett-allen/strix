package sql

import "core:fmt"
import "core:strings"

// Stable error classification for tooling / tests. Messages remain human-readable.
Parse_Error_Code :: enum {
	None = 0,
	Unexpected_Token,
	Unexpected_EOF,
	Trailing_Token,
	Unterminated_String,
	Unterminated_Comment,
	Unterminated_Ident,
	Invalid_Blob,
	Invalid_Number,
	Invalid_Type_Name,
	Empty_List,
	Unsupported_Syntax,
	Expected_Statement,
}

Parse_Error :: struct {
	code:    Parse_Error_Code,
	message: string,
	span:    Span,
}

ok_error :: proc() -> Parse_Error {
	return Parse_Error{code = .None}
}

has_error :: proc(err: Parse_Error) -> bool {
	return err.message != "" || err.code != .None
}

// Frees an allocated Parse_Error.message. Safe no-op when there is no error.
free_error :: proc(err: Parse_Error, allocator := context.allocator) {
	if err.message != "" {
		delete(err.message, allocator)
	}
}

make_error :: proc(
	span: Span,
	format: string,
	args: ..any,
	code: Parse_Error_Code = .Unexpected_Token,
	allocator := context.allocator,
) -> Parse_Error {
	return Parse_Error{
		code    = code,
		message = fmt.aprintf(format, ..args, allocator = allocator),
		span    = span,
	}
}

format_error :: proc(err: Parse_Error, allocator := context.allocator) -> string {
	if !has_error(err) {
		return ""
	}
	return fmt.aprintf(
		"%d:%d: %s",
		err.span.line,
		err.span.column,
		err.message,
		allocator = allocator,
	)
}

// Convenience for building messages without fmt when span is known.
error_at :: proc(
	span: Span,
	message: string,
	code: Parse_Error_Code = .Unexpected_Token,
	allocator := context.allocator,
) -> Parse_Error {
	return Parse_Error{
		code    = code,
		message = strings.clone(message, allocator),
		span    = span,
	}
}
