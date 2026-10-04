package exec

import engine "../engine"
import sql "../sql"

Bound_Assign :: struct {
	col_idx: int,
	expr:    ^sql.Expr,
}

// exec_delete runs DELETE FROM t [WHERE …] (seq scan + delete-by-rowid).
exec_delete :: proc(s: ^Exec_Session, stmt: sql.Delete_Stmt, span: sql.Span) -> (Exec_Result, Exec_Error) {
	e := session_engine(s)
	if e == nil {
		return {}, error_at(.Closed, "session is closed", span)
	}
	if stmt.table == "" {
		return {}, make_error(.Invalid_Schema, "DELETE requires a table name", span = span)
	}

	entry, gerr := engine.catalog_get_table_entry(e, stmt.table)
	if gerr == .Not_Found {
		return {}, make_error(.Unknown_Table, "no such table: %q", stmt.table, span = span)
	}
	if gerr != .None {
		return {}, from_engine_error(gerr, span)
	}
	defer engine.free_catalog_entry(entry)

	if len(entry.columns) == 0 {
		return {}, make_error(.Invalid_Schema, "table %q has no columns", stmt.table, span = span)
	}

	if verr := validate_mutate_where(stmt.where_expr, entry.columns, stmt.table); has_error(verr) {
		return {}, verr
	}

	started, btxn := stmt_write_begin(s, e, span)
	if has_error(btxn) {
		return {}, btxn
	}

	idx_refs, ixerr := table_indexes_maintained(e, stmt.table, span)
	if has_error(ixerr) {
		return {}, finish_write_error(s, e, started, ixerr, span)
	}
	defer engine.free_catalog_index_refs(idx_refs)

	tree, oerr := engine.catalog_open_table(e, stmt.table)
	if oerr != .None {
		return {}, finish_write_error(s, e, started, from_engine_error(oerr, span), span)
	}

	rowids, cerr := collect_matching_rowids(&tree, entry.columns, stmt.table, "", stmt.where_expr, span)
	if has_error(cerr) {
		return {}, finish_write_error(s, e, started, cerr, span)
	}
	defer delete(rowids)

	for rowid in rowids {
		if len(idx_refs) > 0 {
			old_payload, gerr := engine.table_get_row(&tree, rowid)
			if gerr != .None {
				return {}, finish_write_error(s, e, started, from_engine_error(gerr, span), span)
			}
			old_vals, derr := decode_heap_row(old_payload)
			delete(old_payload)
			if has_error(derr) {
				return {}, finish_write_error(s, e, started, derr, span)
			}
			merr := index_delete_for_row(e, idx_refs, entry.columns, old_vals, rowid, span)
			free_values(old_vals)
			if has_error(merr) {
				return {}, finish_write_error(s, e, started, merr, span)
			}
		}
		derr := engine.table_delete_row(&tree, rowid)
		if derr != .None {
			return {}, finish_write_error(s, e, started, from_engine_error(derr, span), span)
		}
	}

	if cerr := stmt_write_commit(s, e, started, span); has_error(cerr) {
		return {}, cerr
	}
	return rows_affected_result(len(rowids)), ok_error()
}

// exec_update runs UPDATE t SET … [WHERE …] (seq scan + row rewrite).
exec_update :: proc(s: ^Exec_Session, stmt: sql.Update_Stmt, span: sql.Span) -> (Exec_Result, Exec_Error) {
	e := session_engine(s)
	if e == nil {
		return {}, error_at(.Closed, "session is closed", span)
	}
	if stmt.table == "" {
		return {}, make_error(.Invalid_Schema, "UPDATE requires a table name", span = span)
	}
	if len(stmt.sets) == 0 {
		return {}, make_error(.Invalid_Schema, "UPDATE SET requires at least one assignment", span = span)
	}

	entry, gerr := engine.catalog_get_table_entry(e, stmt.table)
	if gerr == .Not_Found {
		return {}, make_error(.Unknown_Table, "no such table: %q", stmt.table, span = span)
	}
	if gerr != .None {
		return {}, from_engine_error(gerr, span)
	}
	defer engine.free_catalog_entry(entry)

	if len(entry.columns) == 0 {
		return {}, make_error(.Invalid_Schema, "table %q has no columns", stmt.table, span = span)
	}

	assigns, aerr := bind_update_assignments(stmt.sets, entry.columns)
	if has_error(aerr) {
		return {}, aerr
	}
	defer delete(assigns)

	ipk_idx := find_ipk_column(entry.columns)
	for a in assigns {
		if a.col_idx == ipk_idx && ipk_idx >= 0 {
			return {}, make_error(
				.Unsupported_Ast,
				"updating INTEGER PRIMARY KEY (rowid) is not supported yet",
				span = span,
			)
		}
	}

	if verr := validate_mutate_where(stmt.where_expr, entry.columns, stmt.table); has_error(verr) {
		return {}, verr
	}
	if verr := validate_update_set_exprs(assigns, entry.columns, stmt.table); has_error(verr) {
		return {}, verr
	}

	started, btxn := stmt_write_begin(s, e, span)
	if has_error(btxn) {
		return {}, btxn
	}

	idx_refs, ixerr := table_indexes_maintained(e, stmt.table, span)
	if has_error(ixerr) {
		return {}, finish_write_error(s, e, started, ixerr, span)
	}
	defer engine.free_catalog_index_refs(idx_refs)

	tree, oerr := engine.catalog_open_table(e, stmt.table)
	if oerr != .None {
		return {}, finish_write_error(s, e, started, from_engine_error(oerr, span), span)
	}

	pending, perr := collect_update_rewrites(
		&tree,
		entry.columns,
		stmt.table,
		assigns,
		stmt.where_expr,
		span,
	)
	if has_error(perr) {
		return {}, finish_write_error(s, e, started, perr, span)
	}
	defer free_pending_rewrites(pending)

	for item in pending {
		if len(idx_refs) > 0 {
			old_vals, derr := decode_heap_row(item.old_payload)
			if has_error(derr) {
				return {}, finish_write_error(s, e, started, derr, span)
			}
			new_vals, nerr := decode_heap_row(item.payload)
			if has_error(nerr) {
				free_values(old_vals)
				return {}, finish_write_error(s, e, started, nerr, span)
			}
			merr := index_delete_for_row(e, idx_refs, entry.columns, old_vals, item.rowid, span)
			free_values(old_vals)
			if has_error(merr) {
				free_values(new_vals)
				return {}, finish_write_error(s, e, started, merr, span)
			}
			merr2 := index_insert_for_row(e, idx_refs, entry.columns, new_vals, item.rowid, span)
			free_values(new_vals)
			if has_error(merr2) {
				return {}, finish_write_error(s, e, started, merr2, span)
			}
		}
		rerr := engine.table_rewrite_row(&tree, item.rowid, item.payload)
		if rerr != .None {
			return {}, finish_write_error(s, e, started, from_engine_error(rerr, span), span)
		}
	}

	if cerr := stmt_write_commit(s, e, started, span); has_error(cerr) {
		return {}, cerr
	}
	return rows_affected_result(len(pending)), ok_error()
}

bind_update_assignments :: proc(
	sets: []sql.Assignment,
	columns: []engine.Catalog_Column,
	allocator := context.allocator,
) -> ([]Bound_Assign, Exec_Error) {
	out := make([]Bound_Assign, len(sets), allocator)
	for a, i in sets {
		idx := find_column_index(columns, a.column)
		if idx < 0 {
			delete(out, allocator)
			return nil, make_error(.Unknown_Column, "no such column: %q", a.column, span = a.span)
		}
		if a.value == nil {
			delete(out, allocator)
			return nil, make_error(.Unsupported_Ast, "missing SET expression", span = a.span)
		}
		out[i] = Bound_Assign{col_idx = idx, expr = a.value}
	}
	return out, ok_error()
}

validate_mutate_where :: proc(
	where_expr: ^sql.Expr,
	columns: []engine.Catalog_Column,
	table_name: string,
) -> Exec_Error {
	if where_expr == nil {
		return ok_error()
	}
	nulls := make([]Value, len(columns))
	defer delete(nulls)
	for i in 0 ..< len(nulls) {
		nulls[i] = value_null()
	}
	env := Row_Env{
		table   = table_name,
		columns = columns,
		values  = nulls,
	}
	v, err := eval_expr(where_expr, &env)
	free_value(v)
	return err
}

validate_update_set_exprs :: proc(
	assigns: []Bound_Assign,
	columns: []engine.Catalog_Column,
	table_name: string,
) -> Exec_Error {
	nulls := make([]Value, len(columns))
	defer delete(nulls)
	for i in 0 ..< len(nulls) {
		nulls[i] = value_null()
	}
	env := Row_Env{
		table   = table_name,
		columns = columns,
		values  = nulls,
	}
	for a in assigns {
		v, err := eval_expr(a.expr, &env)
		free_value(v)
		if has_error(err) {
			return err
		}
	}
	return ok_error()
}

collect_matching_rowids :: proc(
	tree: ^engine.Btree,
	columns: []engine.Catalog_Column,
	table_name, alias: string,
	where_expr: ^sql.Expr,
	span: sql.Span,
	allocator := context.allocator,
) -> ([]u64, Exec_Error) {
	out := make([dynamic]u64, 0, 16, allocator)

	cur := engine.btree_cursor_init(tree)
	defer engine.btree_cursor_close(&cur)

	start_key: [8]u8
	_ = engine.rowid_key(0, start_key[:])
	if serr := engine.btree_seek_ge(&cur, start_key[:]); serr != .None {
		delete(out)
		return nil, from_engine_error(serr, span)
	}

	env := Row_Env{
		table   = table_name,
		alias   = alias,
		columns = columns,
	}

	for engine.btree_cursor_valid(&cur) {
		key := engine.btree_cursor_key(&cur)
		rowid, kerr := engine.rowid_from_key(key)
		if kerr != .None {
			delete(out)
			return nil, from_engine_error(kerr, span)
		}

		payload := engine.btree_cursor_payload(&cur)
		vals, derr := decode_heap_row(payload)
		if has_error(derr) {
			delete(out)
			return nil, derr
		}

		env.values = vals
		keep := true
		if where_expr != nil {
			ok, werr := eval_expr_bool(where_expr, &env)
			if has_error(werr) {
				free_values(vals)
				delete(out)
				return nil, werr
			}
			keep = ok
		}
		free_values(vals)

		if keep {
			append(&out, rowid)
		}

		if nerr := engine.btree_next(&cur); nerr != .None {
			delete(out)
			return nil, from_engine_error(nerr, span)
		}
	}
	return out[:], ok_error()
}

Pending_Rewrite :: struct {
	rowid:       u64,
	old_payload: []u8, // owned; pre-SET heap bytes for index maintenance
	payload:     []u8, // owned; post-SET heap bytes
}

free_pending_rewrite_payloads :: proc(items: []Pending_Rewrite, allocator := context.allocator) {
	for item in items {
		if item.old_payload != nil {
			delete(item.old_payload, allocator)
		}
		if item.payload != nil {
			delete(item.payload, allocator)
		}
	}
}

free_pending_rewrites :: proc(items: []Pending_Rewrite, allocator := context.allocator) {
	free_pending_rewrite_payloads(items, allocator)
	delete(items, allocator)
}

collect_update_rewrites :: proc(
	tree: ^engine.Btree,
	columns: []engine.Catalog_Column,
	table_name: string,
	assigns: []Bound_Assign,
	where_expr: ^sql.Expr,
	span: sql.Span,
	allocator := context.allocator,
) -> ([]Pending_Rewrite, Exec_Error) {
	out := make([dynamic]Pending_Rewrite, 0, 16, allocator)

	cur := engine.btree_cursor_init(tree)
	defer engine.btree_cursor_close(&cur)

	start_key: [8]u8
	_ = engine.rowid_key(0, start_key[:])
	if serr := engine.btree_seek_ge(&cur, start_key[:]); serr != .None {
		delete(out)
		return nil, from_engine_error(serr, span)
	}

	env := Row_Env{
		table   = table_name,
		columns = columns,
	}

	for engine.btree_cursor_valid(&cur) {
		key := engine.btree_cursor_key(&cur)
		rowid, kerr := engine.rowid_from_key(key)
		if kerr != .None {
			free_pending_rewrite_payloads(out[:])
			delete(out)
			return nil, from_engine_error(kerr, span)
		}

		payload := engine.btree_cursor_payload(&cur)
		old_payload := make([]u8, len(payload), allocator)
		copy(old_payload, payload)

		vals, derr := decode_heap_row(payload)
		if has_error(derr) {
			delete(old_payload, allocator)
			free_pending_rewrite_payloads(out[:])
			delete(out)
			return nil, derr
		}

		env.values = vals
		keep := true
		if where_expr != nil {
			ok, werr := eval_expr_bool(where_expr, &env)
			if has_error(werr) {
				free_values(vals)
				delete(old_payload, allocator)
				free_pending_rewrite_payloads(out[:])
				delete(out)
				return nil, werr
			}
			keep = ok
		}

		if !keep {
			free_values(vals)
			delete(old_payload, allocator)
			if nerr := engine.btree_next(&cur); nerr != .None {
				free_pending_rewrite_payloads(out[:])
				delete(out)
				return nil, from_engine_error(nerr, span)
			}
			continue
		}

		// Apply SET left-to-right; later assignments see earlier updates.
		for a in assigns {
			new_v, eerr := eval_expr(a.expr, &env)
			if has_error(eerr) {
				free_value(new_v)
				free_values(vals)
				delete(old_payload, allocator)
				free_pending_rewrite_payloads(out[:])
				delete(out)
				return nil, eerr
			}
			free_value(vals[a.col_idx])
			vals[a.col_idx] = new_v
		}

		for c, i in columns {
			if .Not_Null in c.flags && vals[i].kind == .Null {
				free_values(vals)
				delete(old_payload, allocator)
				free_pending_rewrite_payloads(out[:])
				delete(out)
				return nil, make_error(
					.Constraint,
					"NOT NULL constraint failed: %s",
					c.name,
					span = span,
				)
			}
		}

		new_payload, enc_err := encode_heap_row(vals)
		free_values(vals)
		if has_error(enc_err) {
			delete(old_payload, allocator)
			free_pending_rewrite_payloads(out[:])
			delete(out)
			return nil, enc_err
		}
		append(&out, Pending_Rewrite{rowid = rowid, old_payload = old_payload, payload = new_payload})

		if nerr := engine.btree_next(&cur); nerr != .None {
			free_pending_rewrite_payloads(out[:])
			delete(out)
			return nil, from_engine_error(nerr, span)
		}
	}
	return out[:], ok_error()
}
