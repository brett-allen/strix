package exec

import "core:strconv"
import "core:strings"
import sql "../sql"

// Runtime scalar values for row codec / DML bind (execute v1).
Value_Kind :: enum u8 {
	Null    = 0,
	Integer = 1,
	Float   = 2,
	Text    = 3,
	Blob    = 4,
}

Value :: struct {
	kind:  Value_Kind,
	i:     i64,
	f:     f64,
	bytes: []u8, // owned for Text/Blob when decoded or cloned
}

free_value :: proc(v: Value, allocator := context.allocator) {
	if (v.kind == .Text || v.kind == .Blob) && v.bytes != nil {
		delete(v.bytes, allocator)
	}
}

free_values :: proc(vals: []Value, allocator := context.allocator) {
	for v in vals {
		free_value(v, allocator)
	}
	if vals != nil {
		delete(vals, allocator)
	}
}

value_null :: proc() -> Value {
	return Value{kind = .Null}
}

value_integer :: proc(i: i64) -> Value {
	return Value{kind = .Integer, i = i}
}

value_float :: proc(f: f64) -> Value {
	return Value{kind = .Float, f = f}
}

value_text :: proc(s: string, allocator := context.allocator) -> Value {
	return Value{kind = .Text, bytes = transmute([]u8)strings.clone(s, allocator)}
}

value_blob :: proc(b: []u8, allocator := context.allocator) -> Value {
	out := make([]u8, len(b), allocator)
	copy(out, b)
	return Value{kind = .Blob, bytes = out}
}

clone_value :: proc(v: Value, allocator := context.allocator) -> Value {
	switch v.kind {
	case .Null:
		return value_null()
	case .Integer:
		return value_integer(v.i)
	case .Float:
		return value_float(v.f)
	case .Text:
		return value_text(string(v.bytes), allocator)
	case .Blob:
		return value_blob(v.bytes, allocator)
	}
	return value_null()
}

// eval_literal_expr evaluates a literal (or unary +/- numeric literal) to a Value.
// Non-literal / non-NULL defaults and expressions yield a clear error.
eval_literal_expr :: proc(expr: ^sql.Expr, allocator := context.allocator) -> (Value, Exec_Error) {
	if expr == nil {
		return {}, error_at(.Unsupported_Ast, "missing expression")
	}
	switch expr.kind {
	case .Literal:
		return value_from_literal(expr.data.(sql.Literal_Data), expr.span, allocator)
	case .Unary:
		u := expr.data.(sql.Unary_Data)
		if u.expr == nil || u.expr.kind != .Literal {
			return {}, make_error(.Unsupported_Ast, "only literal values are supported in INSERT", span = expr.span)
		}
		inner, err := value_from_literal(u.expr.data.(sql.Literal_Data), u.expr.span, allocator)
		if has_error(err) {
			return {}, err
		}
		#partial switch u.op {
		case .Plus:
			return inner, ok_error()
		case .Minus:
			switch inner.kind {
			case .Integer:
				return value_integer(-inner.i), ok_error()
			case .Float:
				return value_float(-inner.f), ok_error()
			case .Null, .Text, .Blob:
				free_value(inner, allocator)
				return {}, make_error(.Unsupported_Ast, "unary minus requires a numeric literal", span = expr.span)
			}
		case .Not:
			free_value(inner, allocator)
			return {}, make_error(.Unsupported_Ast, "NOT is not supported in INSERT VALUES", span = expr.span)
		}
		free_value(inner, allocator)
		return {}, make_error(.Unsupported_Ast, "unsupported unary operator in INSERT", span = expr.span)
	case .Column_Ref, .Placeholder, .Star, .Binary, .Call, .Is_Null, .In_List, .Between, .Cast:
		return {}, make_error(
			.Unsupported_Ast,
			"only literal / NULL values are supported in INSERT VALUES",
			span = expr.span,
		)
	}
	return {}, make_error(.Unsupported_Ast, "unsupported expression in INSERT", span = expr.span)
}

value_from_literal :: proc(
	lit: sql.Literal_Data,
	span: sql.Span,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	switch lit.lit_kind {
	case .Null:
		return value_null(), ok_error()
	case .Integer:
		n, ok := strconv.parse_i64(lit.text)
		if !ok {
			return {}, make_error(.Invalid_Schema, "invalid integer literal %q", lit.text, span = span)
		}
		return value_integer(n), ok_error()
	case .Float:
		f, ok := strconv.parse_f64(lit.text)
		if !ok {
			return {}, make_error(.Invalid_Schema, "invalid float literal %q", lit.text, span = span)
		}
		return value_float(f), ok_error()
	case .String:
		s, ok := unquote_sql_string(lit.text, allocator)
		if !ok {
			return {}, make_error(.Invalid_Schema, "invalid string literal", span = span)
		}
		return Value{kind = .Text, bytes = transmute([]u8)s}, ok_error()
	case .Blob:
		b, ok := decode_sql_blob(lit.text, allocator)
		if !ok {
			return {}, make_error(.Invalid_Schema, "invalid blob literal", span = span)
		}
		return Value{kind = .Blob, bytes = b}, ok_error()
	}
	return {}, make_error(.Unsupported_Ast, "unsupported literal kind", span = span)
}

// unquote_sql_string strips surrounding quotes and unescapes '' → '.
unquote_sql_string :: proc(text: string, allocator := context.allocator) -> (string, bool) {
	if len(text) < 2 || text[0] != '\'' || text[len(text) - 1] != '\'' {
		return "", false
	}
	inner := text[1:len(text) - 1]
	b: strings.Builder
	strings.builder_init(&b, 0, len(inner), allocator)
	i := 0
	for i < len(inner) {
		if inner[i] == '\'' {
			if i + 1 < len(inner) && inner[i + 1] == '\'' {
				strings.write_byte(&b, '\'')
				i += 2
				continue
			}
			strings.builder_destroy(&b)
			return "", false
		}
		strings.write_byte(&b, inner[i])
		i += 1
	}
	return strings.to_string(b), true
}

decode_sql_blob :: proc(text: string, allocator := context.allocator) -> ([]u8, bool) {
	// Token text is X'hex' or x'hex'
	if len(text) < 3 {
		return nil, false
	}
	if !(text[0] == 'X' || text[0] == 'x') || text[1] != '\'' || text[len(text) - 1] != '\'' {
		return nil, false
	}
	hex := text[2:len(text) - 1]
	if len(hex) % 2 != 0 {
		return nil, false
	}
	out := make([]u8, len(hex) / 2, allocator)
	for i := 0; i < len(hex); i += 2 {
		hi, ok1 := hex_nibble(hex[i])
		lo, ok2 := hex_nibble(hex[i + 1])
		if !ok1 || !ok2 {
			delete(out, allocator)
			return nil, false
		}
		out[i / 2] = hi << 4 | lo
	}
	return out, true
}

hex_nibble :: proc(ch: u8) -> (u8, bool) {
	switch ch {
	case '0' ..= '9':
		return ch - '0', true
	case 'a' ..= 'f':
		return ch - 'a' + 10, true
	case 'A' ..= 'F':
		return ch - 'A' + 10, true
	}
	return 0, false
}
