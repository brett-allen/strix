package exec

import "core:fmt"
import "core:slice"
import "core:strings"
import engine "../engine"

// list_tables returns user table names in lexical order.
// Caller frees with free_table_names.
list_tables :: proc(s: ^Exec_Session, allocator := context.allocator) -> ([]string, Exec_Error) {
	e := session_engine(s)
	if e == nil {
		return nil, error_at(.Closed, "session is closed")
	}
	names, err := engine.catalog_list_tables(e, allocator)
	if err != .None {
		return nil, from_engine_error(err)
	}
	slice.sort(names)
	return names, ok_error()
}

free_table_names :: proc(names: []string, allocator := context.allocator) {
	engine.free_catalog_table_names(names, allocator)
}

// schema_sql synthesizes CREATE TABLE / CREATE INDEX text from catalog meta.
// If table_name is empty, all tables (lexical) are included; otherwise one table
// or Unknown_Table if missing. Caller frees the returned string.
schema_sql :: proc(
	s: ^Exec_Session,
	table_name: string = "",
	allocator := context.allocator,
) -> (string, Exec_Error) {
	e := session_engine(s)
	if e == nil {
		return "", error_at(.Closed, "session is closed")
	}

	if table_name != "" {
		return schema_sql_one(e, table_name, allocator)
	}

	names, lerr := list_tables(s, allocator)
	if has_error(lerr) {
		return "", lerr
	}
	defer free_table_names(names, allocator)

	b: strings.Builder
	strings.builder_init(&b, allocator)
	defer strings.builder_destroy(&b)

	for name, i in names {
		part, perr := schema_sql_one(e, name, allocator)
		if has_error(perr) {
			return "", perr
		}
		if i > 0 && strings.builder_len(b) > 0 && !strings.has_suffix(strings.to_string(b), "\n") {
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, part)
		if !strings.has_suffix(part, "\n") {
			strings.write_byte(&b, '\n')
		}
		delete(part, allocator)
	}
	return strings.clone(strings.to_string(b), allocator), ok_error()
}

schema_sql_one :: proc(
	e: ^engine.Engine,
	table_name: string,
	allocator := context.allocator,
) -> (string, Exec_Error) {
	entry, gerr := engine.catalog_get_table_entry(e, table_name, allocator)
	if gerr == .Not_Found {
		return "", make_error(.Unknown_Table, "no such table: %q", table_name)
	}
	if gerr != .None {
		return "", from_engine_error(gerr)
	}
	defer engine.free_catalog_entry(entry, allocator)

	b: strings.Builder
	strings.builder_init(&b, allocator)
	defer strings.builder_destroy(&b)

	pk_count := count_primary_key_columns(entry.columns)
	composite_pk := pk_count > 1

	idx_refs, ixerr := engine.catalog_indexes_on_table(e, table_name, allocator)
	if ixerr != .None {
		return "", from_engine_error(ixerr)
	}
	defer engine.free_catalog_index_refs(idx_refs, allocator)

	// Composite PK column order from the matching system unique autoindex when present.
	pk_index_names: []string
	if composite_pk {
		for ref in idx_refs {
			if !is_system_autoindex_name(ref.name) || !engine.catalog_index_is_unique(ref.entry) {
				continue
			}
			if index_columns_match_pk_set(ref.entry.columns, entry.columns) {
				pk_index_names = make([]string, len(ref.entry.columns), allocator)
				for c, i in ref.entry.columns {
					pk_index_names[i] = c.name
				}
				break
			}
		}
		if pk_index_names == nil {
			// Fallback: table column order.
			pk_index_names = make([]string, pk_count, allocator)
			j := 0
			for c in entry.columns {
				if .Primary_Key in c.flags {
					pk_index_names[j] = c.name
					j += 1
				}
			}
		}
	}
	defer if pk_index_names != nil { delete(pk_index_names, allocator) }

	fmt.sbprintf(&b, "CREATE TABLE %s (\n", table_name)
	for col, i in entry.columns {
		if i > 0 {
			strings.write_string(&b, ",\n")
		}
		strings.write_string(&b, "  ")
		write_column_def(&b, col, omit_primary_key = composite_pk)
	}
	if composite_pk && len(pk_index_names) > 0 {
		strings.write_string(&b, ",\n  PRIMARY KEY (")
		for n, i in pk_index_names {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, n)
		}
		strings.write_string(&b, ")")
	}

	// Multi-column UNIQUE system autoindexes → table-level UNIQUE (c1, c2)
	// inside CREATE TABLE (replayable; never emit reserved strix_autoindex_* names).
	if len(idx_refs) > 1 {
		slice.sort_by(idx_refs, proc(a, b: engine.Catalog_Index_Ref) -> bool {
			return a.name < b.name
		})
	}
	for ref in idx_refs {
		if !is_system_autoindex_name(ref.name) || !engine.catalog_index_is_unique(ref.entry) {
			continue
		}
		if len(ref.entry.columns) <= 1 {
			continue // single-col UNIQUE/PK shown on the column
		}
		if composite_pk && index_columns_match_pk_set(ref.entry.columns, entry.columns) {
			continue // already emitted as PRIMARY KEY (…)
		}
		strings.write_string(&b, ",\n  UNIQUE (")
		for col, i in ref.entry.columns {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, col.name)
		}
		strings.write_string(&b, ")")
	}
	strings.write_string(&b, "\n);\n")

	// User indexes only (system autoindexes never appear as CREATE INDEX).
	for ref in idx_refs {
		if len(ref.entry.columns) == 0 {
			continue // v1 rows without column meta — skip awkwardly empty INDEX
		}
		if is_system_autoindex_name(ref.name) {
			continue
		}
		if engine.catalog_index_is_unique(ref.entry) {
			fmt.sbprintf(&b, "CREATE UNIQUE INDEX %s ON %s (", ref.name, table_name)
		} else {
			fmt.sbprintf(&b, "CREATE INDEX %s ON %s (", ref.name, table_name)
		}
		for col, i in ref.entry.columns {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, col.name)
			if .Desc in col.flags {
				strings.write_string(&b, " DESC")
			}
		}
		strings.write_string(&b, ");\n")
	}

	return strings.clone(strings.to_string(b), allocator), ok_error()
}

// index_columns_match_pk_set reports whether index cols are exactly the PK columns (any order).
index_columns_match_pk_set :: proc(
	index_cols: []engine.Catalog_Column,
	table_cols: []engine.Catalog_Column,
) -> bool {
	pk_count := count_primary_key_columns(table_cols)
	if pk_count == 0 || len(index_cols) != pk_count {
		return false
	}
	for ic in index_cols {
		found := false
		for tc in table_cols {
			if .Primary_Key in tc.flags && strings.equal_fold(tc.name, ic.name) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

write_column_def :: proc(b: ^strings.Builder, col: engine.Catalog_Column, omit_primary_key := false) {
	strings.write_string(b, col.name)
	if col.type_name != "" {
		fmt.sbprintf(b, " %s", col.type_name)
	}
	show_pk := .Primary_Key in col.flags && !omit_primary_key
	// PRIMARY KEY implies NOT NULL; avoid redundant NOT NULL (incl. composite table PK).
	if .Not_Null in col.flags && .Primary_Key not_in col.flags {
		strings.write_string(b, " NOT NULL")
	}
	if show_pk {
		strings.write_string(b, " PRIMARY KEY")
	} else if .Unique in col.flags {
		strings.write_string(b, " UNIQUE")
	}
	if .Has_Default in col.flags {
		strings.write_string(b, " DEFAULT ")
		write_default_literal(b, col)
	}
}

write_default_literal :: proc(b: ^strings.Builder, col: engine.Catalog_Column) {
	switch col.default_kind {
	case .None, .Null:
		strings.write_string(b, "NULL")
	case .Integer:
		fmt.sbprintf(b, "%d", col.default_i)
	case .Float:
		fmt.sbprintf(b, "%g", col.default_f)
	case .Boolean:
		strings.write_string(b, "TRUE" if col.default_i != 0 else "FALSE")
	case .Text:
		strings.write_byte(b, '\'')
		for i in 0 ..< len(col.default_bytes) {
			c := col.default_bytes[i]
			if c == '\'' {
				strings.write_string(b, "''")
			} else {
				strings.write_byte(b, c)
			}
		}
		strings.write_byte(b, '\'')
	case .Blob:
		strings.write_string(b, "X'")
		for i in 0 ..< len(col.default_bytes) {
			fmt.sbprintf(b, "%02X", col.default_bytes[i])
		}
		strings.write_byte(b, '\'')
	case .Uuid:
		canon := format_uuid_canonical(transmute([]u8)col.default_bytes)
		defer delete(canon)
		strings.write_byte(b, '\'')
		strings.write_string(b, canon)
		strings.write_byte(b, '\'')
	}
}
