package exec

import "core:strings"
import engine "../engine"
import sql "../sql"

// Whole-query aggregates (S4) and GROUP BY / HAVING (S5 / sql-compliance).
// Null-skipping for COUNT(expr)/SUM/AVG/MIN/MAX; COUNT(*) counts all filtered rows.
// AVG always yields Float (integers promote).
// Whole-query empty input: one row (COUNT→0; SUM/AVG/MIN/MAX→NULL).
// GROUP BY empty input: zero result rows (no groups).

// i64_add_checked returns (sum, overflowed). Fail-closed for SUM(i64).
i64_add_checked :: proc(a, b: i64) -> (i64, bool) {
	if b > 0 && a > max(i64) - b {
		return 0, true
	}
	if b < 0 && a < min(i64) - b {
		return 0, true
	}
	return a + b, false
}

Agg_Fn :: enum {
	Count_Star,
	Count,
	Sum,
	Avg,
	Min,
	Max,
}

Agg_Slot :: struct {
	fn:        Agg_Fn,
	call:      ^sql.Expr, // AST Call node (pointer identity)
	arg:       ^sql.Expr, // nil for COUNT(*)
	n:         i64, // non-null inputs (COUNT/SUM/AVG) or rows for COUNT(*)
	sum_i:     i64,
	sum_f:     f64,
	use_float: bool,
	has_mm:    bool, // MIN/MAX saw a non-null
	mm:        Value, // owned MIN/MAX extremum
}

free_agg_slots :: proc(slots: []Agg_Slot, allocator := context.allocator) {
	for s in slots {
		free_value(s.mm, allocator)
	}
	if slots != nil {
		delete(slots, allocator)
	}
}

is_aggregate_name :: proc(name: string) -> bool {
	return strings.equal_fold(name, "count") ||
		strings.equal_fold(name, "sum") ||
		strings.equal_fold(name, "avg") ||
		strings.equal_fold(name, "min") ||
		strings.equal_fold(name, "max")
}

resolve_agg_fn :: proc(call: ^sql.Expr) -> (Agg_Fn, Exec_Error) {
	if call == nil || call.kind != .Call {
		return .Count, make_error(.Unsupported_Ast, "expected aggregate call")
	}
	d := call.data.(sql.Call_Data)
	name := d.name
	args := d.args
	if strings.equal_fold(name, "count") {
		if len(args) != 1 {
			return .Count, make_error(
				.Unsupported_Ast,
				"COUNT requires exactly one argument (COUNT(*) or COUNT(expr))",
				span = call.span,
			)
		}
		if args[0] != nil && args[0].kind == .Star {
			return .Count_Star, ok_error()
		}
		return .Count, ok_error()
	}
	if strings.equal_fold(name, "sum") {
		if len(args) != 1 || (args[0] != nil && args[0].kind == .Star) {
			return .Sum, make_error(
				.Unsupported_Ast,
				"SUM requires exactly one expression argument (not *)",
				span = call.span,
			)
		}
		return .Sum, ok_error()
	}
	if strings.equal_fold(name, "avg") {
		if len(args) != 1 || (args[0] != nil && args[0].kind == .Star) {
			return .Avg, make_error(
				.Unsupported_Ast,
				"AVG requires exactly one expression argument (not *)",
				span = call.span,
			)
		}
		return .Avg, ok_error()
	}
	if strings.equal_fold(name, "min") {
		if len(args) != 1 || (args[0] != nil && args[0].kind == .Star) {
			return .Min, make_error(
				.Unsupported_Ast,
				"MIN requires exactly one expression argument (not *)",
				span = call.span,
			)
		}
		return .Min, ok_error()
	}
	if strings.equal_fold(name, "max") {
		if len(args) != 1 || (args[0] != nil && args[0].kind == .Star) {
			return .Max, make_error(
				.Unsupported_Ast,
				"MAX requires exactly one expression argument (not *)",
				span = call.span,
			)
		}
		return .Max, ok_error()
	}
	return .Count, make_error(
		.Unsupported_Ast,
		"function %q is not supported",
		name,
		span = call.span,
	)
}

// Expr_Agg_Flags describes whether an expression tree contains aggregates and/or
// bare column references (outside aggregate arguments).
Expr_Agg_Flags :: struct {
	has_agg:  bool,
	has_bare: bool,
}

analyze_expr_aggs :: proc(expr: ^sql.Expr, in_agg_arg: bool = false) -> (Expr_Agg_Flags, Exec_Error) {
	if expr == nil {
		return {}, ok_error()
	}
	out: Expr_Agg_Flags
	switch expr.kind {
	case .Literal, .Placeholder:
		return {}, ok_error()
	case .Star:
		if in_agg_arg {
			return {}, ok_error()
		}
		return {}, make_error(
			.Unsupported_Ast,
			"bare * is not valid in this expression",
			span = expr.span,
		)
	case .Column_Ref:
		if !in_agg_arg {
			out.has_bare = true
		}
		return out, ok_error()
	case .Unary:
		return analyze_expr_aggs(expr.data.(sql.Unary_Data).expr, in_agg_arg)
	case .Binary:
		d := expr.data.(sql.Binary_Data)
		l, lerr := analyze_expr_aggs(d.left, in_agg_arg)
		if has_error(lerr) {
			return {}, lerr
		}
		r, rerr := analyze_expr_aggs(d.right, in_agg_arg)
		if has_error(rerr) {
			return {}, rerr
		}
		out.has_agg = l.has_agg || r.has_agg
		out.has_bare = l.has_bare || r.has_bare
		return out, ok_error()
	case .Is_Null:
		return analyze_expr_aggs(expr.data.(sql.Is_Null_Data).expr, in_agg_arg)
	case .In_List:
		d := expr.data.(sql.In_List_Data)
		f, err := analyze_expr_aggs(d.expr, in_agg_arg)
		if has_error(err) {
			return {}, err
		}
		out = f
		for v in d.values {
			vf, verr := analyze_expr_aggs(v, in_agg_arg)
			if has_error(verr) {
				return {}, verr
			}
			out.has_agg = out.has_agg || vf.has_agg
			out.has_bare = out.has_bare || vf.has_bare
		}
		return out, ok_error()
	case .Between:
		d := expr.data.(sql.Between_Data)
		a, aerr := analyze_expr_aggs(d.expr, in_agg_arg)
		if has_error(aerr) {
			return {}, aerr
		}
		b, berr := analyze_expr_aggs(d.low, in_agg_arg)
		if has_error(berr) {
			return {}, berr
		}
		c, cerr := analyze_expr_aggs(d.high, in_agg_arg)
		if has_error(cerr) {
			return {}, cerr
		}
		out.has_agg = a.has_agg || b.has_agg || c.has_agg
		out.has_bare = a.has_bare || b.has_bare || c.has_bare
		return out, ok_error()
	case .Cast:
		return analyze_expr_aggs(expr.data.(sql.Cast_Data).expr, in_agg_arg)
	case .Call:
		d := expr.data.(sql.Call_Data)
		if is_aggregate_name(d.name) {
			if in_agg_arg {
				return {}, make_error(
					.Unsupported_Ast,
					"nested aggregate functions are not supported",
					span = expr.span,
				)
			}
			_, rerr := resolve_agg_fn(expr)
			if has_error(rerr) {
				return {}, rerr
			}
			out.has_agg = true
			for arg in d.args {
				// Arguments may reference columns; those are not "bare" at select-list level.
				af, aerr := analyze_expr_aggs(arg, true)
				if has_error(aerr) {
					return {}, aerr
				}
				if af.has_agg {
					return {}, make_error(
						.Unsupported_Ast,
						"nested aggregate functions are not supported",
						span = expr.span,
					)
				}
			}
			return out, ok_error()
		}
		// Non-aggregate function: still unsupported at eval; columns in args are bare
		// unless we are already inside an aggregate argument (illegal nesting path).
		for arg in d.args {
			af, aerr := analyze_expr_aggs(arg, in_agg_arg)
			if has_error(aerr) {
				return {}, aerr
			}
			out.has_agg = out.has_agg || af.has_agg
			out.has_bare = out.has_bare || af.has_bare
		}
		return out, ok_error()
	}
	return {}, make_error(.Unsupported_Ast, "unsupported expression", span = expr.span)
}

collect_agg_calls :: proc(
	expr: ^sql.Expr,
	slots: ^[dynamic]Agg_Slot,
) -> Exec_Error {
	if expr == nil {
		return ok_error()
	}
	switch expr.kind {
	case .Literal, .Placeholder, .Star, .Column_Ref:
		return ok_error()
	case .Unary:
		return collect_agg_calls(expr.data.(sql.Unary_Data).expr, slots)
	case .Binary:
		d := expr.data.(sql.Binary_Data)
		if err := collect_agg_calls(d.left, slots); has_error(err) {
			return err
		}
		return collect_agg_calls(d.right, slots)
	case .Is_Null:
		return collect_agg_calls(expr.data.(sql.Is_Null_Data).expr, slots)
	case .In_List:
		d := expr.data.(sql.In_List_Data)
		if err := collect_agg_calls(d.expr, slots); has_error(err) {
			return err
		}
		for v in d.values {
			if err := collect_agg_calls(v, slots); has_error(err) {
				return err
			}
		}
		return ok_error()
	case .Between:
		d := expr.data.(sql.Between_Data)
		if err := collect_agg_calls(d.expr, slots); has_error(err) {
			return err
		}
		if err := collect_agg_calls(d.low, slots); has_error(err) {
			return err
		}
		return collect_agg_calls(d.high, slots)
	case .Cast:
		return collect_agg_calls(expr.data.(sql.Cast_Data).expr, slots)
	case .Call:
		d := expr.data.(sql.Call_Data)
		if is_aggregate_name(d.name) {
			fn, ferr := resolve_agg_fn(expr)
			if has_error(ferr) {
				return ferr
			}
			slot := Agg_Slot{
				fn   = fn,
				call = expr,
				arg  = nil,
			}
			if fn != .Count_Star && len(d.args) == 1 {
				slot.arg = d.args[0]
			}
			append(slots, slot)
			// Do not recurse into args for further agg collection (nested already rejected).
			return ok_error()
		}
		for arg in d.args {
			if err := collect_agg_calls(arg, slots); has_error(err) {
				return err
			}
		}
		return ok_error()
	}
	return ok_error()
}

// prepare_aggregate_select returns whether this SELECT is whole-query aggregate mode
// (no GROUP BY) and the accumulator slots. Caller owns slots (free_agg_slots).
prepare_aggregate_select :: proc(
	stmt: sql.Select_Stmt,
	allocator := context.allocator,
) -> (is_agg: bool, slots: []Agg_Slot, err: Exec_Error) {
	if len(stmt.group_by) > 0 {
		return false, nil, ok_error() // grouped path owns this
	}

	any_agg := false
	any_bare := false

	for item in stmt.projection {
		switch item.kind {
		case .Star, .Table_Star:
			any_bare = true
		case .Expr:
			if item.expr == nil {
				continue
			}
			flags, aerr := analyze_expr_aggs(item.expr, false)
			if has_error(aerr) {
				return false, nil, aerr
			}
			any_agg = any_agg || flags.has_agg
			any_bare = any_bare || flags.has_bare
		}
	}

	if !any_agg {
		return false, nil, ok_error()
	}
	if any_bare {
		return false, nil, make_error(
			.Unsupported_Ast,
			"SELECT mixes aggregates with non-aggregate columns; GROUP BY is required",
			span = stmt.projection[0].span if len(stmt.projection) > 0 else {},
		)
	}

	if err := reject_aggs_in_where(stmt); has_error(err) {
		return false, nil, err
	}

	// ORDER BY with bare columns is illegal without GROUP BY; aggregates in ORDER BY deferred.
	for item in stmt.order_by {
		of, oerr := analyze_expr_aggs(item.expr, false)
		if has_error(oerr) {
			return false, nil, oerr
		}
		if of.has_bare {
			return false, nil, make_error(
				.Unsupported_Ast,
				"ORDER BY column not allowed with aggregate SELECT without GROUP BY",
				span = item.expr.span if item.expr != nil else {},
			)
		}
		if of.has_agg {
			return false, nil, make_error(
				.Unsupported_Ast,
				"ORDER BY aggregates are not supported yet",
				span = item.expr.span if item.expr != nil else {},
			)
		}
	}

	dyn := make([dynamic]Agg_Slot, 0, 4, allocator)
	for item in stmt.projection {
		if item.kind == .Expr && item.expr != nil {
			if cerr := collect_agg_calls(item.expr, &dyn); has_error(cerr) {
				free_agg_slots(dyn[:], allocator)
				delete(dyn)
				return false, nil, cerr
			}
		}
	}
	if len(dyn) == 0 {
		delete(dyn)
		return false, nil, make_error(.Engine, "aggregate SELECT produced no aggregate slots")
	}
	return true, dyn[:], ok_error()
}

reject_aggs_in_where :: proc(stmt: sql.Select_Stmt) -> Exec_Error {
	if stmt.where_expr == nil {
		return ok_error()
	}
	wf, werr := analyze_expr_aggs(stmt.where_expr, false)
	if has_error(werr) {
		return werr
	}
	if wf.has_agg {
		return make_error(
			.Unsupported_Ast,
			"aggregate functions are not allowed in WHERE",
			span = stmt.where_expr.span,
		)
	}
	return ok_error()
}

// resolve_group_by_columns requires each GROUP BY item to be a column ref (S5 start).
// Returns owned slice of catalog column indices. Caller deletes.
resolve_group_by_columns :: proc(
	stmt: sql.Select_Stmt,
	columns: []engine.Catalog_Column,
	table_name, alias: string,
	sides: []Join_Side = nil,
	allocator := context.allocator,
) -> ([]int, Exec_Error) {
	if len(stmt.group_by) == 0 {
		return nil, make_error(.Engine, "resolve_group_by_columns called without GROUP BY")
	}
	out := make([]int, len(stmt.group_by), allocator)
	for expr, i in stmt.group_by {
		if expr == nil || expr.kind != .Column_Ref {
			delete(out, allocator)
			return nil, make_error(
				.Unsupported_Ast,
				"GROUP BY only supports column references (expressions not supported yet)",
				span = expr.span if expr != nil else {},
			)
		}
		idx, ok, rerr := resolve_proj_column(
			expr.data.(sql.Column_Ref_Data),
			columns,
			table_name,
			alias,
			expr.span,
			sides,
		)
		if has_error(rerr) {
			delete(out, allocator)
			return nil, rerr
		}
		if !ok {
			delete(out, allocator)
			return nil, make_error(.Unknown_Column, "GROUP BY column could not be resolved", span = expr.span)
		}
		out[i] = idx
	}
	return out, ok_error()
}

column_idx_in_group :: proc(col_idx: int, group_idxs: []int) -> bool {
	for g in group_idxs {
		if g == col_idx {
			return true
		}
	}
	return false
}

// validate_expr_group_cols ensures every bare Column_Ref outside aggregate args
// resolves to a GROUP BY column (strict select list / HAVING / ORDER BY).
validate_expr_group_cols :: proc(
	expr: ^sql.Expr,
	group_idxs: []int,
	columns: []engine.Catalog_Column,
	table_name, alias: string,
	in_agg_arg: bool = false,
	sides: []Join_Side = nil,
) -> Exec_Error {
	if expr == nil {
		return ok_error()
	}
	switch expr.kind {
	case .Literal, .Placeholder, .Star:
		return ok_error()
	case .Column_Ref:
		if in_agg_arg {
			return ok_error()
		}
		idx, ok, rerr := resolve_proj_column(
			expr.data.(sql.Column_Ref_Data),
			columns,
			table_name,
			alias,
			expr.span,
			sides,
		)
		if has_error(rerr) {
			return rerr
		}
		if !ok || !column_idx_in_group(idx, group_idxs) {
			return make_error(
				.Unsupported_Ast,
				"column must appear in GROUP BY or be used in an aggregate function",
				span = expr.span,
			)
		}
		return ok_error()
	case .Unary:
		return validate_expr_group_cols(
			expr.data.(sql.Unary_Data).expr,
			group_idxs,
			columns,
			table_name,
			alias,
			in_agg_arg,
			sides,
		)
	case .Binary:
		d := expr.data.(sql.Binary_Data)
		if err := validate_expr_group_cols(d.left, group_idxs, columns, table_name, alias, in_agg_arg, sides); has_error(err) {
			return err
		}
		return validate_expr_group_cols(d.right, group_idxs, columns, table_name, alias, in_agg_arg, sides)
	case .Is_Null:
		return validate_expr_group_cols(
			expr.data.(sql.Is_Null_Data).expr,
			group_idxs,
			columns,
			table_name,
			alias,
			in_agg_arg,
			sides,
		)
	case .In_List:
		d := expr.data.(sql.In_List_Data)
		if err := validate_expr_group_cols(d.expr, group_idxs, columns, table_name, alias, in_agg_arg, sides); has_error(err) {
			return err
		}
		for v in d.values {
			if err := validate_expr_group_cols(v, group_idxs, columns, table_name, alias, in_agg_arg, sides); has_error(err) {
				return err
			}
		}
		return ok_error()
	case .Between:
		d := expr.data.(sql.Between_Data)
		if err := validate_expr_group_cols(d.expr, group_idxs, columns, table_name, alias, in_agg_arg, sides); has_error(err) {
			return err
		}
		if err := validate_expr_group_cols(d.low, group_idxs, columns, table_name, alias, in_agg_arg, sides); has_error(err) {
			return err
		}
		return validate_expr_group_cols(d.high, group_idxs, columns, table_name, alias, in_agg_arg, sides)
	case .Cast:
		return validate_expr_group_cols(
			expr.data.(sql.Cast_Data).expr,
			group_idxs,
			columns,
			table_name,
			alias,
			in_agg_arg,
			sides,
		)
	case .Call:
		d := expr.data.(sql.Call_Data)
		if is_aggregate_name(d.name) {
			if in_agg_arg {
				return make_error(
					.Unsupported_Ast,
					"nested aggregate functions are not supported",
					span = expr.span,
				)
			}
			_, rerr := resolve_agg_fn(expr)
			if has_error(rerr) {
				return rerr
			}
			for arg in d.args {
				if err := validate_expr_group_cols(arg, group_idxs, columns, table_name, alias, true, sides); has_error(err) {
					return err
				}
			}
			return ok_error()
		}
		for arg in d.args {
			if err := validate_expr_group_cols(arg, group_idxs, columns, table_name, alias, in_agg_arg, sides); has_error(err) {
				return err
			}
		}
		return ok_error()
	}
	return make_error(.Unsupported_Ast, "unsupported expression", span = expr.span)
}

// prepare_grouped_select validates GROUP BY / HAVING / strict select list and
// collects aggregate slots (from projection, HAVING, ORDER BY). Caller owns
// group_idxs (delete) and slots (free_agg_slots).
prepare_grouped_select :: proc(
	stmt: sql.Select_Stmt,
	columns: []engine.Catalog_Column,
	table_name, alias: string,
	sides: []Join_Side = nil,
	allocator := context.allocator,
) -> (group_idxs: []int, slots: []Agg_Slot, err: Exec_Error) {
	gidxs, gerr := resolve_group_by_columns(stmt, columns, table_name, alias, sides, allocator)
	if has_error(gerr) {
		return nil, nil, gerr
	}

	if werr := reject_aggs_in_where(stmt); has_error(werr) {
		delete(gidxs, allocator)
		return nil, nil, werr
	}

	for item in stmt.projection {
		switch item.kind {
		case .Star, .Table_Star:
			delete(gidxs, allocator)
			return nil, nil, make_error(
				.Unsupported_Ast,
				"SELECT * is not allowed with GROUP BY (strict: list grouped columns and aggregates)",
				span = item.span,
			)
		case .Expr:
			if item.expr == nil {
				continue
			}
			if verr := validate_expr_group_cols(
				item.expr,
				gidxs,
				columns,
				table_name,
				alias,
				false,
				sides,
			); has_error(verr) {
				delete(gidxs, allocator)
				return nil, nil, verr
			}
		}
	}

	if stmt.having != nil {
		if verr := validate_expr_group_cols(
			stmt.having,
			gidxs,
			columns,
			table_name,
			alias,
			false,
			sides,
		); has_error(verr) {
			delete(gidxs, allocator)
			return nil, nil, verr
		}
	}

	for item in stmt.order_by {
		if item.expr == nil {
			continue
		}
		if verr := validate_expr_group_cols(
			item.expr,
			gidxs,
			columns,
			table_name,
			alias,
			false,
			sides,
		); has_error(verr) {
			delete(gidxs, allocator)
			return nil, nil, verr
		}
	}

	dyn := make([dynamic]Agg_Slot, 0, 4, allocator)
	for item in stmt.projection {
		if item.kind == .Expr && item.expr != nil {
			if cerr := collect_agg_calls(item.expr, &dyn); has_error(cerr) {
				free_agg_slots(dyn[:], allocator)
				delete(dyn)
				delete(gidxs, allocator)
				return nil, nil, cerr
			}
		}
	}
	if stmt.having != nil {
		if cerr := collect_agg_calls(stmt.having, &dyn); has_error(cerr) {
			free_agg_slots(dyn[:], allocator)
			delete(dyn)
			delete(gidxs, allocator)
			return nil, nil, cerr
		}
	}
	for item in stmt.order_by {
		if item.expr != nil {
			if cerr := collect_agg_calls(item.expr, &dyn); has_error(cerr) {
				free_agg_slots(dyn[:], allocator)
				delete(dyn)
				delete(gidxs, allocator)
				return nil, nil, cerr
			}
		}
	}
	return gidxs, dyn[:], ok_error()
}

clone_agg_slot_templates :: proc(
	templates: []Agg_Slot,
	allocator := context.allocator,
) -> []Agg_Slot {
	if len(templates) == 0 {
		return nil
	}
	out := make([]Agg_Slot, len(templates), allocator)
	for t, i in templates {
		out[i] = Agg_Slot{
			fn   = t.fn,
			call = t.call,
			arg  = t.arg,
		}
	}
	return out
}

group_keys_equal :: proc(a, b: []Value) -> (bool, Exec_Error) {
	if len(a) != len(b) {
		return false, ok_error()
	}
	for i in 0 ..< len(a) {
		cmp, err := compare_values(a[i], b[i])
		if has_error(err) {
			return false, err
		}
		if cmp != 0 {
			return false, ok_error()
		}
	}
	return true, ok_error()
}

extract_group_key :: proc(
	row: []Value,
	group_idxs: []int,
	allocator := context.allocator,
) -> ([]Value, Exec_Error) {
	key := make([]Value, len(group_idxs), allocator)
	for gi, i in group_idxs {
		if gi < 0 || gi >= len(row) {
			free_values(key, allocator)
			return nil, make_error(.Engine, "GROUP BY column index out of range")
		}
		key[i] = clone_value(row[gi], allocator)
	}
	return key, ok_error()
}

make_group_rep_row :: proc(
	columns_len: int,
	group_idxs: []int,
	key: []Value,
	allocator := context.allocator,
) -> []Value {
	row := make([]Value, columns_len, allocator)
	for i in 0 ..< columns_len {
		row[i] = value_null()
	}
	for gi, i in group_idxs {
		if gi >= 0 && gi < columns_len && i < len(key) {
			free_value(row[gi], allocator)
			row[gi] = clone_value(key[i], allocator)
		}
	}
	return row
}

eval_expr_bool_with_aggs :: proc(
	expr: ^sql.Expr,
	slots: []Agg_Slot,
	finals: []Value,
	env: ^Row_Env,
	allocator := context.allocator,
) -> (bool, Exec_Error) {
	v, err := eval_expr_with_aggs(expr, slots, finals, env, allocator)
	if has_error(err) {
		return false, err
	}
	defer free_value(v, allocator)
	if value_is_null(v) {
		return false, ok_error()
	}
	if berr := require_bool_operand(v, expr.span if expr != nil else {}); has_error(berr) {
		return false, berr
	}
	return value_is_true(v), ok_error()
}

accumulate_agg_slot :: proc(
	slot: ^Agg_Slot,
	env: ^Row_Env,
	allocator := context.allocator,
) -> Exec_Error {
	switch slot.fn {
	case .Count_Star:
		slot.n += 1
		return ok_error()
	case .Count, .Sum, .Avg, .Min, .Max:
		if slot.arg == nil {
			return make_error(.Unsupported_Ast, "aggregate missing argument")
		}
		v, err := eval_expr(slot.arg, env, allocator)
		if has_error(err) {
			return err
		}
		defer free_value(v, allocator)
		if value_is_null(v) {
			return ok_error() // null-skipping
		}
		#partial switch slot.fn {
		case .Count:
			slot.n += 1
			return ok_error()
		case .Sum, .Avg:
			if !is_numeric_kind(v.kind) {
				return make_error(
					.Unsupported_Ast,
					"%s requires a numeric argument (got %v)",
					agg_fn_name(slot.fn),
					v.kind,
					span = slot.call.span if slot.call != nil else {},
				)
			}
			slot.n += 1
			if v.kind == .Float || slot.use_float {
				if !slot.use_float {
					slot.sum_f = f64(slot.sum_i)
					slot.use_float = true
				}
				slot.sum_f += value_as_f64(v)
			} else {
				sum, overflowed := i64_add_checked(slot.sum_i, v.i)
				if overflowed {
					return make_error(
						.Unsupported_Ast,
						"SUM overflow: integer sum does not fit in i64",
						span = slot.call.span if slot.call != nil else {},
					)
				}
				slot.sum_i = sum
			}
			return ok_error()
		case .Min, .Max:
			if !is_numeric_kind(v.kind) {
				return make_error(
					.Unsupported_Ast,
					"%s requires a numeric argument (got %v)",
					agg_fn_name(slot.fn),
					v.kind,
					span = slot.call.span if slot.call != nil else {},
				)
			}
			if !slot.has_mm {
				slot.mm = clone_value(v, allocator)
				slot.has_mm = true
				return ok_error()
			}
			cmp, cerr := compare_values(v, slot.mm, slot.call.span if slot.call != nil else {})
			if has_error(cerr) {
				return cerr
			}
			replace := (slot.fn == .Min && cmp < 0) || (slot.fn == .Max && cmp > 0)
			if replace {
				free_value(slot.mm, allocator)
				slot.mm = clone_value(v, allocator)
			}
			return ok_error()
		}
	}
	return ok_error()
}

agg_fn_name :: proc(fn: Agg_Fn) -> string {
	switch fn {
	case .Count_Star, .Count:
		return "COUNT"
	case .Sum:
		return "SUM"
	case .Avg:
		return "AVG"
	case .Min:
		return "MIN"
	case .Max:
		return "MAX"
	}
	return "AGG"
}

finalize_agg_slot :: proc(slot: Agg_Slot, allocator := context.allocator) -> (Value, Exec_Error) {
	switch slot.fn {
	case .Count_Star, .Count:
		return value_integer(slot.n), ok_error()
	case .Sum:
		if slot.n == 0 {
			return value_null(), ok_error()
		}
		if slot.use_float {
			return value_float(slot.sum_f), ok_error()
		}
		return value_integer(slot.sum_i), ok_error()
	case .Avg:
		if slot.n == 0 {
			return value_null(), ok_error()
		}
		total := slot.sum_f if slot.use_float else f64(slot.sum_i)
		return value_float(total / f64(slot.n)), ok_error()
	case .Min, .Max:
		if !slot.has_mm {
			return value_null(), ok_error()
		}
		return clone_value(slot.mm, allocator), ok_error()
	}
	return value_null(), ok_error()
}

find_agg_slot :: proc(slots: []Agg_Slot, call: ^sql.Expr) -> (int, bool) {
	for s, i in slots {
		if s.call == call {
			return i, true
		}
	}
	return -1, false
}

// eval_expr_with_aggs evaluates a projection expression after aggregates are finalized.
// `finals[i]` is the Value for `slots[i]` (same length; caller owns).
eval_expr_with_aggs :: proc(
	expr: ^sql.Expr,
	slots: []Agg_Slot,
	finals: []Value,
	env: ^Row_Env,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	if expr == nil {
		return {}, error_at(.Unsupported_Ast, "missing expression")
	}
	switch expr.kind {
	case .Call:
		if idx, ok := find_agg_slot(slots, expr); ok {
			return clone_value(finals[idx], allocator), ok_error()
		}
		return {}, make_error(
			.Unsupported_Ast,
			"function calls are not supported yet",
			span = expr.span,
		)
	case .Literal:
		return value_from_literal(expr.data.(sql.Literal_Data), expr.span, allocator)
	case .Column_Ref:
		return eval_column_ref(expr.data.(sql.Column_Ref_Data), expr.span, env, allocator)
	case .Unary:
		return eval_unary_with_aggs(expr.data.(sql.Unary_Data), expr.span, slots, finals, env, allocator)
	case .Binary:
		return eval_binary_with_aggs(expr.data.(sql.Binary_Data), expr.span, slots, finals, env, allocator)
	case .Is_Null:
		inner, err := eval_expr_with_aggs(expr.data.(sql.Is_Null_Data).expr, slots, finals, env, allocator)
		if has_error(err) {
			return {}, err
		}
		defer free_value(inner, allocator)
		is_null := value_is_null(inner)
		if expr.data.(sql.Is_Null_Data).negated {
			is_null = !is_null
		}
		return value_integer(i64(1 if is_null else 0)), ok_error()
	case .In_List:
		return eval_in_list_with_aggs(expr.data.(sql.In_List_Data), expr.span, slots, finals, env, allocator)
	case .Placeholder:
		return {}, make_error(.Unsupported_Ast, "parameter placeholders are not supported yet", span = expr.span)
	case .Star:
		return {}, make_error(.Unsupported_Ast, "bare * is not valid in this expression", span = expr.span)
	case .Between:
		return {}, make_error(.Unsupported_Ast, "BETWEEN is not supported yet", span = expr.span)
	case .Cast:
		return eval_cast_with_aggs(expr.data.(sql.Cast_Data), expr.span, slots, finals, env, allocator)
	}
	return {}, make_error(.Unsupported_Ast, "unsupported expression", span = expr.span)
}

eval_unary_with_aggs :: proc(
	u: sql.Unary_Data,
	span: sql.Span,
	slots: []Agg_Slot,
	finals: []Value,
	env: ^Row_Env,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	inner, err := eval_expr_with_aggs(u.expr, slots, finals, env, allocator)
	if has_error(err) {
		return {}, err
	}
	switch u.op {
	case .Plus:
		#partial switch inner.kind {
		case .Null, .Integer, .Float:
			return inner, ok_error()
		case .Text, .Blob, .Boolean, .Uuid:
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
		case .Text, .Blob, .Boolean, .Uuid:
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

eval_binary_with_aggs :: proc(
	b: sql.Binary_Data,
	span: sql.Span,
	slots: []Agg_Slot,
	finals: []Value,
	env: ^Row_Env,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	#partial switch b.op {
	case .And, .Or:
		// Aggregates in boolean AND/OR in projection are unusual; evaluate both sides.
		left, lerr := eval_expr_with_aggs(b.left, slots, finals, env, allocator)
		if has_error(lerr) {
			return {}, lerr
		}
		defer free_value(left, allocator)
		right, rerr := eval_expr_with_aggs(b.right, slots, finals, env, allocator)
		if has_error(rerr) {
			return {}, rerr
		}
		defer free_value(right, allocator)
		left_span := b.left.span if b.left != nil else span
		right_span := b.right.span if b.right != nil else span
		if berr := require_bool_operand(left, left_span); has_error(berr) {
			return {}, berr
		}
		if berr := require_bool_operand(right, right_span); has_error(berr) {
			return {}, berr
		}
		if b.op == .And {
			if value_is_false(left) || value_is_false(right) {
				return value_integer(0), ok_error()
			}
			if value_is_null(left) || value_is_null(right) {
				return value_null(), ok_error()
			}
			return value_integer(1), ok_error()
		}
		if value_is_true(left) || value_is_true(right) {
			return value_integer(1), ok_error()
		}
		if value_is_null(left) || value_is_null(right) {
			return value_null(), ok_error()
		}
		return value_integer(0), ok_error()
	}

	left, lerr := eval_expr_with_aggs(b.left, slots, finals, env, allocator)
	if has_error(lerr) {
		return {}, lerr
	}
	defer free_value(left, allocator)
	right, rerr := eval_expr_with_aggs(b.right, slots, finals, env, allocator)
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

eval_in_list_with_aggs :: proc(
	d: sql.In_List_Data,
	span: sql.Span,
	slots: []Agg_Slot,
	finals: []Value,
	env: ^Row_Env,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	left, lerr := eval_expr_with_aggs(d.expr, slots, finals, env, allocator)
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
		v, err := eval_expr_with_aggs(item, slots, finals, env, allocator)
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

eval_cast_with_aggs :: proc(
	d: sql.Cast_Data,
	span: sql.Span,
	slots: []Agg_Slot,
	finals: []Value,
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
	inner, err := eval_expr_with_aggs(d.expr, slots, finals, env, allocator)
	if has_error(err) {
		return {}, err
	}
	if value_is_null(inner) {
		return value_null(), ok_error()
	}
	defer free_value(inner, allocator)
	return cast_value(inner, target, d.type_name, span, allocator)
}

// validate_agg_arg_exprs dry-runs aggregate argument expressions (and non-agg
// projection pieces) so unbound names fail even on empty tables.
validate_agg_projection_exprs :: proc(
	stmt: sql.Select_Stmt,
	slots: []Agg_Slot,
	columns: []engine.Catalog_Column,
	table_name, alias: string,
	sides: []Join_Side = nil,
) -> Exec_Error {
	nulls := make([]Value, len(columns))
	defer delete(nulls)
	for i in 0 ..< len(nulls) {
		nulls[i] = value_null()
	}
	env := Row_Env{
		table   = table_name,
		alias   = alias,
		columns = columns,
		values  = nulls,
		sides   = sides,
	}
	for j in stmt.joins {
		if j.on == nil {
			continue
		}
		v, err := eval_expr(j.on, &env)
		free_value(v)
		if has_error(err) {
			return err
		}
	}
	if stmt.where_expr != nil {
		v, err := eval_expr(stmt.where_expr, &env)
		free_value(v)
		if has_error(err) {
			return err
		}
	}
	for item in stmt.order_by {
		of, oerr := analyze_expr_aggs(item.expr, false)
		if has_error(oerr) {
			return oerr
		}
		if of.has_agg {
			// Aggregates in ORDER BY (grouped) need finalized slots; skip dry-run.
			continue
		}
		v, err := eval_expr(item.expr, &env)
		free_value(v)
		if has_error(err) {
			return err
		}
	}
	for s in slots {
		if s.arg != nil {
			v, err := eval_expr(s.arg, &env)
			free_value(v)
			if has_error(err) {
				return err
			}
		}
	}
	// Constant-only projection items (no agg): dry-run full eval without row deps.
	for item in stmt.projection {
		if item.kind != .Expr || item.expr == nil {
			continue
		}
		flags, _ := analyze_expr_aggs(item.expr, false)
		if flags.has_agg {
			continue
		}
		// Grouped selects may reference group-key columns; null-row dry-run is fine.
		v, err := eval_expr(item.expr, &env)
		free_value(v)
		if has_error(err) {
			return err
		}
	}
	if stmt.having != nil {
		// Dry-run HAVING structure with nulls / no finalized aggs via analyze only;
		// unbound names in non-agg parts already checked by validate_expr_group_cols.
		hf, herr := analyze_expr_aggs(stmt.having, false)
		if has_error(herr) {
			return herr
		}
		_ = hf
	}
	return ok_error()
}
