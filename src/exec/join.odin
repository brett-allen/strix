package exec

import "core:strings"
import engine "../engine"
import sql "../sql"

// F1: left-deep nested-loop joins — INNER / CROSS / LEFT OUTER, N tables.
// USING, RIGHT / FULL / NATURAL remain rejected (NATURAL/RIGHT/FULL at parse).

validate_select_joins :: proc(stmt: sql.Select_Stmt, span: sql.Span) -> Exec_Error {
	_ = span
	if len(stmt.joins) == 0 {
		return ok_error()
	}
	for j in stmt.joins {
		if len(j.using_cols) > 0 {
			return make_error(
				.Unsupported_Ast,
				"JOIN ... USING is not supported yet (use ON)",
				span = j.span,
			)
		}
		switch j.kind {
		case .Left:
			if j.on == nil {
				return make_error(
					.Unsupported_Ast,
					"LEFT OUTER JOIN requires an ON condition",
					span = j.span,
				)
			}
		case .Inner:
			if j.on == nil {
				return make_error(
					.Unsupported_Ast,
					"INNER JOIN requires an ON condition",
					span = j.span,
				)
			}
		case .Cross:
			// CROSS JOIN / comma-join: no ON required (cartesian, then WHERE).
			if j.on != nil {
				return make_error(
					.Unsupported_Ast,
					"CROSS JOIN must not have an ON condition",
					span = j.span,
				)
			}
		}
		if j.table.table == "" {
			return make_error(.Invalid_Schema, "JOIN requires a table name", span = j.span)
		}
	}
	return ok_error()
}

// build_flat_join_columns flattens N table column lists into one schema + Join_Side meta.
// tables / aliases / col_lists must be the same length (≥2 for joins).
build_flat_join_columns :: proc(
	tables: []string,
	aliases: []string,
	col_lists: [][]engine.Catalog_Column,
	allocator := context.allocator,
) -> (columns: []engine.Catalog_Column, sides: []Join_Side, err: Exec_Error) {
	n := len(tables)
	if n == 0 || len(aliases) != n || len(col_lists) != n {
		return nil, nil, make_error(.Engine, "join column build arity mismatch")
	}
	total := 0
	for cols in col_lists {
		total += len(cols)
	}
	columns = make([]engine.Catalog_Column, total, allocator)
	sides = make([]Join_Side, n, allocator)
	off := 0
	for i in 0 ..< n {
		ncols := len(col_lists[i])
		for c, ci in col_lists[i] {
			columns[off + ci] = c
		}
		sides[i] = Join_Side{
			table  = tables[i],
			alias  = aliases[i],
			offset = off,
			ncols  = ncols,
		}
		off += ncols
	}

	// Duplicate exposed table/alias names are illegal (S6 / F1).
	for i in 0 ..< n {
		ei := side_exposed_name(sides[i])
		if ei == "" {
			continue
		}
		for j in i + 1 ..< n {
			ej := side_exposed_name(sides[j])
			if ej != "" && strings.equal_fold(ei, ej) {
				delete(columns, allocator)
				delete(sides, allocator)
				return nil, nil, make_error(
					.Invalid_Schema,
					"duplicate table/alias %q in FROM/JOIN",
					ei,
				)
			}
		}
	}
	return columns, sides, ok_error()
}

// scan_table_rows seq-scans a table into owned decoded rows (caller frees).
scan_table_rows :: proc(
	e: ^engine.Engine,
	table_name: string,
	span: sql.Span,
	allocator := context.allocator,
) -> ([][]Value, Exec_Error) {
	tree, oerr := engine.catalog_open_table(e, table_name)
	if oerr != .None {
		return nil, from_engine_error(oerr, span)
	}
	out := make([dynamic][]Value, 0, 16, allocator)
	cur := engine.btree_cursor_init(&tree)
	defer engine.btree_cursor_close(&cur)

	start_key: [8]u8
	_ = engine.rowid_key(0, start_key[:])
	if serr := engine.btree_seek_ge(&cur, start_key[:]); serr != .None {
		delete(out)
		return nil, from_engine_error(serr, span)
	}
	for engine.btree_cursor_valid(&cur) {
		payload := engine.btree_cursor_payload(&cur)
		vals, derr := decode_heap_row(payload, allocator)
		if has_error(derr) {
			free_scanned_rows(out[:], allocator)
			delete(out)
			return nil, derr
		}
		append(&out, vals)
		if nerr := engine.btree_next(&cur); nerr != .None {
			free_scanned_rows(out[:], allocator)
			delete(out)
			return nil, from_engine_error(nerr, span)
		}
	}
	return out[:], ok_error()
}

concat_join_row :: proc(left, right: []Value, allocator := context.allocator) -> []Value {
	out := make([]Value, len(left) + len(right), allocator)
	for v, i in left {
		out[i] = clone_value(v, allocator)
	}
	for v, i in right {
		out[len(left) + i] = clone_value(v, allocator)
	}
	return out
}

null_extend_join_row :: proc(left: []Value, right_ncols: int, allocator := context.allocator) -> []Value {
	out := make([]Value, len(left) + right_ncols, allocator)
	for v, i in left {
		out[i] = clone_value(v, allocator)
	}
	for i in 0 ..< right_ncols {
		out[len(left) + i] = value_null()
	}
	return out
}

// nested_loop_join_step joins left_rows with right_rows for one JOIN clause.
// INNER / CROSS: emit matching pairs only. LEFT: NULL-extend right when no ON match.
// Does not apply WHERE (caller filters after the full left-deep chain).
// Appends owned rows into out; on error, frees rows already appended to out.
nested_loop_join_step :: proc(
	out: ^[dynamic][]Value,
	left_rows, right_rows: [][]Value,
	kind: sql.Join_Kind,
	on_expr: ^sql.Expr,
	env: ^Row_Env,
	allocator := context.allocator,
) -> Exec_Error {
	right_ncols := 0
	if len(right_rows) > 0 {
		right_ncols = len(right_rows[0])
	} else if env != nil && len(env.sides) > 0 {
		right_ncols = env.sides[len(env.sides) - 1].ncols
	}

	for lrow in left_rows {
		matched_any := false
		for rrow in right_rows {
			joined := concat_join_row(lrow, rrow, allocator)
			env.values = joined
			keep := true
			if on_expr != nil {
				ok, oerr := eval_expr_bool(on_expr, env, allocator)
				if has_error(oerr) {
					free_values(joined, allocator)
					return oerr
				}
				keep = ok
			}
			if keep {
				matched_any = true
				append(out, joined)
			} else {
				free_values(joined, allocator)
			}
		}
		if kind == .Left && !matched_any {
			padded := null_extend_join_row(lrow, right_ncols, allocator)
			append(out, padded)
		}
	}
	return ok_error()
}

// filter_rows_where keeps rows for which WHERE is true (or all rows if where_expr is nil).
// Moves kept rows into out; frees dropped rows. On eval error, frees the current row and
// all not-yet-processed input rows (rows already appended to out remain for the caller).
filter_rows_where :: proc(
	out: ^[dynamic][]Value,
	rows: [][]Value,
	where_expr: ^sql.Expr,
	env: ^Row_Env,
	allocator := context.allocator,
) -> Exec_Error {
	if where_expr == nil {
		for row in rows {
			append(out, row)
		}
		return ok_error()
	}
	for i in 0 ..< len(rows) {
		row := rows[i]
		env.values = row
		ok, werr := eval_expr_bool(where_expr, env, allocator)
		if has_error(werr) {
			free_values(row, allocator)
			for j in i + 1 ..< len(rows) {
				free_values(rows[j], allocator)
			}
			return werr
		}
		if ok {
			append(out, row)
		} else {
			free_values(row, allocator)
		}
	}
	return ok_error()
}
