package exec

import sql "../sql"

// Bind_Table holds positional parameter values for Placeholder eval (`?` / `?N`).
// Values are owned by the table (cloned on bind); free via bind_table_clear / session_clear_binds.
Bind_Table :: struct {
	values: [dynamic]Value,
	filled: [dynamic]bool,
}

// Package-level active binds for the current exec_statement / exec_script statement.
// Single-threaded: set around each statement; Placeholder eval reads this.
@(private = "file")
_active_binds: ^Bind_Table

bind_table_activate :: proc(bt: ^Bind_Table) -> ^Bind_Table {
	prev := _active_binds
	_active_binds = bt
	return prev
}

bind_table_restore :: proc(prev: ^Bind_Table) {
	_active_binds = prev
}

bind_table_clear :: proc(bt: ^Bind_Table, allocator := context.allocator) {
	if bt == nil {
		return
	}
	for i in 0 ..< len(bt.values) {
		if i < len(bt.filled) && bt.filled[i] {
			free_value(bt.values[i], allocator)
		}
	}
	clear(&bt.values)
	clear(&bt.filled)
}

bind_table_destroy :: proc(bt: ^Bind_Table, allocator := context.allocator) {
	if bt == nil {
		return
	}
	bind_table_clear(bt, allocator)
	delete(bt.values)
	delete(bt.filled)
	bt.values = nil
	bt.filled = nil
}

bind_table_ensure :: proc(bt: ^Bind_Table, index: int, allocator := context.allocator) {
	if bt == nil || index < 0 {
		return
	}
	for len(bt.values) <= index {
		append(&bt.values, value_null())
		append(&bt.filled, false)
	}
}

// bind_table_set clones `value` into slot `index` (replacing any previous value).
bind_table_set :: proc(
	bt: ^Bind_Table,
	index: int,
	value: Value,
	allocator := context.allocator,
) -> Exec_Error {
	if bt == nil {
		return error_at(.Closed, "no bind table")
	}
	if index < 0 {
		return make_error(.Invalid_Schema, "parameter index %d is negative", index)
	}
	bind_table_ensure(bt, index, allocator)
	if bt.filled[index] {
		free_value(bt.values[index], allocator)
	}
	bt.values[index] = clone_value(value, allocator)
	bt.filled[index] = true
	return ok_error()
}

// lookup_active_bind returns a clone of the bound value at index.
// Unbound / missing active table → Invalid_Schema with a clear message.
lookup_active_bind :: proc(
	index: int,
	span: sql.Span,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	bt := _active_binds
	if bt == nil {
		return {}, make_error(
			.Invalid_Schema,
			"unbound parameter ?%d (no bind context)",
			index,
			span = span,
		)
	}
	if index < 0 {
		return {}, make_error(.Invalid_Schema, "parameter index %d is negative", index, span = span)
	}
	if index >= len(bt.filled) || !bt.filled[index] {
		return {}, make_error(.Invalid_Schema, "unbound parameter ?%d", index, span = span)
	}
	return clone_value(bt.values[index], allocator), ok_error()
}

// session_bind clones `value` into positional slot `index` on the session bind table.
// Caller retains ownership of `value`. Binds persist until clear / rebind / session_close.
session_bind :: proc(
	s: ^Exec_Session,
	index: int,
	value: Value,
	allocator := context.allocator,
) -> Exec_Error {
	if s == nil || s.closed {
		return error_at(.Closed, "session is closed")
	}
	return bind_table_set(&s.binds, index, value, allocator)
}

// session_bind_all clears existing binds, then binds values at indices 0..len-1 (each cloned).
session_bind_all :: proc(
	s: ^Exec_Session,
	values: []Value,
	allocator := context.allocator,
) -> Exec_Error {
	if s == nil || s.closed {
		return error_at(.Closed, "session is closed")
	}
	session_clear_binds(s, allocator)
	for v, i in values {
		err := bind_table_set(&s.binds, i, v, allocator)
		if has_error(err) {
			return err
		}
	}
	return ok_error()
}

// session_clear_binds frees all cloned bind values and releases the bind table storage.
session_clear_binds :: proc(s: ^Exec_Session, allocator := context.allocator) {
	if s == nil {
		return
	}
	bind_table_destroy(&s.binds, allocator)
}

// session_bind_count returns how many slots are currently filled (not max index + 1).
session_bind_count :: proc(s: ^Exec_Session) -> int {
	if s == nil {
		return 0
	}
	n := 0
	for filled in s.binds.filled {
		if filled {
			n += 1
		}
	}
	return n
}

// collect_placeholder_max walks an expression tree; returns max index seen (−1 if none).
collect_placeholder_max_expr :: proc(expr: ^sql.Expr) -> int {
	if expr == nil {
		return -1
	}
	max_i := -1
	switch expr.kind {
	case .Placeholder:
		max_i = expr.data.(sql.Placeholder_Data).index
	case .Literal, .Column_Ref, .Star:
	case .Unary:
		max_i = collect_placeholder_max_expr(expr.data.(sql.Unary_Data).expr)
	case .Binary:
		d := expr.data.(sql.Binary_Data)
		max_i = max(collect_placeholder_max_expr(d.left), collect_placeholder_max_expr(d.right))
	case .Call:
		for arg in expr.data.(sql.Call_Data).args {
			max_i = max(max_i, collect_placeholder_max_expr(arg))
		}
	case .Is_Null:
		max_i = collect_placeholder_max_expr(expr.data.(sql.Is_Null_Data).expr)
	case .In_List:
		d := expr.data.(sql.In_List_Data)
		max_i = collect_placeholder_max_expr(d.expr)
		for v in d.values {
			max_i = max(max_i, collect_placeholder_max_expr(v))
		}
	case .Between:
		d := expr.data.(sql.Between_Data)
		max_i = collect_placeholder_max_expr(d.expr)
		max_i = max(max_i, collect_placeholder_max_expr(d.low))
		max_i = max(max_i, collect_placeholder_max_expr(d.high))
	case .Cast:
		max_i = collect_placeholder_max_expr(expr.data.(sql.Cast_Data).expr)
	}
	return max_i
}

collect_placeholder_max_statement :: proc(stmt: sql.Statement) -> int {
	max_i := -1
	switch stmt.kind {
	case .Select:
		s := stmt.data.(sql.Select_Stmt)
		for item in s.projection {
			max_i = max(max_i, collect_placeholder_max_expr(item.expr))
		}
		max_i = max(max_i, collect_placeholder_max_expr(s.where_expr))
		max_i = max(max_i, collect_placeholder_max_expr(s.having))
		max_i = max(max_i, collect_placeholder_max_expr(s.limit))
		max_i = max(max_i, collect_placeholder_max_expr(s.offset))
		for j in s.joins {
			max_i = max(max_i, collect_placeholder_max_expr(j.on))
		}
		for g in s.group_by {
			max_i = max(max_i, collect_placeholder_max_expr(g))
		}
		for o in s.order_by {
			max_i = max(max_i, collect_placeholder_max_expr(o.expr))
		}
	case .Insert:
		ins := stmt.data.(sql.Insert_Stmt)
		for row in ins.rows {
			for expr in row {
				max_i = max(max_i, collect_placeholder_max_expr(expr))
			}
		}
	case .Update:
		u := stmt.data.(sql.Update_Stmt)
		for a in u.sets {
			max_i = max(max_i, collect_placeholder_max_expr(a.value))
		}
		max_i = max(max_i, collect_placeholder_max_expr(u.where_expr))
	case .Delete:
		d := stmt.data.(sql.Delete_Stmt)
		max_i = max(max_i, collect_placeholder_max_expr(d.where_expr))
	case .Create_Table, .Drop_Table, .Create_Index, .Drop_Index, .Alter_Table, .Begin, .Commit, .Rollback:
	}
	return max_i
}

// validate_bind_arity checks that exactly max_ph+1 params were provided when placeholders are used.
// No placeholders → params must be empty. Gaps (e.g. only ?2 bound via bind_all of length 1) fail here.
validate_bind_arity :: proc(max_ph: int, param_count: int, span: sql.Span) -> Exec_Error {
	if max_ph < 0 {
		if param_count != 0 {
			return make_error(
				.Invalid_Schema,
				"parameter arity mismatch: statement has no placeholders but %d value(s) were bound",
				param_count,
				span = span,
			)
		}
		return ok_error()
	}
	need := max_ph + 1
	if param_count != need {
		return make_error(
			.Invalid_Schema,
			"parameter arity mismatch: statement uses parameters through ?%d (%d slot(s)) but %d value(s) were bound",
			max_ph,
			need,
			param_count,
			span = span,
		)
	}
	return ok_error()
}
