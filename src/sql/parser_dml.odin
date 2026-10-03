package sql

import "core:mem"
import "core:strings"

parse_insert :: proc(p: ^Parser, start: Span) -> (Statement, Parse_Error) {
	next(p) // INSERT

	conflict := Insert_Conflict.None
	if peek(p).kind == .Kw_Or {
		next(p)
		#partial switch peek(p).kind {
		case .Kw_Replace:
			next(p)
			conflict = .Replace
		case .Kw_Ignore:
			next(p)
			conflict = .Ignore
		case:
			return Statement{}, make_error(
				peek(p).span,
				"expected REPLACE or IGNORE after INSERT OR",
				allocator = p.allocator,
			)
		}
	}

	_, err := expect(p, .Kw_Into)
	if has_error(err) {
		return Statement{}, err
	}

	table, _, terr := parse_object_name(p)
	if has_error(terr) {
		return Statement{}, terr
	}

	columns: []string = nil
	if peek(p).kind == .LParen {
		cols, cerr := parse_name_list(p)
		if has_error(cerr) {
			delete(table, p.allocator)
			return Statement{}, cerr
		}
		columns = cols
	}

	source: Insert_Source
	rows: [][]^Expr = nil
	sel: Select_Stmt

	#partial switch peek(p).kind {
	case .Kw_Values:
		source = .Values
		vals, verr := parse_insert_values(p)
		if has_error(verr) {
			free_insert_partial(table, columns, nil, {}, p.allocator)
			return Statement{}, verr
		}
		rows = vals
	case .Kw_Select:
		source = .Select
		sel_start := peek(p).span
		parsed, serr := parse_select_stmt(p, sel_start)
		if has_error(serr) {
			free_insert_partial(table, columns, nil, {}, p.allocator)
			return Statement{}, serr
		}
		sel = parsed
	case .Kw_Default:
		free_insert_partial(table, columns, nil, {}, p.allocator)
		return Statement{}, make_error(
			peek(p).span,
			"INSERT DEFAULT VALUES is not supported yet",
			code = .Unsupported_Syntax,
			allocator = p.allocator,
		)
	case:
		free_insert_partial(table, columns, nil, {}, p.allocator)
		return Statement{}, make_error(
			peek(p).span,
			"expected VALUES or SELECT after INSERT INTO",
			allocator = p.allocator,
		)
	}

	if peek(p).kind == .Kw_On {
		// ON CONFLICT upsert — deferred
		free_insert_stmt(
			Insert_Stmt{
				table    = table,
				columns  = columns,
				conflict = conflict,
				source   = source,
				rows     = rows,
				select   = sel,
			},
			p.allocator,
		)
		return Statement{}, make_error(
			peek(p).span,
			"ON CONFLICT upsert is not supported yet",
			code = .Unsupported_Syntax,
			allocator = p.allocator,
		)
	}

	end := peek(p).span.offset
	if p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		end = prev.span.offset + prev.span.length
	}
	stmt_span := start
	stmt_span.length = end - start.offset

	return Statement{
		kind = .Insert,
		span = stmt_span,
		data = Insert_Stmt{
			table    = table,
			columns  = columns,
			conflict = conflict,
			source   = source,
			rows     = rows,
			select   = sel,
		},
	}, ok_error()
}

parse_insert_values :: proc(p: ^Parser) -> ([][]^Expr, Parse_Error) {
	next(p) // VALUES
	rows := make([dynamic][]^Expr, p.allocator)
	for {
		_, err := expect(p, .LParen)
		if has_error(err) {
			free_insert_rows(rows[:], p.allocator)
			delete(rows)
			return nil, err
		}
		values := make([dynamic]^Expr, p.allocator)
		if peek(p).kind == .RParen {
			delete(values)
			free_insert_rows(rows[:], p.allocator)
			delete(rows)
			return nil, make_error(
				peek(p).span,
				"VALUES row must contain at least one expression",
				code = .Empty_List,
				allocator = p.allocator,
			)
		}
		for {
			expr, eerr := parse_or_expr(p)
			if has_error(eerr) {
				for v in values {
					free_expr(v, p.allocator)
				}
				delete(values)
				free_insert_rows(rows[:], p.allocator)
				delete(rows)
				return nil, eerr
			}
			append(&values, expr)
			if peek(p).kind == .Comma {
				next(p)
				continue
			}
			break
		}
		_, err2 := expect(p, .RParen)
		if has_error(err2) {
			for v in values {
				free_expr(v, p.allocator)
			}
			delete(values)
			free_insert_rows(rows[:], p.allocator)
			delete(rows)
			return nil, err2
		}
		append(&rows, values[:])
		if peek(p).kind == .Comma {
			next(p)
			continue
		}
		break
	}
	return rows[:], ok_error()
}

parse_update :: proc(p: ^Parser, start: Span) -> (Statement, Parse_Error) {
	next(p) // UPDATE

	if peek(p).kind == .Kw_Or {
		return Statement{}, make_error(
			peek(p).span,
			"UPDATE OR conflict clauses are not supported yet",
			code = .Unsupported_Syntax,
			allocator = p.allocator,
		)
	}

	table, _, terr := parse_object_name(p)
	if has_error(terr) {
		return Statement{}, terr
	}

	_, err := expect(p, .Kw_Set)
	if has_error(err) {
		delete(table, p.allocator)
		return Statement{}, err
	}

	sets, serr := parse_assignments(p)
	if has_error(serr) {
		delete(table, p.allocator)
		return Statement{}, serr
	}

	where_expr: ^Expr = nil
	if peek(p).kind == .Kw_Where {
		next(p)
		expr, werr := parse_or_expr(p)
		if has_error(werr) {
			free_assignments(sets, p.allocator)
			delete(sets, p.allocator)
			delete(table, p.allocator)
			return Statement{}, werr
		}
		where_expr = expr
	}

	end := peek(p).span.offset
	if p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		end = prev.span.offset + prev.span.length
	}
	stmt_span := start
	stmt_span.length = end - start.offset

	return Statement{
		kind = .Update,
		span = stmt_span,
		data = Update_Stmt{
			table      = table,
			sets       = sets,
			where_expr = where_expr,
		},
	}, ok_error()
}

parse_assignments :: proc(p: ^Parser) -> ([]Assignment, Parse_Error) {
	list := make([dynamic]Assignment, p.allocator)
	for {
		start := peek(p).span
		col_tok, err := expect(p, .Ident)
		if has_error(err) {
			free_assignments(list[:], p.allocator)
			delete(list)
			return nil, err
		}
		_, err2 := expect(p, .Eq)
		if has_error(err2) {
			free_assignments(list[:], p.allocator)
			delete(list)
			return nil, err2
		}
		expr, eerr := parse_or_expr(p)
		if has_error(eerr) {
			free_assignments(list[:], p.allocator)
			delete(list)
			return nil, eerr
		}
		span := start
		span.length = (expr.span.offset + expr.span.length) - start.offset
		append(&list, Assignment{
			column = clone_ident_name(col_tok.text, p.allocator),
			value  = expr,
			span   = span,
		})
		if peek(p).kind == .Comma {
			next(p)
			continue
		}
		break
	}
	return list[:], ok_error()
}

parse_delete :: proc(p: ^Parser, start: Span) -> (Statement, Parse_Error) {
	next(p) // DELETE
	_, err := expect(p, .Kw_From)
	if has_error(err) {
		return Statement{}, err
	}

	table, _, terr := parse_object_name(p)
	if has_error(terr) {
		return Statement{}, terr
	}

	where_expr: ^Expr = nil
	if peek(p).kind == .Kw_Where {
		next(p)
		expr, werr := parse_or_expr(p)
		if has_error(werr) {
			delete(table, p.allocator)
			return Statement{}, werr
		}
		where_expr = expr
	}

	end := peek(p).span.offset
	if p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		end = prev.span.offset + prev.span.length
	}
	stmt_span := start
	stmt_span.length = end - start.offset

	return Statement{
		kind = .Delete,
		span = stmt_span,
		data = Delete_Stmt{
			table      = table,
			where_expr = where_expr,
		},
	}, ok_error()
}

free_insert_rows :: proc(rows: [][]^Expr, allocator: mem.Allocator) {
	for row in rows {
		for v in row {
			free_expr(v, allocator)
		}
		delete(row, allocator)
	}
}

free_insert_partial :: proc(
	table: string,
	columns: []string,
	rows: [][]^Expr,
	sel: Select_Stmt,
	allocator: mem.Allocator,
) {
	delete(table, allocator)
	for c in columns {
		delete(c, allocator)
	}
	delete(columns, allocator)
	free_insert_rows(rows, allocator)
	delete(rows, allocator)
	_ = sel // callers only pass empty Select_Stmt here
}

free_insert_stmt :: proc(stmt: Insert_Stmt, allocator: mem.Allocator) {
	delete(stmt.table, allocator)
	for c in stmt.columns {
		delete(c, allocator)
	}
	delete(stmt.columns, allocator)
	if stmt.source == .Values {
		free_insert_rows(stmt.rows, allocator)
		delete(stmt.rows, allocator)
	} else if stmt.source == .Select {
		free_select_stmt(stmt.select, allocator)
	}
}

free_assignments :: proc(sets: []Assignment, allocator: mem.Allocator) {
	for a in sets {
		delete(a.column, allocator)
		free_expr(a.value, allocator)
	}
}

free_update_stmt :: proc(stmt: Update_Stmt, allocator: mem.Allocator) {
	delete(stmt.table, allocator)
	free_assignments(stmt.sets, allocator)
	delete(stmt.sets, allocator)
	free_expr(stmt.where_expr, allocator)
}

free_delete_stmt :: proc(stmt: Delete_Stmt, allocator: mem.Allocator) {
	delete(stmt.table, allocator)
	free_expr(stmt.where_expr, allocator)
}
