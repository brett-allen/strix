package exec

import "core:strings"
import engine "../engine"
import sql "../sql"

column_from_def :: proc(col: sql.Column_Def) -> (engine.Catalog_Column, Exec_Error) {
	flags: bit_set[engine.Catalog_Column_Flag; u8]
	out := engine.Catalog_Column{
		name      = col.name,
		type_name = col.type_name,
	}
	for c in col.constraints {
		#partial switch c.kind {
		case .Primary_Key:
			flags += {.Primary_Key}
		case .Not_Null:
			flags += {.Not_Null}
		case .Default:
			def_val, derr := eval_literal_expr(c.default_expr)
			if has_error(derr) {
				free_error(derr)
				return {}, make_error(
					.Unsupported_Ast,
					"column DEFAULT must be a literal or NULL",
					span = c.span,
				)
			}
			flags += {.Has_Default}
			switch def_val.kind {
			case .Null:
				out.default_kind = .Null
			case .Integer:
				out.default_kind = .Integer
				out.default_i = def_val.i
			case .Float:
				out.default_kind = .Float
				out.default_f = def_val.f
			case .Text:
				out.default_kind = .Text
				out.default_bytes = string(def_val.bytes) // owned; Catalog_Column takes ownership
				def_val.bytes = nil
			case .Blob:
				out.default_kind = .Blob
				out.default_bytes = string(def_val.bytes)
				def_val.bytes = nil
			}
			free_value(def_val)
		case .Unique, .Check, .References:
			return {}, make_error(
				.Unsupported_Ast,
				"column constraint %v is not supported yet",
				c.kind,
				span = c.span,
			)
		}
	}
	out.flags = flags
	return out, ok_error()
}

free_bound_columns :: proc(cols: []engine.Catalog_Column, allocator := context.allocator) {
	for c in cols {
		if c.default_bytes != "" {
			delete(c.default_bytes, allocator)
		}
	}
	if cols != nil {
		delete(cols, allocator)
	}
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
				free_bound_columns(cols[:], allocator)
				return nil, err
			}
			append(&cols, col)
		case .Table_Constraint:
			#partial switch el.table_constraint.kind {
			case .Primary_Key:
				if len(el.table_constraint.columns) > 1 {
					free_bound_columns(cols[:], allocator)
					return nil, make_error(
						.Unsupported_Ast,
						"composite PRIMARY KEY is not supported yet",
						span = el.table_constraint.span,
					)
				}
				for name in el.table_constraint.columns {
					append(&pk_from_table, name)
				}
			case:
				free_bound_columns(cols[:], allocator)
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
		free_bound_columns(cols[:], allocator)
		return nil, error_at(.Invalid_Schema, "CREATE TABLE requires at least one column")
	}

	// Apply table-level PRIMARY KEY to matching columns (case-insensitive).
	for pk_name in pk_from_table {
		found := false
		for &c in cols {
			if strings.equal_fold(c.name, pk_name) {
				c.flags += {.Primary_Key}
				found = true
				break
			}
		}
		if !found {
			free_bound_columns(cols[:], allocator)
			return nil, make_error(
				.Invalid_Schema,
				"PRIMARY KEY column %q not found",
				pk_name,
			)
		}
	}

	// Duplicate column names (case-insensitive; reject case-only duplicates).
	for i in 0 ..< len(cols) {
		for j in i + 1 ..< len(cols) {
			if strings.equal_fold(cols[i].name, cols[j].name) {
				name := cols[i].name
				free_bound_columns(cols[:], allocator)
				return nil, make_error(.Invalid_Schema, "duplicate column name %q", name)
			}
		}
	}

	// Reject unsupported PK shapes before cataloguing (no silent decorative PRIMARY KEY).
	if pkerr := validate_primary_key_shape(cols[:]); has_error(pkerr) {
		free_bound_columns(cols[:], allocator)
		return nil, pkerr
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
	defer free_bound_columns(columns)

	started, btxn := stmt_write_begin(s, e, span)
	if has_error(btxn) {
		return {}, btxn
	}

	_, rerr := engine.catalog_register_table(e, stmt.name, columns)
	if rerr == .Exists {
		if stmt.if_not_exists {
			// Soft success: only unwind an auto-commit txn; keep explicit txn open.
			if started {
				_ = engine.txn_rollback(e)
			}
			return ok_result(), ok_error()
		}
		stmt_write_abort(s, e, started)
		return {}, make_error(.Table_Exists, "table %q already exists", stmt.name, span = span)
	}
	if rerr != .None {
		stmt_write_abort(s, e, started)
		return {}, from_engine_error(rerr, span)
	}

	if cerr := stmt_write_commit(s, e, started, span); has_error(cerr) {
		return {}, cerr
	}
	return ok_result(), ok_error()
}

exec_drop_table :: proc(s: ^Exec_Session, stmt: sql.Drop_Table_Stmt, span: sql.Span) -> (Exec_Result, Exec_Error) {
	e := session_engine(s)
	if e == nil {
		return {}, error_at(.Closed, "session is closed", span)
	}

	started, btxn := stmt_write_begin(s, e, span)
	if has_error(btxn) {
		return {}, btxn
	}

	uerr := engine.catalog_unregister_table(e, stmt.name)
	if uerr == .Not_Found {
		if stmt.if_exists {
			if started {
				_ = engine.txn_rollback(e)
			}
			return ok_result(), ok_error()
		}
		stmt_write_abort(s, e, started)
		return {}, make_error(.Unknown_Table, "no such table: %q", stmt.name, span = span)
	}
	if uerr == .Has_Indexes {
		stmt_write_abort(s, e, started)
		return {}, make_error(
			.Has_Indexes,
			"cannot DROP TABLE %q: indexes still exist (drop indexes first)",
			stmt.name,
			span = span,
		)
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
