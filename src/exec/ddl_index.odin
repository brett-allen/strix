package exec

import engine "../engine"
import sql "../sql"

bind_create_index_columns :: proc(
	stmt: sql.Create_Index_Stmt,
	table_columns: []engine.Catalog_Column,
	allocator := context.allocator,
) -> ([]engine.Catalog_Column, Exec_Error) {
	if len(stmt.columns) == 0 {
		return nil, make_error(.Invalid_Schema, "CREATE INDEX requires at least one column")
	}
	out := make([]engine.Catalog_Column, len(stmt.columns), allocator)
	for ic, i in stmt.columns {
		idx := find_column_index(table_columns, ic.name)
		if idx < 0 {
			delete(out, allocator)
			return nil, make_error(.Unknown_Column, "no such column: %q", ic.name)
		}
		// Store table column's canonical name; DESC flag for catalog only.
		flags: bit_set[engine.Catalog_Column_Flag; u8]
		if ic.desc {
			flags += {.Desc}
		}
		out[i] = engine.Catalog_Column{
			name  = table_columns[idx].name,
			flags = flags,
		}
		for j in 0 ..< i {
			if out[j].name == out[i].name {
				delete(out, allocator)
				return nil, make_error(.Invalid_Schema, "duplicate column in CREATE INDEX: %q", out[i].name)
			}
		}
	}
	return out, ok_error()
}

backfill_index :: proc(
	e: ^engine.Engine,
	index_name: string,
	table_name: string,
	table_columns: []engine.Catalog_Column,
	index_columns: []engine.Catalog_Column,
	span: sql.Span,
) -> Exec_Error {
	tbl, terr := engine.catalog_open_table(e, table_name)
	if terr != .None {
		return from_engine_error(terr, span)
	}
	idx, ierr := engine.catalog_open_index(e, index_name)
	if ierr != .None {
		return from_engine_error(ierr, span)
	}

	cur := engine.btree_cursor_init(&tbl)
	defer engine.btree_cursor_close(&cur)
	start_key: [8]u8
	_ = engine.rowid_key(0, start_key[:])
	if serr := engine.btree_seek_ge(&cur, start_key[:]); serr != .None {
		return from_engine_error(serr, span)
	}

	for engine.btree_cursor_valid(&cur) {
		key := engine.btree_cursor_key(&cur)
		rowid, kerr := engine.rowid_from_key(key)
		if kerr != .None {
			return from_engine_error(kerr, span)
		}
		payload := engine.btree_cursor_payload(&cur)
		vals, derr := decode_heap_row(payload)
		if has_error(derr) {
			return derr
		}
		ikey, enc_err := encode_index_key_from_row(vals, table_columns, index_columns)
		free_values(vals)
		if has_error(enc_err) {
			return enc_err
		}
		ins := engine.index_insert_entry(&idx, ikey, rowid)
		delete(ikey)
		if ins != .None {
			return from_engine_error(ins, span)
		}
		if nerr := engine.btree_next(&cur); nerr != .None {
			return from_engine_error(nerr, span)
		}
	}
	return ok_error()
}

exec_create_index :: proc(s: ^Exec_Session, stmt: sql.Create_Index_Stmt, span: sql.Span) -> (Exec_Result, Exec_Error) {
	e := session_engine(s)
	if e == nil {
		return {}, error_at(.Closed, "session is closed", span)
	}
	if stmt.name == "" {
		return {}, make_error(.Invalid_Schema, "CREATE INDEX requires an index name", span = span)
	}
	if stmt.table_name == "" {
		return {}, make_error(.Invalid_Schema, "CREATE INDEX requires a table name", span = span)
	}

	entry, gerr := engine.catalog_get_table_entry(e, stmt.table_name)
	if gerr == .Not_Found {
		return {}, make_error(.Unknown_Table, "no such table: %q", stmt.table_name, span = span)
	}
	if gerr != .None {
		return {}, from_engine_error(gerr, span)
	}
	defer engine.free_catalog_entry(entry)

	if len(entry.columns) == 0 {
		return {}, make_error(.Invalid_Schema, "table %q has no columns", stmt.table_name, span = span)
	}

	idx_cols, berr := bind_create_index_columns(stmt, entry.columns)
	if has_error(berr) {
		berr.span = span
		return {}, berr
	}
	defer delete(idx_cols)

	started, btxn := stmt_write_begin(s, e, span)
	if has_error(btxn) {
		return {}, btxn
	}

	_, rerr := engine.catalog_register_index(e, stmt.name, stmt.table_name, idx_cols)
	if rerr == .Exists {
		if stmt.if_not_exists {
			if started {
				_ = engine.txn_rollback(e)
			}
			return ok_result(), ok_error()
		}
		stmt_write_abort(s, e, started)
		return {}, make_error(.Index_Exists, "index %q already exists", stmt.name, span = span)
	}
	if rerr == .Not_Found {
		stmt_write_abort(s, e, started)
		return {}, make_error(.Unknown_Table, "no such table: %q", stmt.table_name, span = span)
	}
	if rerr != .None {
		stmt_write_abort(s, e, started)
		return {}, from_engine_error(rerr, span)
	}

	if ferr := backfill_index(e, stmt.name, stmt.table_name, entry.columns, idx_cols, span); has_error(ferr) {
		stmt_write_abort(s, e, started)
		return {}, ferr
	}

	if cerr := stmt_write_commit(s, e, started, span); has_error(cerr) {
		return {}, cerr
	}
	return ok_result(), ok_error()
}

exec_drop_index :: proc(s: ^Exec_Session, stmt: sql.Drop_Index_Stmt, span: sql.Span) -> (Exec_Result, Exec_Error) {
	e := session_engine(s)
	if e == nil {
		return {}, error_at(.Closed, "session is closed", span)
	}
	if stmt.name == "" {
		return {}, make_error(.Invalid_Schema, "DROP INDEX requires an index name", span = span)
	}

	started, btxn := stmt_write_begin(s, e, span)
	if has_error(btxn) {
		return {}, btxn
	}

	uerr := engine.catalog_unregister_index(e, stmt.name)
	if uerr == .Not_Found {
		if stmt.if_exists {
			if started {
				_ = engine.txn_rollback(e)
			}
			return ok_result(), ok_error()
		}
		stmt_write_abort(s, e, started)
		return {}, make_error(.Unknown_Index, "no such index: %q", stmt.name, span = span)
	}
	if uerr != .None {
		stmt_write_abort(s, e, started)
		return {}, from_engine_error(uerr, span)
	}

	if cerr := stmt_write_commit(s, e, started, span); has_error(cerr) {
		return {}, cerr
	}
	return ok_result(), ok_error()
}
