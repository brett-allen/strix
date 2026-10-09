package exec

import "core:strings"
import engine "../engine"
import sql "../sql"

Bound_Proj_Kind :: enum {
	Column, // catalog column by index
	Expr,   // evaluate expression
}

Bound_Proj :: struct {
	kind:    Bound_Proj_Kind,
	col_idx: int,
	expr:    ^sql.Expr,
	name:    string, // owned result column name
}

free_bound_projs :: proc(projs: []Bound_Proj, allocator := context.allocator) {
	for p in projs {
		if p.name != "" {
			delete(p.name, allocator)
		}
	}
	if projs != nil {
		delete(projs, allocator)
	}
}

// exec_select runs a single-table SELECT (seq scan + in-memory filter/sort/limit).
exec_select :: proc(s: ^Exec_Session, stmt: sql.Select_Stmt, span: sql.Span) -> (Exec_Result, Exec_Error) {
	e := session_engine(s)
	if e == nil {
		return {}, error_at(.Closed, "session is closed", span)
	}

	if err := validate_select_supported(stmt, span); has_error(err) {
		return {}, err
	}

	table_name := stmt.from.table
	if table_name == "" {
		return {}, make_error(.Invalid_Schema, "SELECT requires a FROM table", span = span)
	}

	entry, gerr := engine.catalog_get_table_entry(e, table_name)
	if gerr == .Not_Found {
		return {}, make_error(.Unknown_Table, "no such table: %q", table_name, span = span)
	}
	if gerr != .None {
		return {}, from_engine_error(gerr, span)
	}
	defer engine.free_catalog_entry(entry)

	if len(entry.columns) == 0 {
		return {}, make_error(.Invalid_Schema, "table %q has no columns", table_name, span = span)
	}

	projs, perr := bind_select_projection(stmt, entry.columns, table_name, stmt.from.alias)
	if has_error(perr) {
		return {}, perr
	}
	defer free_bound_projs(projs)

	is_grouped := len(stmt.group_by) > 0
	group_idxs: []int = nil
	agg_slots: []Agg_Slot = nil
	is_agg := false

	if is_grouped {
		gidxs, gslots, gerr := prepare_grouped_select(
			stmt,
			entry.columns,
			table_name,
			stmt.from.alias,
		)
		if has_error(gerr) {
			return {}, gerr
		}
		group_idxs = gidxs
		agg_slots = gslots
	} else {
		agg_ok, aslots, aerr := prepare_aggregate_select(stmt)
		if has_error(aerr) {
			return {}, aerr
		}
		is_agg = agg_ok
		agg_slots = aslots
	}
	defer {
		free_agg_slots(agg_slots)
		if group_idxs != nil {
			delete(group_idxs)
		}
	}

	if is_grouped || is_agg {
		if verr := validate_agg_projection_exprs(
			stmt,
			agg_slots,
			entry.columns,
			table_name,
			stmt.from.alias,
		); has_error(verr) {
			return {}, verr
		}
	} else {
		if verr := validate_select_exprs(stmt, projs, entry.columns, table_name, stmt.from.alias); has_error(verr) {
			return {}, verr
		}
	}

	limit_n: int = -1
	offset_n: int = 0
	if stmt.limit != nil {
		n, lerr := eval_const_integer(stmt.limit, "LIMIT")
		if has_error(lerr) {
			return {}, lerr
		}
		limit_n = int(n)
	}
	if stmt.offset != nil {
		n, oerr := eval_const_integer(stmt.offset, "OFFSET")
		if has_error(oerr) {
			return {}, oerr
		}
		offset_n = int(n)
	}

	tree, oerr := engine.catalog_open_table(e, table_name)
	if oerr != .None {
		return {}, from_engine_error(oerr, span)
	}

	matched := make([dynamic][]Value, 0, 16)
	defer {
		free_scanned_rows(matched[:])
		delete(matched)
	}

	env := Row_Env{
		table   = table_name,
		alias   = stmt.from.alias,
		columns = entry.columns,
	}

	// Index point lookup: fail hard on Engine/Io/encode errors; seq-scan only when
	// there is cleanly no usable index (no sargable eq, or no matching single-col index).
	used_index := false
	if stmt.where_expr != nil {
		col_idx, const_val, is_eq := find_single_column_eq_const(
			stmt.where_expr,
			entry.columns,
			table_name,
			stmt.from.alias,
		)
		if is_eq {
			defer free_value(const_val)
			idx_refs, ixerr := engine.catalog_indexes_on_table(e, table_name)
			if ixerr != .None {
				return {}, from_engine_error(ixerr, span)
			}
			defer engine.free_catalog_index_refs(idx_refs)
			if iname, iok := find_usable_eq_index(idx_refs, entry.columns, col_idx); iok {
				ikey_vals := []Value{const_val}
				ikey, kerr := encode_index_key(ikey_vals)
				if has_error(kerr) {
					return {}, kerr
				}
				itree, ioerr := engine.catalog_open_index(e, iname)
				if ioerr != .None {
					delete(ikey)
					return {}, from_engine_error(ioerr, span)
				}
				rowids, rerr := engine.index_collect_rowids(&itree, ikey)
				delete(ikey)
				if rerr != .None {
					return {}, from_engine_error(rerr, span)
				}
				defer delete(rowids)
				for rowid in rowids {
					payload, gerr := engine.table_get_row(&tree, rowid)
					if gerr != .None {
						return {}, from_engine_error(gerr, span)
					}
					vals, derr := decode_heap_row(payload)
					delete(payload)
					if has_error(derr) {
						return {}, derr
					}
					// Re-check WHERE (handles non-sargable extras if we ever widen matcher).
					env.values = vals
					ok, werr := eval_expr_bool(stmt.where_expr, &env)
					if has_error(werr) {
						free_values(vals)
						return {}, werr
					}
					if ok {
						append(&matched, vals)
					} else {
						free_values(vals)
					}
				}
				used_index = true
			}
		}
	}

	if !used_index {
		cur := engine.btree_cursor_init(&tree)
		defer engine.btree_cursor_close(&cur)

		start_key: [8]u8
		_ = engine.rowid_key(0, start_key[:])
		if serr := engine.btree_seek_ge(&cur, start_key[:]); serr != .None {
			return {}, from_engine_error(serr, span)
		}

		for engine.btree_cursor_valid(&cur) {
			payload := engine.btree_cursor_payload(&cur)
			vals, derr := decode_heap_row(payload)
			if has_error(derr) {
				return {}, derr
			}

			env.values = vals
			keep := true
			if stmt.where_expr != nil {
				ok, werr := eval_expr_bool(stmt.where_expr, &env)
				if has_error(werr) {
					free_values(vals)
					return {}, werr
				}
				keep = ok
			}
			if keep {
				append(&matched, vals)
			} else {
				free_values(vals)
			}

			if nerr := engine.btree_next(&cur); nerr != .None {
				return {}, from_engine_error(nerr, span)
			}
		}
	}

	if is_grouped {
		return exec_select_grouped(
			stmt,
			projs,
			agg_slots,
			group_idxs,
			matched[:],
			&env,
			limit_n,
			offset_n,
		)
	}

	if is_agg {
		return exec_select_aggregate(
			stmt,
			projs,
			agg_slots,
			matched[:],
			&env,
			limit_n,
			offset_n,
		)
	}

	if len(stmt.order_by) > 0 {
		if sort_err := sort_scanned_rows(matched[:], stmt.order_by, &env); has_error(sort_err) {
			return {}, sort_err
		}
	}

	start := offset_n
	if start > len(matched) {
		start = len(matched)
	}
	end := len(matched)
	if limit_n >= 0 {
		end = min(start + limit_n, len(matched))
	}
	window := matched[start:end]

	col_names := make([]string, len(projs))
	for p, i in projs {
		col_names[i] = strings.clone(p.name)
	}

	out_rows := make([][]string, len(window))
	for ri in 0 ..< len(window) {
		env.values = window[ri]
		cells := make([]string, len(projs))
		for p, ci in projs {
			cell, cerr := project_cell(p, &env)
			if has_error(cerr) {
				// clean up partial
				for j in 0 ..< ci {
					delete(cells[j])
				}
				delete(cells)
				for j in 0 ..< ri {
					for c in out_rows[j] {
						delete(c)
					}
					delete(out_rows[j])
				}
				delete(out_rows)
				for name in col_names {
					delete(name)
				}
				delete(col_names)
				return {}, cerr
			}
			cells[ci] = cell
		}
		out_rows[ri] = cells
	}

	return result_set_result(col_names, out_rows), ok_error()
}

// exec_select_aggregate accumulates over filtered rows and emits one result row
// (then applies LIMIT/OFFSET). Empty filtered set still yields one row.
exec_select_aggregate :: proc(
	stmt: sql.Select_Stmt,
	projs: []Bound_Proj,
	slots: []Agg_Slot,
	matched: [][]Value,
	env: ^Row_Env,
	limit_n: int,
	offset_n: int,
	allocator := context.allocator,
) -> (Exec_Result, Exec_Error) {
	for row in matched {
		env.values = row
		for i in 0 ..< len(slots) {
			if aerr := accumulate_agg_slot(&slots[i], env, allocator); has_error(aerr) {
				return {}, aerr
			}
		}
	}

	finals := make([]Value, len(slots), allocator)
	defer {
		for v in finals {
			free_value(v, allocator)
		}
		delete(finals, allocator)
	}
	for i in 0 ..< len(slots) {
		v, ferr := finalize_agg_slot(slots[i], allocator)
		if has_error(ferr) {
			return {}, ferr
		}
		finals[i] = v
	}

	// Project one logical row (no current heap row required for pure aggs/constants).
	env.values = nil
	cells := make([]string, len(projs), allocator)
	for p, ci in projs {
		cell, cerr := project_agg_cell(p, slots, finals, env, allocator)
		if has_error(cerr) {
			for j in 0 ..< ci {
				delete(cells[j], allocator)
			}
			delete(cells, allocator)
			return {}, cerr
		}
		cells[ci] = cell
	}

	col_names := make([]string, len(projs), allocator)
	for p, i in projs {
		col_names[i] = strings.clone(p.name, allocator)
	}

	// LIMIT/OFFSET apply to the single aggregate result row.
	include := true
	if offset_n > 0 {
		include = false
	} else if limit_n == 0 {
		include = false
	}

	out_rows: [][]string
	if include {
		out_rows = make([][]string, 1, allocator)
		out_rows[0] = cells
	} else {
		for c in cells {
			delete(c, allocator)
		}
		delete(cells, allocator)
		out_rows = make([][]string, 0, allocator)
	}

	_ = stmt
	return result_set_result(col_names, out_rows), ok_error()
}

project_agg_cell :: proc(
	p: Bound_Proj,
	slots: []Agg_Slot,
	finals: []Value,
	env: ^Row_Env,
	allocator := context.allocator,
) -> (string, Exec_Error) {
	switch p.kind {
	case .Column:
		// Whole-query agg has no row env; grouped queries supply a representative row.
		if env == nil || env.values == nil {
			return "", make_error(
				.Unsupported_Ast,
				"SELECT mixes aggregates with non-aggregate columns; GROUP BY is required",
			)
		}
		if p.col_idx < 0 || p.col_idx >= len(env.values) {
			return "", make_error(.Engine, "projection column index out of range")
		}
		return format_value_cell(env.values[p.col_idx], allocator), ok_error()
	case .Expr:
		v, err := eval_expr_with_aggs(p.expr, slots, finals, env, allocator)
		if has_error(err) {
			return "", err
		}
		defer free_value(v, allocator)
		return format_value_cell(v, allocator), ok_error()
	}
	return "", make_error(.Engine, "invalid projection")
}

Group_Bucket :: struct {
	key:   []Value, // owned group-key clones
	slots: []Agg_Slot, // owned per-group accumulators
}

free_group_bucket :: proc(g: Group_Bucket, allocator := context.allocator) {
	free_values(g.key, allocator)
	free_agg_slots(g.slots, allocator)
}

free_group_buckets :: proc(groups: []Group_Bucket, allocator := context.allocator) {
	for g in groups {
		free_group_bucket(g, allocator)
	}
}

Grouped_Out_Row :: struct {
	cells:     []string, // owned
	sort_keys: []Value, // owned; empty if no ORDER BY
}

free_grouped_out_row :: proc(r: Grouped_Out_Row, allocator := context.allocator) {
	for c in r.cells {
		delete(c, allocator)
	}
	if r.cells != nil {
		delete(r.cells, allocator)
	}
	free_values(r.sort_keys, allocator)
}

// exec_select_grouped partitions filtered rows by GROUP BY keys, accumulates
// per-group aggregates, applies HAVING, then ORDER BY / LIMIT / OFFSET.
// Empty filtered set → zero result rows (unlike whole-query aggregates).
exec_select_grouped :: proc(
	stmt: sql.Select_Stmt,
	projs: []Bound_Proj,
	slot_templates: []Agg_Slot,
	group_idxs: []int,
	matched: [][]Value,
	env: ^Row_Env,
	limit_n: int,
	offset_n: int,
	allocator := context.allocator,
) -> (Exec_Result, Exec_Error) {
	groups := make([dynamic]Group_Bucket, 0, 8, allocator)
	defer {
		free_group_buckets(groups[:], allocator)
		delete(groups)
	}

	for row in matched {
		key, kerr := extract_group_key(row, group_idxs, allocator)
		if has_error(kerr) {
			return {}, kerr
		}

		found := -1
		for g, gi in groups {
			eq, eerr := group_keys_equal(g.key, key)
			if has_error(eerr) {
				free_values(key, allocator)
				return {}, eerr
			}
			if eq {
				found = gi
				break
			}
		}

		if found < 0 {
			slots := clone_agg_slot_templates(slot_templates, allocator)
			append(&groups, Group_Bucket{key = key, slots = slots})
			found = len(groups) - 1
		} else {
			free_values(key, allocator)
		}

		env.values = row
		for i in 0 ..< len(groups[found].slots) {
			if aerr := accumulate_agg_slot(&groups[found].slots[i], env, allocator); has_error(aerr) {
				return {}, aerr
			}
		}
	}

	out_rows := make([dynamic]Grouped_Out_Row, 0, len(groups), allocator)
	defer {
		for r in out_rows {
			free_grouped_out_row(r, allocator)
		}
		delete(out_rows)
	}

	ncols := len(env.columns)
	for g in groups {
		finals := make([]Value, len(g.slots), allocator)
		for i in 0 ..< len(g.slots) {
			v, ferr := finalize_agg_slot(g.slots[i], allocator)
			if has_error(ferr) {
				for j in 0 ..< i {
					free_value(finals[j], allocator)
				}
				delete(finals, allocator)
				return {}, ferr
			}
			finals[i] = v
		}

		rep := make_group_rep_row(ncols, group_idxs, g.key, allocator)
		env.values = rep

		keep := true
		if stmt.having != nil {
			ok, herr := eval_expr_bool_with_aggs(stmt.having, g.slots, finals, env, allocator)
			if has_error(herr) {
				for v in finals {
					free_value(v, allocator)
				}
				delete(finals, allocator)
				free_values(rep, allocator)
				return {}, herr
			}
			keep = ok
		}

		if !keep {
			for v in finals {
				free_value(v, allocator)
			}
			delete(finals, allocator)
			free_values(rep, allocator)
			continue
		}

		cells := make([]string, len(projs), allocator)
		for p, ci in projs {
			cell, cerr := project_agg_cell(p, g.slots, finals, env, allocator)
			if has_error(cerr) {
				for j in 0 ..< ci {
					delete(cells[j], allocator)
				}
				delete(cells, allocator)
				for v in finals {
					free_value(v, allocator)
				}
				delete(finals, allocator)
				free_values(rep, allocator)
				return {}, cerr
			}
			cells[ci] = cell
		}

		sort_keys: []Value = nil
		if len(stmt.order_by) > 0 {
			sort_keys = make([]Value, len(stmt.order_by), allocator)
			for item, ki in stmt.order_by {
				v, oerr := eval_expr_with_aggs(item.expr, g.slots, finals, env, allocator)
				if has_error(oerr) {
					for j in 0 ..< ki {
						free_value(sort_keys[j], allocator)
					}
					delete(sort_keys, allocator)
					for c in cells {
						delete(c, allocator)
					}
					delete(cells, allocator)
					for fv in finals {
						free_value(fv, allocator)
					}
					delete(finals, allocator)
					free_values(rep, allocator)
					return {}, oerr
				}
				sort_keys[ki] = v
			}
		}

		append(&out_rows, Grouped_Out_Row{cells = cells, sort_keys = sort_keys})

		for v in finals {
			free_value(v, allocator)
		}
		delete(finals, allocator)
		free_values(rep, allocator)
	}

	if len(stmt.order_by) > 0 && len(out_rows) > 1 {
		if serr := sort_grouped_out_rows(out_rows[:], stmt.order_by); has_error(serr) {
			return {}, serr
		}
	}

	start := offset_n
	if start > len(out_rows) {
		start = len(out_rows)
	}
	end := len(out_rows)
	if limit_n >= 0 {
		end = min(start + limit_n, len(out_rows))
	}
	window := out_rows[start:end]

	col_names := make([]string, len(projs), allocator)
	for p, i in projs {
		col_names[i] = strings.clone(p.name, allocator)
	}

	rows := make([][]string, len(window), allocator)
	for i in 0 ..< len(window) {
		rows[i] = window[i].cells
		window[i].cells = nil // transfer ownership
	}

	return result_set_result(col_names, rows), ok_error()
}

sort_grouped_out_rows :: proc(
	rows: []Grouped_Out_Row,
	order: []sql.Order_By_Item,
) -> Exec_Error {
	if len(rows) <= 1 || len(order) == 0 {
		return ok_error()
	}
	idxs := make([]int, len(rows))
	defer delete(idxs)
	for i in 0 ..< len(rows) {
		idxs[i] = i
	}
	for i in 1 ..< len(idxs) {
		j := i
		for j > 0 {
			cmp, cerr := compare_order_keys(rows[idxs[j - 1]].sort_keys, rows[idxs[j]].sort_keys, order)
			if has_error(cerr) {
				return cerr
			}
			if cmp <= 0 {
				break
			}
			idxs[j - 1], idxs[j] = idxs[j], idxs[j - 1]
			j -= 1
		}
	}
	tmp := make([]Grouped_Out_Row, len(rows))
	defer delete(tmp)
	for i in 0 ..< len(rows) {
		tmp[i] = rows[idxs[i]]
	}
	for i in 0 ..< len(rows) {
		rows[i] = tmp[i]
	}
	return ok_error()
}

// validate_select_exprs dry-runs WHERE / ORDER BY / non-column projections on a null row
// so unbound names and unsupported nodes fail even when the table is empty.
validate_select_exprs :: proc(
	stmt: sql.Select_Stmt,
	projs: []Bound_Proj,
	columns: []engine.Catalog_Column,
	table_name, alias: string,
) -> Exec_Error {
	nulls := make([]Value, len(columns))
	defer delete(nulls)
	for i in 0 ..< len(nulls) {
		nulls[i] = value_null()
	}
	env := Row_Env{
		table   = table_name,
		alias   = alias,
		columns = columns,
		values  = nulls,
	}
	if stmt.where_expr != nil {
		v, err := eval_expr(stmt.where_expr, &env)
		free_value(v)
		if has_error(err) {
			return err
		}
	}
	for item in stmt.order_by {
		v, err := eval_expr(item.expr, &env)
		free_value(v)
		if has_error(err) {
			return err
		}
	}
	for p in projs {
		if p.kind == .Expr {
			v, err := eval_expr(p.expr, &env)
			free_value(v)
			if has_error(err) {
				return err
			}
		}
	}
	return ok_error()
}

validate_select_supported :: proc(stmt: sql.Select_Stmt, span: sql.Span) -> Exec_Error {
	if stmt.is_distinct {
		return make_error(.Unsupported_Ast, "SELECT DISTINCT is not supported yet", span = span)
	}
	if len(stmt.joins) > 0 {
		return make_error(.Unsupported_Ast, "JOINs are not supported yet", span = span)
	}
	// GROUP BY / HAVING executed (S5). Parser already rejects HAVING without GROUP BY.
	_ = span
	return ok_error()
}

bind_select_projection :: proc(
	stmt: sql.Select_Stmt,
	columns: []engine.Catalog_Column,
	table_name: string,
	alias: string,
	allocator := context.allocator,
) -> ([]Bound_Proj, Exec_Error) {
	if len(stmt.projection) == 0 {
		return nil, make_error(.Invalid_Schema, "SELECT projection is empty")
	}
	out := make([dynamic]Bound_Proj, 0, len(stmt.projection), allocator)
	for item in stmt.projection {
		switch item.kind {
		case .Star:
			for c, i in columns {
				append(&out, Bound_Proj{
					kind    = .Column,
					col_idx = i,
					name    = strings.clone(c.name, allocator),
				})
			}
		case .Table_Star:
			if !table_star_matches(item.table, table_name, alias) {
				free_bound_projs(out[:], allocator)
				return nil, make_error(
					.Unknown_Table,
					"no such table/alias %q in SELECT",
					item.table,
					span = item.span,
				)
			}
			for c, i in columns {
				append(&out, Bound_Proj{
					kind    = .Column,
					col_idx = i,
					name    = strings.clone(c.name, allocator),
				})
			}
		case .Expr:
			name := projection_name(item, allocator)
			if item.expr != nil && item.expr.kind == .Column_Ref {
				ref := item.expr.data.(sql.Column_Ref_Data)
				idx, ok, rerr := resolve_proj_column(ref, columns, table_name, alias, item.span)
				if has_error(rerr) {
					delete(name, allocator)
					free_bound_projs(out[:], allocator)
					return nil, rerr
				}
				if ok {
					append(&out, Bound_Proj{
						kind    = .Column,
						col_idx = idx,
						name    = name,
					})
					continue
				}
			}
			append(&out, Bound_Proj{
				kind = .Expr,
				expr = item.expr,
				name = name,
			})
		}
	}
	return out[:], ok_error()
}

table_star_matches :: proc(qual, table_name, alias: string) -> bool {
	if strings.equal_fold(qual, table_name) {
		return true
	}
	if alias != "" && strings.equal_fold(qual, alias) {
		return true
	}
	return false
}

resolve_proj_column :: proc(
	ref: sql.Column_Ref_Data,
	columns: []engine.Catalog_Column,
	table_name, alias: string,
	span: sql.Span,
) -> (idx: int, ok: bool, err: Exec_Error) {
	segs := ref.segments
	col_name: string
	if len(segs) == 1 {
		col_name = segs[0]
	} else if len(segs) == 2 {
		env := Row_Env{table = table_name, alias = alias, columns = columns}
		if !qualifier_matches(segs[0], &env) {
			return -1, false, make_error(
				.Unknown_Column,
				"no such table/alias %q in FROM",
				segs[0],
				span = span,
			)
		}
		col_name = segs[1]
	} else {
		return -1, false, make_error(
			.Unsupported_Ast,
			"multi-part column references are not supported",
			span = span,
		)
	}
	idx = find_column_index(columns, col_name)
	if idx < 0 {
		return -1, false, make_error(.Unknown_Column, "no such column: %q", col_name, span = span)
	}
	return idx, true, ok_error()
}

projection_name :: proc(item: sql.Select_Item, allocator := context.allocator) -> string {
	if item.alias != "" {
		return strings.clone(item.alias, allocator)
	}
	if item.expr != nil && item.expr.kind == .Column_Ref {
		segs := item.expr.data.(sql.Column_Ref_Data).segments
		if len(segs) > 0 {
			return strings.clone(segs[len(segs) - 1], allocator)
		}
	}
	if item.expr != nil && item.expr.kind == .Call {
		return sql.print_expr(item.expr, allocator)
	}
	return strings.clone("?", allocator)
}

project_cell :: proc(p: Bound_Proj, env: ^Row_Env, allocator := context.allocator) -> (string, Exec_Error) {
	switch p.kind {
	case .Column:
		if p.col_idx < 0 || p.col_idx >= len(env.values) {
			return "", make_error(.Engine, "projection column index out of range")
		}
		return format_value_cell(env.values[p.col_idx], allocator), ok_error()
	case .Expr:
		v, err := eval_expr(p.expr, env, allocator)
		if has_error(err) {
			return "", err
		}
		defer free_value(v, allocator)
		return format_value_cell(v, allocator), ok_error()
	}
	return "", make_error(.Engine, "invalid projection")
}

free_scanned_rows :: proc(rows: [][]Value, allocator := context.allocator) {
	for row in rows {
		free_values(row, allocator)
	}
}

sort_scanned_rows :: proc(
	rows: [][]Value,
	order: []sql.Order_By_Item,
	env: ^Row_Env,
) -> Exec_Error {
	if len(rows) <= 1 || len(order) == 0 {
		return ok_error()
	}
	// Precompute sort keys per row so ORDER BY errors surface before mutating order.
	keys := make([][]Value, len(rows))
	defer {
		for k in keys {
			free_values(k)
		}
		delete(keys)
	}
	for row, ri in rows {
		env.values = row
		krow := make([]Value, len(order))
		for item, ki in order {
			v, err := eval_expr(item.expr, env)
			if has_error(err) {
				for j in 0 ..< ki {
					free_value(krow[j])
				}
				delete(krow)
				for j in 0 ..< ri {
					free_values(keys[j])
					keys[j] = nil
				}
				return err
			}
			krow[ki] = v
		}
		keys[ri] = krow
	}

	idxs := make([]int, len(rows))
	defer delete(idxs)
	for i in 0 ..< len(rows) {
		idxs[i] = i
	}

	// Insertion sort (stable) — fine for v1 in-memory result sets.
	for i in 1 ..< len(idxs) {
		j := i
		for j > 0 {
			cmp, cerr := compare_order_keys(keys[idxs[j - 1]], keys[idxs[j]], order)
			if has_error(cerr) {
				return cerr
			}
			if cmp <= 0 {
				break
			}
			idxs[j - 1], idxs[j] = idxs[j], idxs[j - 1]
			j -= 1
		}
	}

	tmp := make([][]Value, len(rows))
	defer delete(tmp)
	for i in 0 ..< len(rows) {
		tmp[i] = rows[idxs[i]]
	}
	for i in 0 ..< len(rows) {
		rows[i] = tmp[i]
	}
	return ok_error()
}

compare_order_keys :: proc(a, b: []Value, order: []sql.Order_By_Item) -> (int, Exec_Error) {
	n := min(len(a), len(b), len(order))
	for i in 0 ..< n {
		cmp, cerr := compare_values(a[i], b[i])
		if has_error(cerr) {
			return 0, cerr
		}
		if cmp == 0 {
			continue
		}
		if order[i].desc {
			return -cmp, ok_error()
		}
		return cmp, ok_error()
	}
	return 0, ok_error()
}
