package exec

import "core:strings"
import engine "../engine"
import sql "../sql"

// S6: two-table INNER / CROSS joins via nested loop.
// LEFT OUTER, USING, and >2 tables are rejected with clear errors.

validate_select_joins :: proc(stmt: sql.Select_Stmt, span: sql.Span) -> Exec_Error {
	if len(stmt.joins) == 0 {
		return ok_error()
	}
	if len(stmt.joins) > 1 {
		return make_error(
			.Unsupported_Ast,
			"only two-table JOINs are supported (multiple JOIN clauses not supported yet)",
			span = span,
		)
	}
	j := stmt.joins[0]
	if len(j.using_cols) > 0 {
		return make_error(
			.Unsupported_Ast,
			"JOIN ... USING is not supported yet (use ON)",
			span = j.span,
		)
	}
	switch j.kind {
	case .Left:
		return make_error(
			.Unsupported_Ast,
			"LEFT OUTER JOIN is not supported yet",
			span = j.span,
		)
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
	return ok_error()
}

build_flat_join_columns :: proc(
	left_cols, right_cols: []engine.Catalog_Column,
	left_table, left_alias, right_table, right_alias: string,
	allocator := context.allocator,
) -> (columns: []engine.Catalog_Column, sides: []Join_Side, err: Exec_Error) {
	nL := len(left_cols)
	nR := len(right_cols)
	columns = make([]engine.Catalog_Column, nL + nR, allocator)
	for c, i in left_cols {
		columns[i] = c
	}
	for c, i in right_cols {
		columns[nL + i] = c
	}
	sides = make([]Join_Side, 2, allocator)
	sides[0] = Join_Side{table = left_table, alias = left_alias, offset = 0, ncols = nL}
	sides[1] = Join_Side{table = right_table, alias = right_alias, offset = nL, ncols = nR}

	left_exp := side_exposed_name(sides[0])
	right_exp := side_exposed_name(sides[1])
	if left_exp != "" && right_exp != "" && strings.equal_fold(left_exp, right_exp) {
		delete(columns, allocator)
		delete(sides, allocator)
		return nil, nil, make_error(
			.Invalid_Schema,
			"duplicate table/alias %q in FROM/JOIN",
			left_exp,
		)
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

// nested_loop_join builds the joined row stream for INNER (ON) or CROSS (no ON).
// Appends owned rows into matched; on error, frees rows already appended.
nested_loop_join :: proc(
	matched:^[dynamic][]Value,
	left_rows, right_rows: [][]Value,
	on_expr: ^sql.Expr,
	where_expr: ^sql.Expr,
	env: ^Row_Env,
	allocator := context.allocator,
) -> Exec_Error {
	for lrow in left_rows {
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
			if keep && where_expr != nil {
				ok, werr := eval_expr_bool(where_expr, env, allocator)
				if has_error(werr) {
					free_values(joined, allocator)
					return werr
				}
				keep = ok
			}
			if keep {
				append(matched, joined)
			} else {
				free_values(joined, allocator)
			}
		}
	}
	return ok_error()
}
