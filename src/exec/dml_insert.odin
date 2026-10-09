package exec

import "core:strings"
import engine "../engine"
import sql "../sql"

// IPK type name: exact equal_fold match on INTEGER or INT only (no INTEGER(n), BIGINT, etc.).
is_ipk_type_name :: proc(type_name: string) -> bool {
	return strings.equal_fold(type_name, "INTEGER") || strings.equal_fold(type_name, "INT")
}

count_primary_key_columns :: proc(columns: []engine.Catalog_Column) -> int {
	n := 0
	for c in columns {
		if .Primary_Key in c.flags {
			n += 1
		}
	}
	return n
}

// is_integer_primary_key reports whether a column is marked PK with an IPK type name.
// Callers that need rowid-alias behavior must use find_ipk_column (sole PK required).
is_integer_primary_key :: proc(col: engine.Catalog_Column) -> bool {
	if .Primary_Key not_in col.flags {
		return false
	}
	return is_ipk_type_name(col.type_name)
}

// type_name_base strips parameters / trailing words for declared-type matching.
// "VARCHAR(10)" → "VARCHAR"; "DOUBLE PRECISION" → "DOUBLE"; "CHARACTER VARYING" → "CHARACTER".
type_name_base :: proc(type_name: string) -> string {
	base := strings.trim_space(type_name)
	if paren := strings.index_byte(base, '('); paren >= 0 {
		base = strings.trim_space(base[:paren])
	}
	if sp := strings.index_byte(base, ' '); sp >= 0 {
		first := base[:sp]
		if strings.equal_fold(first, "DOUBLE") ||
		   strings.equal_fold(first, "CHARACTER") ||
		   strings.equal_fold(first, "CHAR") {
			return first
		}
	}
	return base
}

// declared_storage_kind maps a recognized column type name to the Value_Kind that
// may be stored. enforced=false means empty/unknown type → no kind check (no affinity).
declared_storage_kind :: proc(type_name: string) -> (kind: Value_Kind, enforced: bool) {
	if type_name == "" {
		return {}, false
	}
	base := type_name_base(type_name)
	if strings.equal_fold(base, "INTEGER") || strings.equal_fold(base, "INT") {
		return .Integer, true
	}
	if strings.equal_fold(base, "REAL") ||
	   strings.equal_fold(base, "FLOAT") ||
	   strings.equal_fold(base, "DOUBLE") {
		return .Float, true
	}
	if strings.equal_fold(base, "TEXT") ||
	   strings.equal_fold(base, "VARCHAR") ||
	   strings.equal_fold(base, "CHAR") ||
	   strings.equal_fold(base, "CHARACTER") ||
	   strings.equal_fold(base, "CLOB") ||
	   strings.equal_fold(base, "NVARCHAR") {
		return .Text, true
	}
	if strings.equal_fold(base, "BLOB") {
		return .Blob, true
	}
	return {}, false
}

// check_value_matches_column_type rejects bound kinds that disagree with a recognized
// declared type. NULL is always allowed here (NOT NULL is separate). No soft coerce / affinity.
check_value_matches_column_type :: proc(col: engine.Catalog_Column, v: Value) -> Exec_Error {
	if v.kind == .Null {
		return ok_error()
	}
	expected, enforced := declared_storage_kind(col.type_name)
	if !enforced {
		return ok_error()
	}
	if v.kind == expected {
		return ok_error()
	}
	return make_error(
		.Constraint,
		"type mismatch for column %s: declared %s requires %v, got %v",
		col.name,
		col.type_name,
		expected,
		v.kind,
	)
}

// find_ipk_column returns the sole INTEGER/INT PRIMARY KEY column index, or -1.
// Composite / multi-column PK and non-IPK PK types never alias rowid.
find_ipk_column :: proc(columns: []engine.Catalog_Column) -> int {
	if count_primary_key_columns(columns) != 1 {
		return -1
	}
	for c, i in columns {
		if is_integer_primary_key(c) {
			return i
		}
	}
	return -1
}

// validate_primary_key_shape rejects unsupported PK forms until UNIQUE enforcement exists.
// Allowed: zero PK columns, or exactly one PK column whose type is INTEGER/INT (IPK rowid alias).
validate_primary_key_shape :: proc(columns: []engine.Catalog_Column) -> Exec_Error {
	pk_count := 0
	pk_idx := -1
	for c, i in columns {
		if .Primary_Key in c.flags {
			pk_count += 1
			pk_idx = i
		}
	}
	if pk_count == 0 {
		return ok_error()
	}
	if pk_count > 1 {
		return make_error(
			.Unsupported_Ast,
			"composite PRIMARY KEY is not supported yet",
		)
	}
	if !is_ipk_type_name(columns[pk_idx].type_name) {
		return make_error(
			.Unsupported_Ast,
			"PRIMARY KEY column type must be INTEGER or INT until UNIQUE enforcement exists (got %q)",
			columns[pk_idx].type_name,
		)
	}
	return ok_error()
}

catalog_default_to_value :: proc(
	col: engine.Catalog_Column,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	if .Has_Default not_in col.flags {
		return {}, error_at(.Constraint, "column has no default")
	}
	switch col.default_kind {
	case .None:
		return {}, error_at(.Constraint, "column has no default")
	case .Null:
		return value_null(), ok_error()
	case .Integer:
		return value_integer(col.default_i), ok_error()
	case .Float:
		return value_float(col.default_f), ok_error()
	case .Text:
		return value_text(col.default_bytes, allocator), ok_error()
	case .Blob:
		return value_blob(transmute([]u8)col.default_bytes, allocator), ok_error()
	}
	return {}, error_at(.Constraint, "column has no default")
}

// resolve_omitted_column fills a column not listed in INSERT column list.
// is_ipk is true only for the sole INTEGER/INT PRIMARY KEY column (rowid alias).
resolve_omitted_column :: proc(
	col: engine.Catalog_Column,
	is_ipk: bool,
	allocator := context.allocator,
) -> (Value, Exec_Error) {
	if .Has_Default in col.flags {
		return catalog_default_to_value(col, allocator)
	}
	if .Not_Null in col.flags && !is_ipk {
		return {}, make_error(
			.Constraint,
			"NOT NULL constraint failed: %s",
			col.name,
		)
	}
	// Nullable (or IPK auto rowid) → NULL placeholder; IPK NULL triggers allocation later.
	return value_null(), ok_error()
}

bind_insert_column_map :: proc(
	stmt: sql.Insert_Stmt,
	columns: []engine.Catalog_Column,
) -> (col_map: []int, err: Exec_Error) {
	ncol := len(columns)
	if len(stmt.columns) == 0 {
		// Implicit: VALUES must match table column order/count (checked per row).
		m := make([]int, ncol)
		for i in 0 ..< ncol {
			m[i] = i
		}
		return m, ok_error()
	}
	m := make([]int, len(stmt.columns))
	seen := make([]bool, ncol)
	defer delete(seen)
	for name, i in stmt.columns {
		found := find_column_index(columns, name)
		if found < 0 {
			delete(m)
			return nil, make_error(.Unknown_Column, "no such column: %q", name)
		}
		if seen[found] {
			delete(m)
			return nil, make_error(.Invalid_Schema, "duplicate column in INSERT: %q", name)
		}
		seen[found] = true
		m[i] = found
	}
	return m, ok_error()
}

build_insert_row_values :: proc(
	stmt: sql.Insert_Stmt,
	row_exprs: []^sql.Expr,
	columns: []engine.Catalog_Column,
	col_map: []int,
	allocator := context.allocator,
) -> ([]Value, Exec_Error) {
	ncol := len(columns)
	named := len(stmt.columns) > 0

	if named {
		if len(row_exprs) != len(col_map) {
			return nil, make_error(
				.Invalid_Schema,
				"INSERT value count %d does not match column count %d",
				len(row_exprs),
				len(col_map),
			)
		}
	} else {
		if len(row_exprs) != ncol {
			return nil, make_error(
				.Invalid_Schema,
				"INSERT value count %d does not match table column count %d",
				len(row_exprs),
				ncol,
			)
		}
	}

	vals := make([]Value, ncol, allocator)
	filled := make([]bool, ncol)
	defer delete(filled)
	ipk := find_ipk_column(columns)

	for expr, i in row_exprs {
		target := col_map[i]
		v, err := eval_literal_expr(expr, allocator)
		if has_error(err) {
			free_values(vals, allocator)
			return nil, err
		}
		vals[target] = v
		filled[target] = true
	}

	for i in 0 ..< ncol {
		if filled[i] {
			continue
		}
		v, err := resolve_omitted_column(columns[i], i == ipk, allocator)
		if has_error(err) {
			free_values(vals, allocator)
			return nil, err
		}
		vals[i] = v
	}

	// Declared-type kind check (no affinity / soft coerce). Untyped / unknown types skipped.
	for i in 0 ..< ncol {
		if cerr := check_value_matches_column_type(columns[i], vals[i]); has_error(cerr) {
			free_values(vals, allocator)
			return nil, cerr
		}
	}

	// NOT NULL on provided NULLs (except sole IPK NULL → autoallocate).
	for i in 0 ..< ncol {
		if vals[i].kind != .Null {
			continue
		}
		if i == ipk {
			continue
		}
		if .Not_Null in columns[i].flags {
			free_values(vals, allocator)
			return nil, make_error(
				.Constraint,
				"NOT NULL constraint failed: %s",
				columns[i].name,
			)
		}
	}
	return vals, ok_error()
}

allocate_rowid :: proc(
	vals: []Value,
	columns: []engine.Catalog_Column,
	next_rowid: ^u64,
) -> (rowid: u64, err: Exec_Error) {
	ipk := find_ipk_column(columns)
	if ipk >= 0 {
		v := vals[ipk]
		if v.kind == .Null {
			rowid = next_rowid^
			next_rowid^ += 1
			vals[ipk] = value_integer(i64(rowid))
			return rowid, ok_error()
		}
		if v.kind != .Integer {
			return 0, make_error(
				.Constraint,
				"INTEGER PRIMARY KEY must be an integer",
			)
		}
		if v.i < 0 {
			return 0, make_error(.Constraint, "INTEGER PRIMARY KEY must be non-negative")
		}
		rowid = u64(v.i)
		if rowid >= next_rowid^ {
			next_rowid^ = rowid + 1
		}
		return rowid, ok_error()
	}
	rowid = next_rowid^
	next_rowid^ += 1
	return rowid, ok_error()
}

exec_insert :: proc(s: ^Exec_Session, stmt: sql.Insert_Stmt, span: sql.Span) -> (Exec_Result, Exec_Error) {
	e := session_engine(s)
	if e == nil {
		return {}, error_at(.Closed, "session is closed", span)
	}

	if stmt.conflict != .None {
		return {}, make_error(
			.Unsupported_Ast,
			"INSERT OR %v is not supported",
			stmt.conflict,
			span = span,
		)
	}
	if stmt.source != .Values {
		return {}, make_error(
			.Unsupported_Ast,
			"INSERT … SELECT is not supported yet",
			span = span,
		)
	}
	if len(stmt.rows) == 0 {
		return {}, make_error(.Invalid_Schema, "INSERT VALUES requires at least one row", span = span)
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

	if pkerr := validate_primary_key_shape(entry.columns); has_error(pkerr) {
		pkerr.span = span
		return {}, pkerr
	}

	col_map, merr := bind_insert_column_map(stmt, entry.columns)
	if has_error(merr) {
		merr.span = span
		return {}, merr
	}
	defer delete(col_map)

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

	next_rowid := entry.next_rowid
	if next_rowid == 0 {
		next_rowid = 1
	}
	initial_next := next_rowid
	rows_affected := 0

	for row_exprs in stmt.rows {
		vals, berr := build_insert_row_values(stmt, row_exprs, entry.columns, col_map)
		if has_error(berr) {
			return {}, finish_write_error(s, e, started, berr, span)
		}

		rowid, rerr := allocate_rowid(vals, entry.columns, &next_rowid)
		if has_error(rerr) {
			free_values(vals)
			return {}, finish_write_error(s, e, started, rerr, span)
		}

		payload, enc_err := encode_heap_row(vals)
		if has_error(enc_err) {
			free_values(vals)
			return {}, finish_write_error(s, e, started, enc_err, span)
		}

		ierr := engine.table_insert_row(&tree, rowid, payload)
		delete(payload)
		if ierr == .Exists {
			free_values(vals)
			return {}, finish_write_error(
				s,
				e,
				started,
				make_error(
					.Constraint,
					"UNIQUE / PRIMARY KEY constraint failed: rowid %v",
					rowid,
					span = span,
				),
				span,
			)
		}
		if ierr != .None {
			free_values(vals)
			return {}, finish_write_error(s, e, started, from_engine_error(ierr, span), span)
		}

		if len(idx_refs) > 0 {
			if merr := index_insert_for_row(e, idx_refs, entry.columns, vals, rowid, span); has_error(merr) {
				free_values(vals)
				return {}, finish_write_error(s, e, started, merr, span)
			}
		}
		free_values(vals)
		rows_affected += 1
	}

	if next_rowid != initial_next {
		if uerr := engine.catalog_update_next_rowid(e, stmt.table, next_rowid); uerr != .None {
			return {}, finish_write_error(s, e, started, from_engine_error(uerr, span), span)
		}
	}

	if cerr := stmt_write_commit(s, e, started, span); has_error(cerr) {
		return {}, cerr
	}
	return rows_affected_result(rows_affected), ok_error()
}
