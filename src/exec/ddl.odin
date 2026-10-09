package exec

import "core:fmt"
import "core:strings"
import engine "../engine"
import sql "../sql"

// System unique index names for PK / UNIQUE constraints: strix_autoindex_<table>_<n>
SYSTEM_AUTOINDEX_PREFIX :: "strix_autoindex_"

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
		case .Unique:
			flags += {.Unique}
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
			// Typed bind for DEFAULT: UUID string → Uuid; BOOLEAN TRUE/FALSE already Boolean.
			if cerr := coerce_value_for_column(
				engine.Catalog_Column{name = col.name, type_name = col.type_name},
				&def_val,
			); has_error(cerr) {
				free_value(def_val)
				return {}, cerr
			}
			switch def_val.kind {
			case .Null:
				out.default_kind = .Null
			case .Integer:
				out.default_kind = .Integer
				out.default_i = def_val.i
			case .Float:
				out.default_kind = .Float
				out.default_f = def_val.f
			case .Boolean:
				out.default_kind = .Boolean
				out.default_i = def_val.i
			case .Text:
				out.default_kind = .Text
				out.default_bytes = string(def_val.bytes) // owned; Catalog_Column takes ownership
				def_val.bytes = nil
			case .Blob:
				out.default_kind = .Blob
				out.default_bytes = string(def_val.bytes)
				def_val.bytes = nil
			case .Uuid:
				out.default_kind = .Uuid
				out.default_bytes = string(def_val.bytes)
				def_val.bytes = nil
			}
			free_value(def_val)
		case .Check, .References:
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

// Unique_Col_Set is a deferred unique-index column list (names only; owned strings optional).
Unique_Col_Set :: struct {
	names: []string, // borrowed from AST / column defs during bind
}

free_unique_col_sets :: proc(sets: []Unique_Col_Set, allocator := context.allocator) {
	for s in sets {
		if s.names != nil {
			delete(s.names, allocator)
		}
	}
	if sets != nil {
		delete(sets, allocator)
	}
}

unique_sets_equal :: proc(a, b: []string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if !strings.equal_fold(a[i], b[i]) {
			return false
		}
	}
	return true
}

append_unique_set_if_new :: proc(
	sets: ^[dynamic]Unique_Col_Set,
	names: []string,
	allocator := context.allocator,
) {
	for s in sets {
		if unique_sets_equal(s.names, names) {
			return
		}
	}
	cloned := make([]string, len(names), allocator)
	for n, i in names {
		cloned[i] = n
	}
	append(sets, Unique_Col_Set{names = cloned})
}

// collect_create_table_unique_sets builds unique index column sets for non-IPK PK and UNIQUE.
// pk_ordered is the PRIMARY KEY column list in constraint order (empty if no PK).
collect_create_table_unique_sets :: proc(
	cols: []engine.Catalog_Column,
	table_unique: []Unique_Col_Set,
	pk_ordered: []string,
	allocator := context.allocator,
) -> []Unique_Col_Set {
	out := make([dynamic]Unique_Col_Set, 0, 4, allocator)
	ipk := find_ipk_column(cols)

	// Non-IPK PRIMARY KEY (single-column or composite) → unique index.
	// Sole INTEGER/INT PK aliases rowid — no secondary unique index.
	if len(pk_ordered) > 0 && !(len(pk_ordered) == 1 && ipk >= 0) {
		append_unique_set_if_new(&out, pk_ordered, allocator)
	}

	// Column-level UNIQUE (skip IPK — rowid already enforces uniqueness).
	for c, i in cols {
		if .Unique in c.flags && i != ipk {
			append_unique_set_if_new(&out, []string{c.name}, allocator)
		}
	}

	// Table-level UNIQUE (…); already validated column names exist.
	// Skip sole-IPK sets (INTEGER PRIMARY KEY UNIQUE / UNIQUE (ipk_col)).
	for s in table_unique {
		if len(s.names) == 1 && ipk >= 0 && strings.equal_fold(s.names[0], cols[ipk].name) {
			continue
		}
		append_unique_set_if_new(&out, s.names, allocator)
	}

	return out[:]
}

system_autoindex_name :: proc(
	table_name: string,
	n: int,
	allocator := context.allocator,
) -> string {
	return fmt.aprintf("%s%s_%d", SYSTEM_AUTOINDEX_PREFIX, table_name, n, allocator = allocator)
}

is_system_autoindex_name :: proc(name: string) -> bool {
	pref := SYSTEM_AUTOINDEX_PREFIX
	if len(name) < len(pref) {
		return false
	}
	return strings.equal_fold(name[:len(pref)], pref)
}

bind_create_table_columns :: proc(
	stmt: sql.Create_Table_Stmt,
	allocator := context.allocator,
) -> ([]engine.Catalog_Column, []Unique_Col_Set, []string, Exec_Error) {
	cols := make([dynamic]engine.Catalog_Column, 0, len(stmt.elements), allocator)
	pk_from_table: [dynamic]string
	defer delete(pk_from_table)
	table_pk_span: sql.Span
	saw_table_pk := false
	table_unique := make([dynamic]Unique_Col_Set, 0, 2, allocator)

	for el in stmt.elements {
		switch el.kind {
		case .Column:
			col, err := column_from_def(el.column)
			if has_error(err) {
				free_bound_columns(cols[:], allocator)
				free_unique_col_sets(table_unique[:], allocator)
				return nil, nil, nil, err
			}
			append(&cols, col)
		case .Table_Constraint:
			#partial switch el.table_constraint.kind {
			case .Primary_Key:
				if saw_table_pk {
					free_bound_columns(cols[:], allocator)
					free_unique_col_sets(table_unique[:], allocator)
					return nil, nil, nil, make_error(
						.Invalid_Schema,
						"multiple PRIMARY KEY constraints",
						span = el.table_constraint.span,
					)
				}
				if len(el.table_constraint.columns) == 0 {
					free_bound_columns(cols[:], allocator)
					free_unique_col_sets(table_unique[:], allocator)
					return nil, nil, nil, make_error(
						.Invalid_Schema,
						"PRIMARY KEY requires at least one column",
						span = el.table_constraint.span,
					)
				}
				saw_table_pk = true
				table_pk_span = el.table_constraint.span
				for name in el.table_constraint.columns {
					append(&pk_from_table, name)
				}
			case .Unique:
				if len(el.table_constraint.columns) == 0 {
					free_bound_columns(cols[:], allocator)
					free_unique_col_sets(table_unique[:], allocator)
					return nil, nil, nil, make_error(
						.Invalid_Schema,
						"UNIQUE constraint requires at least one column",
						span = el.table_constraint.span,
					)
				}
				names := make([]string, len(el.table_constraint.columns), allocator)
				for n, i in el.table_constraint.columns {
					names[i] = n
				}
				append(&table_unique, Unique_Col_Set{names = names})
			case:
				free_bound_columns(cols[:], allocator)
				free_unique_col_sets(table_unique[:], allocator)
				return nil, nil, nil, make_error(
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
		free_unique_col_sets(table_unique[:], allocator)
		return nil, nil, nil, error_at(.Invalid_Schema, "CREATE TABLE requires at least one column")
	}

	// Reject column-level PK mixed with a different / composite table PRIMARY KEY.
	// Allowed: sole column `c PRIMARY KEY` with `PRIMARY KEY (c)` (same column).
	n_col_pk := 0
	sole_col_pk := ""
	for c in cols {
		if .Primary_Key in c.flags {
			n_col_pk += 1
			sole_col_pk = c.name
		}
	}
	if saw_table_pk && n_col_pk > 0 {
		same_sole :=
			n_col_pk == 1 &&
			len(pk_from_table) == 1 &&
			strings.equal_fold(sole_col_pk, pk_from_table[0])
		if !same_sole {
			free_bound_columns(cols[:], allocator)
			free_unique_col_sets(table_unique[:], allocator)
			return nil, nil, nil, make_error(
				.Invalid_Schema,
				"conflicting PRIMARY KEY constraints",
				span = table_pk_span,
			)
		}
	}

	// Apply table-level PRIMARY KEY to matching columns (case-insensitive).
	for i in 0 ..< len(pk_from_table) {
		pk_name := pk_from_table[i]
		for j in i + 1 ..< len(pk_from_table) {
			if strings.equal_fold(pk_name, pk_from_table[j]) {
				free_bound_columns(cols[:], allocator)
				free_unique_col_sets(table_unique[:], allocator)
				return nil, nil, nil, make_error(
					.Invalid_Schema,
					"duplicate column %q in PRIMARY KEY",
					pk_name,
					span = table_pk_span,
				)
			}
		}
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
			free_unique_col_sets(table_unique[:], allocator)
			return nil, nil, nil, make_error(
				.Invalid_Schema,
				"PRIMARY KEY column %q not found",
				pk_name,
			)
		}
	}

	// Resolve table-level UNIQUE column names; reject unknown.
	// Single-column table UNIQUE also sets column .Unique so .schema can emit
	// UNIQUE on the column (system autoindex stays hidden for single-col).
	for s in table_unique {
		for name in s.names {
			found := false
			for &c in cols {
				if strings.equal_fold(c.name, name) {
					if len(s.names) == 1 {
						c.flags += {.Unique}
					}
					found = true
					break
				}
			}
			if !found {
				free_bound_columns(cols[:], allocator)
				free_unique_col_sets(table_unique[:], allocator)
				return nil, nil, nil, make_error(
					.Invalid_Schema,
					"UNIQUE column %q not found",
					name,
				)
			}
		}
	}

	// PRIMARY KEY implies NOT NULL (including composite and non-IPK TEXT/UUID-style PKs).
	for &c in cols {
		if .Primary_Key in c.flags {
			c.flags += {.Not_Null}
		}
	}

	// Duplicate column names (case-insensitive; reject case-only duplicates).
	for i in 0 ..< len(cols) {
		for j in i + 1 ..< len(cols) {
			if strings.equal_fold(cols[i].name, cols[j].name) {
				name := cols[i].name
				free_bound_columns(cols[:], allocator)
				free_unique_col_sets(table_unique[:], allocator)
				return nil, nil, nil, make_error(.Invalid_Schema, "duplicate column name %q", name)
			}
		}
	}

	// Ordered PK column names: table constraint order, else table column order.
	pk_ordered: []string
	if len(pk_from_table) > 0 {
		pk_ordered = make([]string, len(pk_from_table), allocator)
		for n, i in pk_from_table {
			// Use catalog column name casing.
			for c in cols {
				if strings.equal_fold(c.name, n) {
					pk_ordered[i] = c.name
					break
				}
			}
		}
	} else {
		pk_count := count_primary_key_columns(cols[:])
		if pk_count > 0 {
			pk_ordered = make([]string, pk_count, allocator)
			j := 0
			for c in cols {
				if .Primary_Key in c.flags {
					pk_ordered[j] = c.name
					j += 1
				}
			}
		}
	}

	return cols[:], table_unique[:], pk_ordered, ok_error()
}

register_system_unique_indexes :: proc(
	e: ^engine.Engine,
	table_name: string,
	cols: []engine.Catalog_Column,
	table_unique: []Unique_Col_Set,
	pk_ordered: []string,
	span: sql.Span,
	allocator := context.allocator,
) -> Exec_Error {
	sets := collect_create_table_unique_sets(cols, table_unique, pk_ordered, allocator)
	defer free_unique_col_sets(sets, allocator)

	for s, i in sets {
		idx_cols := make([]engine.Catalog_Column, len(s.names), allocator)
		for name, j in s.names {
			found := -1
			for c, ci in cols {
				if strings.equal_fold(c.name, name) {
					found = ci
					break
				}
			}
			if found < 0 {
				delete(idx_cols, allocator)
				return make_error(.Invalid_Schema, "UNIQUE column %q not found", name, span = span)
			}
			idx_cols[j] = engine.Catalog_Column{name = cols[found].name}
		}
		iname := system_autoindex_name(table_name, i + 1, allocator)
		_, rerr := engine.catalog_register_index(e, iname, table_name, idx_cols, unique = true)
		delete(iname, allocator)
		delete(idx_cols, allocator)
		if rerr != .None {
			return from_engine_error(rerr, span)
		}
	}
	return ok_error()
}

drop_system_autoindexes_for_table :: proc(
	e: ^engine.Engine,
	table_name: string,
	span: sql.Span,
	allocator := context.allocator,
) -> Exec_Error {
	refs, err := engine.catalog_indexes_on_table(e, table_name, allocator)
	if err != .None {
		return from_engine_error(err, span)
	}
	defer engine.free_catalog_index_refs(refs, allocator)

	for r in refs {
		if !is_system_autoindex_name(r.name) {
			continue
		}
		uerr := engine.catalog_unregister_index(e, r.name)
		if uerr != .None {
			return from_engine_error(uerr, span)
		}
	}
	return ok_error()
}

exec_create_table :: proc(s: ^Exec_Session, stmt: sql.Create_Table_Stmt, span: sql.Span) -> (Exec_Result, Exec_Error) {
	e := session_engine(s)
	if e == nil {
		return {}, error_at(.Closed, "session is closed", span)
	}

	columns, table_unique, pk_ordered, berr := bind_create_table_columns(stmt)
	if has_error(berr) {
		return {}, berr
	}
	defer free_bound_columns(columns)
	defer free_unique_col_sets(table_unique)
	defer if pk_ordered != nil { delete(pk_ordered) }

	started, btxn := stmt_write_begin(s, e, span)
	if has_error(btxn) {
		return {}, btxn
	}

	_, rerr := engine.catalog_register_table(e, stmt.name, columns)
	if rerr == .Exists {
		if stmt.if_not_exists {
			// Soft success: only unwind an auto-commit txn; keep explicit txn open.
			if serr := soft_rollback_started(s, e, started, span); has_error(serr) {
				return {}, serr
			}
			return ok_result(), ok_error()
		}
		return {}, finish_write_error(s, e, started, make_error(.Table_Exists, "table %q already exists", stmt.name, span = span), span)
	}
	if rerr != .None {
		return {}, finish_write_error(s, e, started, from_engine_error(rerr, span), span)
	}

	if ierr := register_system_unique_indexes(e, stmt.name, columns, table_unique, pk_ordered, span); has_error(ierr) {
		return {}, finish_write_error(s, e, started, ierr, span)
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

	// Drop system autoindexes first so TEXT PK / UNIQUE tables can DROP without manual DROP INDEX.
	if derr := drop_system_autoindexes_for_table(e, stmt.name, span); has_error(derr) {
		return {}, finish_write_error(s, e, started, derr, span)
	}

	uerr := engine.catalog_unregister_table(e, stmt.name)
	if uerr == .Not_Found {
		if stmt.if_exists {
			if serr := soft_rollback_started(s, e, started, span); has_error(serr) {
				return {}, serr
			}
			return ok_result(), ok_error()
		}
		return {}, finish_write_error(s, e, started, make_error(.Unknown_Table, "no such table: %q", stmt.name, span = span), span)
	}
	if uerr == .Has_Indexes {
		return {}, finish_write_error(
			s,
			e,
			started,
			make_error(
				.Has_Indexes,
				"cannot DROP TABLE %q: indexes still exist (drop indexes first)",
				stmt.name,
				span = span,
			),
			span,
		)
	}
	if uerr != .None {
		return {}, finish_write_error(s, e, started, from_engine_error(uerr, span), span)
	}

	if cerr := stmt_write_commit(s, e, started, span); has_error(cerr) {
		return {}, cerr
	}
	return ok_result(), ok_error()
}
