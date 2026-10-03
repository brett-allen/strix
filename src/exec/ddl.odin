package exec

import engine "../engine"
import sql "../sql"

column_from_def :: proc(col: sql.Column_Def) -> (engine.Catalog_Column, Exec_Error) {
	flags: bit_set[engine.Catalog_Column_Flag; u8]
	for c in col.constraints {
		#partial switch c.kind {
		case .Primary_Key:
			flags += {.Primary_Key}
		case .Not_Null:
			flags += {.Not_Null}
		case .Unique, .Default, .Check, .References:
			return {}, make_error(
				.Unsupported_Ast,
				"column constraint %v is not supported yet",
				c.kind,
				span = c.span,
			)
		}
	}
	return engine.Catalog_Column{
		name      = col.name,
		type_name = col.type_name,
		flags     = flags,
	}, ok_error()
}

bind_create_table_columns :: proc(
	stmt: sql.Create_Table_Stmt,
	allocator := context.allocator,
) -> ([]engine.Catalog_Column, Exec_Error) {
	cols := make([dynamic]engine.Catalog_Column, 0, len(stmt.elements), allocator)
	pk_from_table: [dynamic]string
	defer delete(pk_from_table)

	for el in stmt.elements {
		switch el.kind {
		case .Column:
			col, err := column_from_def(el.column)
			if has_error(err) {
				delete(cols)
				return nil, err
			}
			append(&cols, col)
		case .Table_Constraint:
			#partial switch el.table_constraint.kind {
			case .Primary_Key:
				for name in el.table_constraint.columns {
					append(&pk_from_table, name)
				}
			case:
				delete(cols)
				return nil, make_error(
					.Unsupported_Ast,
					"table constraint %v is not supported yet",
					el.table_constraint.kind,
					span = el.table_constraint.span,
				)
			}
		}
	}

	if len(cols) == 0 {
		delete(cols)
		return nil, error_at(.Invalid_Schema, "CREATE TABLE requires at least one column")
	}

	// Apply table-level PRIMARY KEY to matching columns.
	for pk_name in pk_from_table {
		found := false
		for &c in cols {
			if c.name == pk_name {
				c.flags += {.Primary_Key}
				found = true
				break
			}
		}
		if !found {
			delete(cols)
			return nil, make_error(
				.Invalid_Schema,
				"PRIMARY KEY column %q not found",
				pk_name,
			)
		}
	}

	// Duplicate column names
	for i in 0 ..< len(cols) {
		for j in i + 1 ..< len(cols) {
			if cols[i].name == cols[j].name {
				name := cols[i].name
				delete(cols)
				return nil, make_error(.Invalid_Schema, "duplicate column name %q", name)
			}
		}
	}

	return cols[:], ok_error()
}

exec_create_table :: proc(s: ^Exec_Session, stmt: sql.Create_Table_Stmt, span: sql.Span) -> (Exec_Result, Exec_Error) {
	e := session_engine(s)
	if e == nil {
		return {}, error_at(.Closed, "session is closed", span)
	}

	columns, berr := bind_create_table_columns(stmt)
	if has_error(berr) {
		return {}, berr
	}
	defer delete(columns)

	if err := engine.txn_begin(e); err != .None {
		return {}, from_engine_error(err, span)
	}

	_, rerr := engine.catalog_register_table(e, stmt.name, columns)
	if rerr == .Exists {
		_ = engine.txn_rollback(e)
		if stmt.if_not_exists {
			return ok_result(), ok_error()
		}
		return {}, make_error(.Table_Exists, "table %q already exists", stmt.name, span = span)
	}
	if rerr != .None {
		_ = engine.txn_rollback(e)
		return {}, from_engine_error(rerr, span)
	}

	if cerr := engine.txn_commit(e); cerr != .None {
		_ = engine.txn_rollback(e)
		return {}, from_engine_error(cerr, span)
	}
	return ok_result(), ok_error()
}

exec_drop_table :: proc(s: ^Exec_Session, stmt: sql.Drop_Table_Stmt, span: sql.Span) -> (Exec_Result, Exec_Error) {
	e := session_engine(s)
	if e == nil {
		return {}, error_at(.Closed, "session is closed", span)
	}

	if err := engine.txn_begin(e); err != .None {
		return {}, from_engine_error(err, span)
	}

	uerr := engine.catalog_unregister_table(e, stmt.name)
	if uerr == .Not_Found {
		_ = engine.txn_rollback(e)
		if stmt.if_exists {
			return ok_result(), ok_error()
		}
		return {}, make_error(.Unknown_Table, "no such table: %q", stmt.name, span = span)
	}
	if uerr == .Has_Indexes {
		_ = engine.txn_rollback(e)
		return {}, make_error(
			.Has_Indexes,
			"cannot DROP TABLE %q: indexes still exist (drop indexes first)",
			stmt.name,
			span = span,
		)
	}
	if uerr != .None {
		_ = engine.txn_rollback(e)
		return {}, from_engine_error(uerr, span)
	}

	if cerr := engine.txn_commit(e); cerr != .None {
		_ = engine.txn_rollback(e)
		return {}, from_engine_error(cerr, span)
	}
	return ok_result(), ok_error()
}
