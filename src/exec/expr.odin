package exec

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import engine "../engine"
import sql "../sql"

// Join_Side describes one FROM/JOIN input in a multi-table Row_Env.
// Column indices in env.columns / env.values are [offset, offset+ncols).
Join_Side :: struct {
	table:  string, // catalog table name
	alias:  string, // optional correlation name (may be "")
	offset: int,
	ncols:  int,
}

// Row_Env binds table/alias + column names to the current decoded row values.
// Used by SELECT WHERE/projection/ORDER BY and UPDATE/DELETE SET/WHERE.
// When sides is non-empty, columns/values are the flattened join row and
// column resolution uses multi-table rules (qualified names + ambiguity).
Row_Env :: struct {
	table:   string, // catalog table name (single-table)
	alias:   string, // optional FROM alias (may be "")
	columns: []engine.Catalog_Column,
	values:  []Value,
	sides:   []Join_Side, // nil/empty → single-table mode
}

// eval_expr evaluates an AST expression against a row environment.
// Comparison / AND / OR / NOT results are Integer 1/0 or Null (three-valued).
// Caller owns the returned Value (free with free_value).
eval_expr :: proc(expr: ^sql.Expr, env: ^Row_Env, allocator := context.allocator) -> (Value, Exec_Error) {
	if expr == nil {
		return {}, error_at(.Unsupported_Ast, "missing expression")
	}
	switch expr.kind {
	case .Literal:
		return value_from_literal(expr.data.(sql.Literal_Data), expr.span, allocator)
	case .Column_Ref:
		return eval_column_ref(expr.data.(sql.Column_Ref_Data), expr.span, env, allocator)
	case .Unary:
		return eval_unary(expr.data.(sql.Unary_Data), expr.span, env, allocator)
	case .Binary:
		return eval_binary(expr.data.(sql.Binary_Data), expr.span, env, allocator)
	case .Is_Null:
		return eval_is_null(expr.data.(sql.Is_Null_Data), env, allocator)
	case .In_List:
		return eval_in_list(expr.data.(sql.In_List_Data), expr.span, env, allocator)
	case .Placeholder:
		return {}, make_error(.Unsupported_Ast, "parameter placeholders are not supported yet", span = expr.span)
	case .Star:
		return {}, make_error(.Unsupported_Ast, "bare * is not valid in this expression", span = expr.span)
	case .Call:
		return {}, make_error(.Unsupported_Ast, "function calls are not supported yet", span = expr.span)
	case .Between:
		return {}, make_error(.Unsupported_Ast, "BETWEEN is not supported yet", span = expr.span)
	case .Cast:
		return eval_cast(expr.data.(sql.Cast_Data), expr.span, env, allocator)
	}
	return {}, make_error(.Unsupported_Ast, "unsupported expression", span = expr.span)
}

// eval_cast implements CAST(expr AS type) (S2). NULL → NULL. Invalid casts error
// (never NULL-by-affinity). Target types: INTEGER/INT, REAL/FLOAT/DOUBLE,
// TEXT/VARCHAR/…/UUID, BLOB — see cast_target_kind / sql-dialect.md.
eval_cast :: proc(
	d: sql.Cast_Data,
	span: sql.Span,
	env: ^Row_Env,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	target, ok := cast_target_kind(d.type_name)
	if !ok {
		return {}, make_error(
			.Unsupported_Ast,
			"unsupported CAST target type %q",
			d.type_name,
			span = span,
		)
	}
	inner, err := eval_expr(d.expr, env, allocator)
	if has_error(err) {
		return {}, err
	}
	if value_is_null(inner) {
		return value_null(), ok_error()
	}
	defer free_value(inner, allocator)
	return cast_value(inner, target, d.type_name, span, allocator)
}

// cast_target_kind maps CAST AS type names (same families as declared_storage_kind).
cast_target_kind :: proc(type_name: string) -> (kind: Value_Kind, ok: bool) {
	k, enforced := declared_storage_kind(type_name)
	return k, enforced
}

// cast_value converts a non-NULL value to target. Caller retains ownership of `v`
// (may free after); returned Value is newly owned when Text/Blob.
cast_value :: proc(
	v: Value,
	target: Value_Kind,
	type_name: string,
	span: sql.Span,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	if v.kind == target {
		return clone_value(v, allocator), ok_error()
	}
	switch target {
	case .Integer:
		return cast_to_integer(v, type_name, span)
	case .Float:
		return cast_to_float(v, type_name, span)
	case .Text:
		return cast_to_text(v, type_name, span, allocator)
	case .Blob:
		return cast_to_blob(v, type_name, span, allocator)
	case .Null:
		return {}, make_error(.Unsupported_Ast, "invalid CAST target", span = span)
	}
	return {}, make_error(.Unsupported_Ast, "unsupported CAST target", span = span)
}

cast_to_integer :: proc(v: Value, type_name: string, span: sql.Span) -> (Value, Exec_Error) {
	switch v.kind {
	case .Integer:
		return value_integer(v.i), ok_error()
	case .Float:
		f := v.f
		if math.is_nan(f) || math.is_inf(f) {
			return {}, make_error(
				.Unsupported_Ast,
				"cannot CAST non-finite REAL to %s",
				type_name,
				span = span,
			)
		}
		if f > f64(max(i64)) || f < f64(min(i64)) {
			return {}, make_error(
				.Unsupported_Ast,
				"cannot CAST REAL %g to %s: out of INTEGER range",
				f,
				type_name,
				span = span,
			)
		}
		// Truncate toward zero (H2-ish / common SQL CAST).
		return value_integer(i64(f)), ok_error()
	case .Text:
		n, status := parse_cast_integer_text(string(v.bytes))
		switch status {
		case .Ok:
			return value_integer(n), ok_error()
		case .Out_Of_Range:
			return {}, make_error(
				.Unsupported_Ast,
				"cannot CAST %q to %s: out of INTEGER range",
				string(v.bytes),
				type_name,
				span = span,
			)
		case .Bad_Format:
			return {}, make_error(
				.Unsupported_Ast,
				"cannot CAST %q to %s: expected optional sign and decimal digits only",
				string(v.bytes),
				type_name,
				span = span,
			)
		}
		return {}, make_error(.Unsupported_Ast, "cannot CAST to %s", type_name, span = span)
	case .Blob, .Null:
		return {}, make_error(
			.Unsupported_Ast,
			"cannot CAST %v to %s",
			v.kind,
			type_name,
			span = span,
		)
	}
	return {}, make_error(.Unsupported_Ast, "cannot CAST to %s", type_name, span = span)
}

cast_to_float :: proc(v: Value, type_name: string, span: sql.Span) -> (Value, Exec_Error) {
	switch v.kind {
	case .Float:
		return value_float(v.f), ok_error()
	case .Integer:
		return value_float(f64(v.i)), ok_error()
	case .Text:
		s := strings.trim_space(string(v.bytes))
		if s == "" {
			return {}, make_error(
				.Unsupported_Ast,
				"cannot CAST %q to %s: empty text",
				string(v.bytes),
				type_name,
				span = span,
			)
		}
		f, ok := strconv.parse_f64(s)
		if !ok {
			return {}, make_error(
				.Unsupported_Ast,
				"cannot CAST %q to %s: invalid REAL text",
				string(v.bytes),
				type_name,
				span = span,
			)
		}
		return value_float(f), ok_error()
	case .Blob, .Null:
		return {}, make_error(
			.Unsupported_Ast,
			"cannot CAST %v to %s",
			v.kind,
			type_name,
			span = span,
		)
	}
	return {}, make_error(.Unsupported_Ast, "cannot CAST to %s", type_name, span = span)
}

cast_to_text :: proc(
	v: Value,
	type_name: string,
	span: sql.Span,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	switch v.kind {
	case .Text:
		return clone_value(v, allocator), ok_error()
	case .Integer:
		s := fmt.aprintf("%d", v.i, allocator = allocator)
		return Value{kind = .Text, bytes = transmute([]u8)s}, ok_error()
	case .Float:
		s := fmt.aprintf("%g", v.f, allocator = allocator)
		return Value{kind = .Text, bytes = transmute([]u8)s}, ok_error()
	case .Blob:
		// Interpret blob bytes as UTF-8 text (no hex encoding).
		return value_text(string(v.bytes), allocator), ok_error()
	case .Null:
		return {}, make_error(.Unsupported_Ast, "cannot CAST NULL (handled upstream)", span = span)
	}
	return {}, make_error(.Unsupported_Ast, "cannot CAST to %s", type_name, span = span)
}

cast_to_blob :: proc(
	v: Value,
	type_name: string,
	span: sql.Span,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	switch v.kind {
	case .Blob:
		return clone_value(v, allocator), ok_error()
	case .Text:
		return value_blob(v.bytes, allocator), ok_error()
	case .Integer, .Float, .Null:
		return {}, make_error(
			.Unsupported_Ast,
			"cannot CAST %v to %s; cast to TEXT first if needed",
			v.kind,
			type_name,
			span = span,
		)
	}
	return {}, make_error(.Unsupported_Ast, "cannot CAST to %s", type_name, span = span)
}

Cast_Int_Parse :: enum {
	Ok,
	Bad_Format,
	Out_Of_Range,
}

// parse_cast_integer_text accepts optional surrounding whitespace, optional +/-,
// then decimal digits only (no hex prefixes, underscores, or fractional part).
// Digits that do not fit in i64 → Out_Of_Range (no silent wrap).
parse_cast_integer_text :: proc(s: string) -> (i64, Cast_Int_Parse) {
	t := strings.trim_space(s)
	if t == "" {
		return 0, .Bad_Format
	}
	neg := false
	i := 0
	if t[0] == '+' || t[0] == '-' {
		if len(t) == 1 {
			return 0, .Bad_Format
		}
		neg = t[0] == '-'
		i = 1
	}
	// Accumulate magnitude in u64 so min(i64) (-2^63) is representable.
	max_mag := u64(max(i64)) // 2^63-1
	if neg {
		max_mag += 1 // 2^63
	}
	mag: u64 = 0
	saw_digit := false
	for j in i ..< len(t) {
		c := t[j]
		if c < '0' || c > '9' {
			return 0, .Bad_Format
		}
		saw_digit = true
		d := u64(c - '0')
		if mag > (max_mag - d) / 10 {
			return 0, .Out_Of_Range
		}
		mag = mag * 10 + d
	}
	if !saw_digit {
		return 0, .Bad_Format
	}
	if neg {
		if mag == u64(max(i64)) + 1 {
			return min(i64), .Ok
		}
		return -i64(mag), .Ok
	}
	return i64(mag), .Ok
}

// eval_expr_bool evaluates expr and returns whether it is TRUE (WHERE keep-row).
// NULL / FALSE → false. Text/Blob in boolean context → Unsupported_Ast. Errors propagate.
eval_expr_bool :: proc(expr: ^sql.Expr, env: ^Row_Env, allocator := context.allocator) -> (bool, Exec_Error) {
	v, err := eval_expr(expr, env, allocator)
	if has_error(err) {
		return false, err
	}
	defer free_value(v, allocator)
	if value_is_null(v) {
		return false, ok_error()
	}
	if berr := require_bool_operand(v, expr.span); has_error(berr) {
		return false, berr
	}
	return value_is_true(v), ok_error()
}

// eval_const_integer evaluates a constant integer expression (LIMIT / OFFSET).
eval_const_integer :: proc(expr: ^sql.Expr, what: string, allocator := context.allocator) -> (i64, Exec_Error) {
	if expr == nil {
		return 0, make_error(.Unsupported_Ast, "missing %s expression", what)
	}
	v, err := eval_expr(expr, nil, allocator)
	if has_error(err) {
		return 0, err
	}
	defer free_value(v, allocator)
	if v.kind != .Integer {
		return 0, make_error(.Unsupported_Ast, "%s must be an integer constant", what, span = expr.span)
	}
	if v.i < 0 {
		return 0, make_error(.Unsupported_Ast, "%s must be non-negative", what, span = expr.span)
	}
	return v.i, ok_error()
}

// Strict boolean context (S1 / sql-compliance): Integer/Float 0 = false, ≠0 = true;
// NULL is unknown (neither). Text/Blob must be rejected via require_bool_operand
// before calling these — they treat non-numeric as neither true nor false.
value_is_true :: proc(v: Value) -> bool {
	#partial switch v.kind {
	case .Integer:
		return v.i != 0
	case .Float:
		return v.f != 0
	}
	return false
}

value_is_false :: proc(v: Value) -> bool {
	#partial switch v.kind {
	case .Integer:
		return v.i == 0
	case .Float:
		return v.f == 0
	}
	return false
}

value_is_null :: proc(v: Value) -> bool {
	return v.kind == .Null
}

// require_bool_operand rejects Text/Blob (and other non-numeric non-null kinds)
// in WHERE / AND / OR / NOT. NULL is allowed (three-valued unknown).
require_bool_operand :: proc(v: Value, span: sql.Span = {}) -> Exec_Error {
	#partial switch v.kind {
	case .Null, .Integer, .Float:
		return ok_error()
	case .Text, .Blob:
		return make_error(
			.Unsupported_Ast,
			"boolean context requires a numeric value (got %v); use a comparison",
			v.kind,
			span = span,
		)
	}
	return make_error(
		.Unsupported_Ast,
		"boolean context requires a numeric value (got %v)",
		v.kind,
		span = span,
	)
}

eval_column_ref :: proc(
	ref: sql.Column_Ref_Data,
	span: sql.Span,
	env: ^Row_Env,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	if env == nil || len(env.columns) == 0 {
		return {}, make_error(.Unknown_Column, "column reference outside of a row context", span = span)
	}
	idx, rerr := resolve_column_index(
		ref,
		env.columns,
		env.table,
		env.alias,
		span,
		env.sides,
	)
	if has_error(rerr) {
		return {}, rerr
	}
	if idx < 0 || idx >= len(env.values) {
		return {}, make_error(.Engine, "row value missing resolved column", span = span)
	}
	return clone_value(env.values[idx], allocator), ok_error()
}

// resolve_column_index maps a column ref to a flat index in columns.
// Multi-table (sides non-empty): unqualified names error if ambiguous;
// qualified names must match a side table/alias.
resolve_column_index :: proc(
	ref: sql.Column_Ref_Data,
	columns: []engine.Catalog_Column,
	table_name, alias: string,
	span: sql.Span,
	sides: []Join_Side = nil,
) -> (idx: int, err: Exec_Error) {
	segs := ref.segments
	if len(segs) == 0 {
		return -1, make_error(.Unknown_Column, "empty column reference", span = span)
	}
	if len(sides) > 0 {
		if len(segs) == 1 {
			col_name := segs[0]
			found := -1
			n_hits := 0
			for side in sides {
				for i in 0 ..< side.ncols {
					cidx := side.offset + i
					if cidx < 0 || cidx >= len(columns) {
						continue
					}
					if strings.equal_fold(columns[cidx].name, col_name) {
						n_hits += 1
						found = cidx
					}
				}
			}
			if n_hits == 0 {
				return -1, make_error(.Unknown_Column, "no such column: %q", col_name, span = span)
			}
			if n_hits > 1 {
				return -1, make_error(.Unknown_Column, "ambiguous column: %q", col_name, span = span)
			}
			return found, ok_error()
		}
		if len(segs) == 2 {
			qual := segs[0]
			col_name := segs[1]
			side_i := -1
			for side, si in sides {
				if side_qualifier_matches(qual, side) {
					side_i = si
					break
				}
			}
			if side_i < 0 {
				return -1, make_error(
					.Unknown_Column,
					"no such table/alias %q in FROM",
					qual,
					span = span,
				)
			}
			side := sides[side_i]
			for i in 0 ..< side.ncols {
				cidx := side.offset + i
				if cidx >= 0 && cidx < len(columns) && strings.equal_fold(columns[cidx].name, col_name) {
					return cidx, ok_error()
				}
			}
			return -1, make_error(.Unknown_Column, "no such column: %q", col_name, span = span)
		}
		return -1, make_error(
			.Unsupported_Ast,
			"multi-part column references are not supported",
			span = span,
		)
	}

	// Single-table
	col_name: string
	if len(segs) == 1 {
		col_name = segs[0]
	} else if len(segs) == 2 {
		qual := segs[0]
		if !(strings.equal_fold(qual, table_name) || (alias != "" && strings.equal_fold(qual, alias))) {
			return -1, make_error(
				.Unknown_Column,
				"no such table/alias %q in FROM",
				qual,
				span = span,
			)
		}
		col_name = segs[1]
	} else {
		return -1, make_error(
			.Unsupported_Ast,
			"multi-part column references are not supported",
			span = span,
		)
	}
	idx = find_column_index(columns, col_name)
	if idx < 0 {
		return -1, make_error(.Unknown_Column, "no such column: %q", col_name, span = span)
	}
	return idx, ok_error()
}

side_qualifier_matches :: proc(qual: string, side: Join_Side) -> bool {
	if strings.equal_fold(qual, side.table) {
		return true
	}
	if side.alias != "" && strings.equal_fold(qual, side.alias) {
		return true
	}
	return false
}

side_exposed_name :: proc(side: Join_Side) -> string {
	if side.alias != "" {
		return side.alias
	}
	return side.table
}

qualifier_matches :: proc(qual: string, env: ^Row_Env) -> bool {
	if env == nil {
		return false
	}
	if len(env.sides) > 0 {
		for side in env.sides {
			if side_qualifier_matches(qual, side) {
				return true
			}
		}
		return false
	}
	if strings.equal_fold(qual, env.table) {
		return true
	}
	if env.alias != "" && strings.equal_fold(qual, env.alias) {
		return true
	}
	return false
}

find_column_index :: proc(columns: []engine.Catalog_Column, name: string) -> int {
	for c, i in columns {
		if strings.equal_fold(c.name, name) {
			return i
		}
	}
	return -1
}

eval_unary :: proc(
	u: sql.Unary_Data,
	span: sql.Span,
	env: ^Row_Env,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	inner, err := eval_expr(u.expr, env, allocator)
	if has_error(err) {
		return {}, err
	}
	switch u.op {
	case .Plus:
		#partial switch inner.kind {
		case .Null, .Integer, .Float:
			return inner, ok_error()
		case .Text, .Blob:
			free_value(inner, allocator)
			return {}, make_error(.Unsupported_Ast, "unary + requires a numeric value", span = span)
		}
	case .Minus:
		switch inner.kind {
		case .Null:
			return value_null(), ok_error()
		case .Integer:
			return value_integer(-inner.i), ok_error()
		case .Float:
			return value_float(-inner.f), ok_error()
		case .Text, .Blob:
			free_value(inner, allocator)
			return {}, make_error(.Unsupported_Ast, "unary - requires a numeric value", span = span)
		}
	case .Not:
		defer free_value(inner, allocator)
		if value_is_null(inner) {
			return value_null(), ok_error()
		}
		if berr := require_bool_operand(inner, span); has_error(berr) {
			return {}, berr
		}
		if value_is_true(inner) {
			return value_integer(0), ok_error()
		}
		return value_integer(1), ok_error()
	}
	free_value(inner, allocator)
	return {}, make_error(.Unsupported_Ast, "unsupported unary operator", span = span)
}

eval_binary :: proc(
	b: sql.Binary_Data,
	span: sql.Span,
	env: ^Row_Env,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	#partial switch b.op {
	case .And, .Or:
		return eval_logic(b, span, env, allocator)
	}

	left, lerr := eval_expr(b.left, env, allocator)
	if has_error(lerr) {
		return {}, lerr
	}
	defer free_value(left, allocator)
	right, rerr := eval_expr(b.right, env, allocator)
	if has_error(rerr) {
		return {}, rerr
	}
	defer free_value(right, allocator)

	#partial switch b.op {
	case .Eq, .EqEq, .NotEq, .Lt, .LtEq, .Gt, .GtEq:
		return eval_compare(b.op, left, right, span)
	case .Add, .Sub, .Mul, .Div, .Mod:
		return eval_arith(b.op, left, right, span)
	case .Concat:
		return eval_concat(left, right, span, allocator)
	}
	return {}, make_error(.Unsupported_Ast, "unsupported binary operator", span = span)
}

eval_logic :: proc(
	b: sql.Binary_Data,
	span: sql.Span,
	env: ^Row_Env,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	left, lerr := eval_expr(b.left, env, allocator)
	if has_error(lerr) {
		return {}, lerr
	}
	defer free_value(left, allocator)

	left_span := b.left.span if b.left != nil else span
	if berr := require_bool_operand(left, left_span); has_error(berr) {
		return {}, berr
	}

	if b.op == .And {
		if value_is_false(left) {
			return value_integer(0), ok_error()
		}
	} else if b.op == .Or {
		if value_is_true(left) {
			return value_integer(1), ok_error()
		}
	}

	right, rerr := eval_expr(b.right, env, allocator)
	if has_error(rerr) {
		return {}, rerr
	}
	defer free_value(right, allocator)

	right_span := b.right.span if b.right != nil else span
	if berr := require_bool_operand(right, right_span); has_error(berr) {
		return {}, berr
	}

	if b.op == .And {
		if value_is_false(right) {
			return value_integer(0), ok_error()
		}
		if value_is_null(left) || value_is_null(right) {
			return value_null(), ok_error()
		}
		return value_integer(1), ok_error()
	}
	// OR
	if value_is_true(right) {
		return value_integer(1), ok_error()
	}
	if value_is_null(left) || value_is_null(right) {
		return value_null(), ok_error()
	}
	return value_integer(0), ok_error()
}

eval_compare :: proc(op: sql.Binary_Op, left, right: Value, span: sql.Span) -> (Value, Exec_Error) {
	if value_is_null(left) || value_is_null(right) {
		return value_null(), ok_error()
	}
	cmp, err := compare_values(left, right, span)
	if has_error(err) {
		return {}, err
	}
	ok := false
	#partial switch op {
	case .Eq, .EqEq:
		ok = cmp == 0
	case .NotEq:
		ok = cmp != 0
	case .Lt:
		ok = cmp < 0
	case .LtEq:
		ok = cmp <= 0
	case .Gt:
		ok = cmp > 0
	case .GtEq:
		ok = cmp >= 0
	case:
		return {}, make_error(.Unsupported_Ast, "unsupported comparison", span = span)
	}
	return value_integer(i64(1 if ok else 0)), ok_error()
}

// compare_values returns -1 / 0 / 1. NULL handling is caller's responsibility.
// Policy (S1 / sql-compliance north star):
//   - Integer–Integer: exact i64
//   - Mixed int/float: allow via f64
//   - Same-kind Text/Blob: byte/lex compare
//   - Text/Blob ↔ numeric (or other kind mismatch): Unsupported_Ast (use CAST)
compare_values :: proc(left, right: Value, span: sql.Span = {}) -> (int, Exec_Error) {
	if left.kind == .Null && right.kind == .Null {
		return 0, ok_error()
	}
	if left.kind == .Null {
		return -1, ok_error()
	}
	if right.kind == .Null {
		return 1, ok_error()
	}
	// Exact i64 path — avoids mantissa rounding around 2^53.
	if left.kind == .Integer && right.kind == .Integer {
		if left.i < right.i do return -1, ok_error()
		if left.i > right.i do return 1, ok_error()
		return 0, ok_error()
	}
	if is_numeric_kind(left.kind) && is_numeric_kind(right.kind) {
		lf := value_as_f64(left)
		rf := value_as_f64(right)
		if lf < rf do return -1, ok_error()
		if lf > rf do return 1, ok_error()
		return 0, ok_error()
	}
	if left.kind != right.kind {
		return {}, make_error(
			.Unsupported_Ast,
			"type mismatch in comparison (%v vs %v)",
			left.kind,
			right.kind,
			span = span,
		)
	}
	switch left.kind {
	case .Null:
		return 0, ok_error()
	case .Integer:
		if left.i < right.i do return -1, ok_error()
		if left.i > right.i do return 1, ok_error()
		return 0, ok_error()
	case .Float:
		if left.f < right.f do return -1, ok_error()
		if left.f > right.f do return 1, ok_error()
		return 0, ok_error()
	case .Text, .Blob:
		return bytes_compare(left.bytes, right.bytes), ok_error()
	}
	return 0, ok_error()
}

is_numeric_kind :: proc(k: Value_Kind) -> bool {
	return k == .Integer || k == .Float
}

value_as_f64 :: proc(v: Value) -> f64 {
	#partial switch v.kind {
	case .Integer:
		return f64(v.i)
	case .Float:
		return v.f
	}
	return 0
}

bytes_compare :: proc(a, b: []u8) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] < b[i] do return -1
		if a[i] > b[i] do return 1
	}
	if len(a) < len(b) do return -1
	if len(a) > len(b) do return 1
	return 0
}

eval_arith :: proc(op: sql.Binary_Op, left, right: Value, span: sql.Span) -> (Value, Exec_Error) {
	if value_is_null(left) || value_is_null(right) {
		return value_null(), ok_error()
	}
	if !is_numeric_kind(left.kind) || !is_numeric_kind(right.kind) {
		return {}, make_error(.Unsupported_Ast, "arithmetic requires numeric operands", span = span)
	}
	use_float := left.kind == .Float || right.kind == .Float || op == .Div
	if use_float {
		lf := value_as_f64(left)
		rf := value_as_f64(right)
		#partial switch op {
		case .Add:
			return value_float(lf + rf), ok_error()
		case .Sub:
			return value_float(lf - rf), ok_error()
		case .Mul:
			return value_float(lf * rf), ok_error()
		case .Div:
			if rf == 0 {
				return {}, make_error(.Unsupported_Ast, "division by zero", span = span)
			}
			return value_float(lf / rf), ok_error()
		case .Mod:
			return {}, make_error(.Unsupported_Ast, "modulo on floats is not supported", span = span)
		}
	} else {
		li := left.i
		ri := right.i
		#partial switch op {
		case .Add:
			return value_integer(li + ri), ok_error()
		case .Sub:
			return value_integer(li - ri), ok_error()
		case .Mul:
			return value_integer(li * ri), ok_error()
		case .Div:
			if ri == 0 {
				return {}, make_error(.Unsupported_Ast, "division by zero", span = span)
			}
			return value_integer(li / ri), ok_error()
		case .Mod:
			if ri == 0 {
				return {}, make_error(.Unsupported_Ast, "division by zero", span = span)
			}
			return value_integer(li % ri), ok_error()
		}
	}
	return {}, make_error(.Unsupported_Ast, "unsupported arithmetic operator", span = span)
}

eval_concat :: proc(left, right: Value, span: sql.Span, allocator := context.allocator) -> (Value, Exec_Error) {
	if value_is_null(left) || value_is_null(right) {
		return value_null(), ok_error()
	}
	ls, lerr := value_as_text(left, span, allocator)
	if has_error(lerr) {
		return {}, lerr
	}
	defer delete(ls, allocator)
	rs, rerr := value_as_text(right, span, allocator)
	if has_error(rerr) {
		return {}, rerr
	}
	defer delete(rs, allocator)
	joined := strings.concatenate({ls, rs}, allocator)
	return Value{kind = .Text, bytes = transmute([]u8)joined}, ok_error()
}

value_as_text :: proc(v: Value, span: sql.Span, allocator := context.allocator) -> (string, Exec_Error) {
	switch v.kind {
	case .Null:
		return "", make_error(.Unsupported_Ast, "cannot concatenate NULL", span = span)
	case .Text:
		return strings.clone(string(v.bytes), allocator), ok_error()
	case .Integer:
		return fmt.aprintf("%d", v.i, allocator = allocator), ok_error()
	case .Float:
		return fmt.aprintf("%g", v.f, allocator = allocator), ok_error()
	case .Blob:
		return {}, make_error(.Unsupported_Ast, "cannot concatenate BLOB", span = span)
	}
	return "", make_error(.Unsupported_Ast, "cannot concatenate value", span = span)
}

eval_is_null :: proc(d: sql.Is_Null_Data, env: ^Row_Env, allocator := context.allocator) -> (Value, Exec_Error) {
	inner, err := eval_expr(d.expr, env, allocator)
	if has_error(err) {
		return {}, err
	}
	defer free_value(inner, allocator)
	is_null := value_is_null(inner)
	if d.negated {
		is_null = !is_null
	}
	return value_integer(i64(1 if is_null else 0)), ok_error()
}

eval_in_list :: proc(
	d: sql.In_List_Data,
	span: sql.Span,
	env: ^Row_Env,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	left, lerr := eval_expr(d.expr, env, allocator)
	if has_error(lerr) {
		return {}, lerr
	}
	defer free_value(left, allocator)
	if value_is_null(left) {
		return value_null(), ok_error()
	}
	saw_null := false
	matched := false
	for item in d.values {
		v, err := eval_expr(item, env, allocator)
		if has_error(err) {
			return {}, err
		}
		if value_is_null(v) {
			free_value(v, allocator)
			saw_null = true
			continue
		}
		cmp, cerr := compare_values(left, v, span)
		free_value(v, allocator)
		if has_error(cerr) {
			return {}, cerr
		}
		if cmp == 0 {
			matched = true
			break
		}
	}
	if matched {
		return value_integer(i64(0 if d.negated else 1)), ok_error()
	}
	if saw_null {
		return value_null(), ok_error()
	}
	return value_integer(i64(1 if d.negated else 0)), ok_error()
}

// format_value_cell renders a Value for result-set / CLI display (caller owns string).
format_value_cell :: proc(v: Value, allocator := context.allocator) -> string {
	switch v.kind {
	case .Null:
		return strings.clone("NULL", allocator)
	case .Integer:
		return fmt.aprintf("%d", v.i, allocator = allocator)
	case .Float:
		return fmt.aprintf("%g", v.f, allocator = allocator)
	case .Text:
		return strings.clone(string(v.bytes), allocator)
	case .Blob:
		return format_blob_hex(v.bytes, allocator)
	}
	return strings.clone("?", allocator)
}

format_blob_hex :: proc(b: []u8, allocator := context.allocator) -> string {
	hex := "0123456789ABCDEF"
	out := make([]u8, 2 + len(b) * 2 + 1, allocator) // X'…'
	out[0] = 'X'
	out[1] = '\''
	for i in 0 ..< len(b) {
		out[2 + i * 2] = hex[b[i] >> 4]
		out[2 + i * 2 + 1] = hex[b[i] & 0xf]
	}
	out[len(out) - 1] = '\''
	return string(out)
}
