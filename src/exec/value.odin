package exec

import "core:strconv"
import "core:strings"
import sql "../sql"

// Runtime scalar values for row codec / DML bind (execute v1 + F3).
Value_Kind :: enum u8 {
	Null    = 0,
	Integer = 1,
	Float   = 2,
	Text    = 3,
	Blob    = 4,
	Boolean = 5,
	Uuid    = 6, // 16-byte typed UUID (not Text)
}

UUID_BYTE_LEN :: 16

Value :: struct {
	kind:  Value_Kind,
	i:     i64, // Integer; Boolean uses 0/1
	f:     f64,
	bytes: []u8, // owned for Text/Blob/Uuid when decoded or cloned
}

free_value :: proc(v: Value, allocator := context.allocator) {
	if (v.kind == .Text || v.kind == .Blob || v.kind == .Uuid) && v.bytes != nil {
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

value_boolean :: proc(b: bool) -> Value {
	return Value{kind = .Boolean, i = i64(1 if b else 0)}
}

value_text :: proc(s: string, allocator := context.allocator) -> Value {
	return Value{kind = .Text, bytes = transmute([]u8)strings.clone(s, allocator)}
}

value_blob :: proc(b: []u8, allocator := context.allocator) -> Value {
	out := make([]u8, len(b), allocator)
	copy(out, b)
	return Value{kind = .Blob, bytes = out}
}

value_uuid :: proc(raw: []u8, allocator := context.allocator) -> (Value, bool) {
	if len(raw) != UUID_BYTE_LEN {
		return {}, false
	}
	out := make([]u8, UUID_BYTE_LEN, allocator)
	copy(out, raw)
	return Value{kind = .Uuid, bytes = out}, true
}

clone_value :: proc(v: Value, allocator := context.allocator) -> Value {
	switch v.kind {
	case .Null:
		return value_null()
	case .Integer:
		return value_integer(v.i)
	case .Float:
		return value_float(v.f)
	case .Boolean:
		return value_boolean(v.i != 0)
	case .Text:
		return value_text(string(v.bytes), allocator)
	case .Blob:
		return value_blob(v.bytes, allocator)
	case .Uuid:
		u, ok := value_uuid(v.bytes, allocator)
		if !ok {
			return value_null()
		}
		return u
	}
	return value_null()
}

// eval_literal_expr evaluates a literal, Placeholder (F4), or unary +/- numeric literal to a Value.
// Other expression shapes yield a clear error. Placeholders read the active session bind table.
eval_literal_expr :: proc(expr: ^sql.Expr, allocator := context.allocator) -> (Value, Exec_Error) {
	if expr == nil {
		return {}, error_at(.Unsupported_Ast, "missing expression")
	}
	switch expr.kind {
	case .Literal:
		return value_from_literal(expr.data.(sql.Literal_Data), expr.span, allocator)
	case .Placeholder:
		ph := expr.data.(sql.Placeholder_Data)
		return lookup_active_bind(ph.index, expr.span, allocator)
	case .Unary:
		u := expr.data.(sql.Unary_Data)
		if u.expr == nil || (u.expr.kind != .Literal && u.expr.kind != .Placeholder) {
			return {}, make_error(.Unsupported_Ast, "only literal values are supported in INSERT", span = expr.span)
		}
		inner: Value
		err: Exec_Error
		if u.expr.kind == .Placeholder {
			ph := u.expr.data.(sql.Placeholder_Data)
			inner, err = lookup_active_bind(ph.index, u.expr.span, allocator)
		} else {
			inner, err = value_from_literal(u.expr.data.(sql.Literal_Data), u.expr.span, allocator)
		}
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
			case .Null, .Text, .Blob, .Boolean, .Uuid:
				free_value(inner, allocator)
				return {}, make_error(.Unsupported_Ast, "unary minus requires a numeric literal", span = expr.span)
			}
		case .Not:
			free_value(inner, allocator)
			return {}, make_error(.Unsupported_Ast, "NOT is not supported in INSERT VALUES", span = expr.span)
		}
		free_value(inner, allocator)
		return {}, make_error(.Unsupported_Ast, "unsupported unary operator in INSERT", span = expr.span)
	case .Column_Ref, .Star, .Binary, .Call, .Is_Null, .In_List, .Between, .Cast:
		return {}, make_error(
			.Unsupported_Ast,
			"only literal / NULL / parameter values are supported in INSERT VALUES",
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
	case .Boolean:
		if ascii_equal_fold_lit(lit.text, "TRUE") {
			return value_boolean(true), ok_error()
		}
		if ascii_equal_fold_lit(lit.text, "FALSE") {
			return value_boolean(false), ok_error()
		}
		return {}, make_error(.Invalid_Schema, "invalid boolean literal %q", lit.text, span = span)
	}
	return {}, make_error(.Unsupported_Ast, "unsupported literal kind", span = span)
}

ascii_equal_fold_lit :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		ca := a[i]
		cb := b[i]
		if ca >= 'A' && ca <= 'Z' {
			ca += 'a' - 'A'
		}
		if cb >= 'A' && cb <= 'Z' {
			cb += 'a' - 'A'
		}
		if ca != cb {
			return false
		}
	}
	return true
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

// parse_uuid_text accepts canonical 8-4-4-4-12 hex (any case) or 32 hex digits.
// On success writes exactly 16 bytes into out (caller provides [16]u8).
parse_uuid_text :: proc(s: string, out: []u8) -> bool {
	if len(out) != UUID_BYTE_LEN {
		return false
	}
	t := strings.trim_space(s)
	hex: [32]u8
	n := 0
	if len(t) == 36 {
		// 8-4-4-4-12 with hyphens
		positions := [?]int{8, 13, 18, 23}
		for p in positions {
			if t[p] != '-' {
				return false
			}
		}
		for i in 0 ..< len(t) {
			if t[i] == '-' {
				continue
			}
			if n >= 32 {
				return false
			}
			nib, ok := hex_nibble(t[i])
			if !ok {
				return false
			}
			hex[n] = nib
			n += 1
		}
	} else if len(t) == 32 {
		for i in 0 ..< 32 {
			nib, ok := hex_nibble(t[i])
			if !ok {
				return false
			}
			hex[i] = nib
		}
		n = 32
	} else {
		return false
	}
	if n != 32 {
		return false
	}
	for i in 0 ..< UUID_BYTE_LEN {
		out[i] = hex[i * 2] << 4 | hex[i * 2 + 1]
	}
	return true
}

// format_uuid_canonical renders 16 bytes as lowercase 8-4-4-4-12 (caller owns string).
format_uuid_canonical :: proc(raw: []u8, allocator := context.allocator) -> string {
	if len(raw) != UUID_BYTE_LEN {
		return strings.clone("?", allocator)
	}
	hex := "0123456789abcdef"
	out := make([]u8, 36, allocator)
	// Byte groups: 4, 2, 2, 2, 6 → positions with hyphens after 8, 12, 16, 20 hex digits.
	o := 0
	for bi in 0 ..< UUID_BYTE_LEN {
		if bi == 4 || bi == 6 || bi == 8 || bi == 10 {
			out[o] = '-'
			o += 1
		}
		out[o] = hex[raw[bi] >> 4]
		out[o + 1] = hex[raw[bi] & 0xf]
		o += 2
	}
	return string(out)
}

value_uuid_from_text :: proc(s: string, allocator := context.allocator) -> (Value, bool) {
	raw: [UUID_BYTE_LEN]u8
	if !parse_uuid_text(s, raw[:]) {
		return {}, false
	}
	return value_uuid(raw[:], allocator)
}
