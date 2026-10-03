package sql

import "core:mem"
import "core:strings"

parse_select :: proc(p: ^Parser, start: Span) -> (Statement, Parse_Error) {
	sel, err := parse_select_stmt(p, start)
	if has_error(err) {
		return Statement{}, err
	}
	end := peek(p).span.offset
	if p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		end = prev.span.offset + prev.span.length
	}
	stmt_span := start
	stmt_span.length = end - start.offset
	return Statement{kind = .Select, span = stmt_span, data = sel}, ok_error()
}

parse_select_stmt :: proc(p: ^Parser, start: Span) -> (Select_Stmt, Parse_Error) {
	next(p) // SELECT

	is_distinct := false
	if peek(p).kind == .Kw_Distinct {
		next(p)
		is_distinct = true
	} else if peek(p).kind == .Kw_All {
		next(p)
	}

	projection, perr := parse_select_projection(p)
	if has_error(perr) {
		return {}, perr
	}

	_, ferr := expect(p, .Kw_From)
	if has_error(ferr) {
		free_select_items(projection, p.allocator)
		delete(projection, p.allocator)
		return {}, ferr
	}

	from, from_err := parse_from_item(p)
	if has_error(from_err) {
		free_select_items(projection, p.allocator)
		delete(projection, p.allocator)
		return {}, from_err
	}

	joins, jerr := parse_join_list(p)
	if has_error(jerr) {
		free_select_items(projection, p.allocator)
		delete(projection, p.allocator)
		delete(from.table, p.allocator)
		delete(from.alias, p.allocator)
		return {}, jerr
	}

	where_expr: ^Expr = nil
	if peek(p).kind == .Kw_Where {
		next(p)
		expr, werr := parse_or_expr(p)
		if has_error(werr) {
			free_select_items(projection, p.allocator)
			delete(projection, p.allocator)
			delete(from.table, p.allocator)
			delete(from.alias, p.allocator)
			free_join_clauses(joins, p.allocator)
			delete(joins, p.allocator)
			return {}, werr
		}
		where_expr = expr
	}

	group_by: []^Expr = nil
	having: ^Expr = nil
	if peek(p).kind == .Kw_Group {
		gb, gerr := parse_group_by(p)
		if has_error(gerr) {
			free_select_core(projection, from, joins, where_expr, nil, nil, nil, nil, nil, p.allocator)
			return {}, gerr
		}
		group_by = gb
		if peek(p).kind == .Kw_Having {
			next(p)
			hexpr, herr := parse_or_expr(p)
			if has_error(herr) {
				free_select_core(projection, from, joins, where_expr, group_by, nil, nil, nil, nil, p.allocator)
				return {}, herr
			}
			having = hexpr
		}
	} else if peek(p).kind == .Kw_Having {
		free_select_core(projection, from, joins, where_expr, nil, nil, nil, nil, nil, p.allocator)
		return {}, make_error(
			peek(p).span,
			"HAVING requires GROUP BY",
			allocator = p.allocator,
		)
	}

	order_by: []Order_By_Item = nil
	if peek(p).kind == .Kw_Order {
		items, oerr := parse_order_by(p)
		if has_error(oerr) {
			free_select_core(projection, from, joins, where_expr, group_by, having, nil, nil, nil, p.allocator)
			return {}, oerr
		}
		order_by = items
	}

	if peek(p).kind == .Kw_Union || peek(p).kind == .Kw_Intersect || peek(p).kind == .Kw_Except {
		free_select_core(projection, from, joins, where_expr, group_by, having, order_by, nil, nil, p.allocator)
		return {}, make_error(
			peek(p).span,
			"set operations (UNION/INTERSECT/EXCEPT) are not supported yet",
			code = .Unsupported_Syntax,
			allocator = p.allocator,
		)
	}

	limit: ^Expr = nil
	offset: ^Expr = nil
	if peek(p).kind == .Kw_Limit {
		next(p)
		lim, lerr := parse_or_expr(p)
		if has_error(lerr) {
			free_select_core(projection, from, joins, where_expr, group_by, having, order_by, nil, nil, p.allocator)
			return {}, lerr
		}
		limit = lim
		if peek(p).kind == .Kw_Offset {
			next(p)
			off, oerr := parse_or_expr(p)
			if has_error(oerr) {
				free_select_core(projection, from, joins, where_expr, group_by, having, order_by, limit, nil, p.allocator)
				return {}, oerr
			}
			offset = off
		} else if peek(p).kind == .Comma {
			free_select_core(projection, from, joins, where_expr, group_by, having, order_by, limit, nil, p.allocator)
			return {}, make_error(
				peek(p).span,
				"LIMIT offset, count form is not supported; use LIMIT n OFFSET m",
				code = .Unsupported_Syntax,
				allocator = p.allocator,
			)
		}
	}

	_ = start
	return Select_Stmt{
		is_distinct = is_distinct,
		projection  = projection,
		from        = from,
		joins       = joins,
		where_expr  = where_expr,
		group_by    = group_by,
		having      = having,
		order_by    = order_by,
		limit       = limit,
		offset      = offset,
	}, ok_error()
}

parse_join_list :: proc(p: ^Parser) -> ([]Join_Clause, Parse_Error) {
	joins := make([dynamic]Join_Clause, p.allocator)
	for {
		if peek(p).kind == .Comma {
			start := peek(p).span
			next(p)
			right, err := parse_from_item(p)
			if has_error(err) {
				free_join_clauses(joins[:], p.allocator)
				delete(joins)
				return nil, err
			}
			span := start
			span.length = (right.span.offset + right.span.length) - start.offset
			append(&joins, Join_Clause{kind = .Cross, table = right, span = span})
			continue
		}
		if !is_join_start(peek(p).kind) {
			break
		}
		join, jerr := parse_join_clause(p)
		if has_error(jerr) {
			free_join_clauses(joins[:], p.allocator)
			delete(joins)
			return nil, jerr
		}
		append(&joins, join)
	}
	return joins[:], ok_error()
}

parse_join_clause :: proc(p: ^Parser) -> (Join_Clause, Parse_Error) {
	start := peek(p).span
	kind, kerr := parse_join_kind(p)
	if has_error(kerr) {
		return {}, kerr
	}

	table, terr := parse_from_item(p)
	if has_error(terr) {
		return {}, terr
	}

	on: ^Expr = nil
	using_cols: []string = nil

	#partial switch peek(p).kind {
	case .Kw_On:
		next(p)
		expr, eerr := parse_or_expr(p)
		if has_error(eerr) {
			delete(table.table, p.allocator)
			delete(table.alias, p.allocator)
			return {}, eerr
		}
		on = expr
	case .Kw_Using:
		next(p)
		cols, cerr := parse_name_list(p)
		if has_error(cerr) {
			delete(table.table, p.allocator)
			delete(table.alias, p.allocator)
			return {}, cerr
		}
		using_cols = cols
	case:
		if kind != .Cross {
			delete(table.table, p.allocator)
			delete(table.alias, p.allocator)
			return {}, make_error(
				peek(p).span,
				"expected ON or USING after JOIN",
				allocator = p.allocator,
			)
		}
	}

	span := start
	if p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		span.length = (prev.span.offset + prev.span.length) - start.offset
	}
	return Join_Clause{
		kind       = kind,
		table      = table,
		on         = on,
		using_cols = using_cols,
		span       = span,
	}, ok_error()
}

parse_join_kind :: proc(p: ^Parser) -> (Join_Kind, Parse_Error) {
	#partial switch peek(p).kind {
	case .Kw_Cross:
		next(p)
		_, err := expect(p, .Kw_Join)
		if has_error(err) {
			return {}, err
		}
		return .Cross, ok_error()
	case .Kw_Inner:
		next(p)
		_, err := expect(p, .Kw_Join)
		if has_error(err) {
			return {}, err
		}
		return .Inner, ok_error()
	case .Kw_Left:
		next(p)
		if peek(p).kind == .Kw_Outer {
			next(p)
		}
		_, err := expect(p, .Kw_Join)
		if has_error(err) {
			return {}, err
		}
		return .Left, ok_error()
	case .Kw_Join:
		next(p)
		return .Inner, ok_error()
	case .Kw_Right, .Kw_Full, .Kw_Natural:
		return {}, make_error(
			peek(p).span,
			"RIGHT/FULL/NATURAL joins are not supported yet",
			code = .Unsupported_Syntax,
			allocator = p.allocator,
		)
	case .Kw_Outer:
		return {}, make_error(
			peek(p).span,
			"expected LEFT OUTER JOIN (OUTER alone is invalid)",
			allocator = p.allocator,
		)
	}
	return {}, make_error(
		peek(p).span,
		"expected JOIN",
		allocator = p.allocator,
	)
}

parse_group_by :: proc(p: ^Parser) -> ([]^Expr, Parse_Error) {
	next(p) // GROUP
	_, err := expect(p, .Kw_By)
	if has_error(err) {
		return nil, err
	}
	exprs := make([dynamic]^Expr, p.allocator)
	for {
		expr, eerr := parse_or_expr(p)
		if has_error(eerr) {
			for e in exprs {
				free_expr(e, p.allocator)
			}
			delete(exprs)
			return nil, eerr
		}
		append(&exprs, expr)
		if peek(p).kind == .Comma {
			next(p)
			continue
		}
		break
	}
	return exprs[:], ok_error()
}

parse_select_projection :: proc(p: ^Parser) -> ([]Select_Item, Parse_Error) {
	items := make([dynamic]Select_Item, p.allocator)
	for {
		item, err := parse_select_item(p)
		if has_error(err) {
			free_select_items(items[:], p.allocator)
			delete(items)
			return nil, err
		}
		append(&items, item)
		if peek(p).kind == .Comma {
			next(p)
			continue
		}
		break
	}
	return items[:], ok_error()
}

parse_select_item :: proc(p: ^Parser) -> (Select_Item, Parse_Error) {
	start := peek(p).span

	if peek(p).kind == .Star {
		star := next(p)
		return Select_Item{kind = .Star, span = star.span}, ok_error()
	}

	if peek(p).kind == .Ident &&
	   p.pos + 2 < len(p.tokens) &&
	   p.tokens[p.pos + 1].kind == .Dot &&
	   p.tokens[p.pos + 2].kind == .Star {
		tbl := next(p)
		next(p)
		star := next(p)
		span := start
		span.length = (star.span.offset + star.span.length) - start.offset
		return Select_Item{
			kind  = .Table_Star,
			table = clone_ident_name(tbl.text, p.allocator),
			span  = span,
		}, ok_error()
	}

	expr, err := parse_or_expr(p)
	if has_error(err) {
		return {}, err
	}

	alias := ""
	if peek(p).kind == .Kw_As {
		next(p)
		atok, aerr := expect(p, .Ident)
		if has_error(aerr) {
			free_expr(expr, p.allocator)
			return {}, aerr
		}
		alias = clone_ident_name(atok.text, p.allocator)
	} else if peek(p).kind == .Ident {
		name_tok := next(p)
		alias = clone_ident_name(name_tok.text, p.allocator)
	}

	span := start
	if alias != "" && p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		span.length = (prev.span.offset + prev.span.length) - start.offset
	} else {
		span = expr.span
	}

	return Select_Item{
		kind  = .Expr,
		expr  = expr,
		alias = alias,
		span  = span,
	}, ok_error()
}

parse_from_item :: proc(p: ^Parser) -> (From_Item, Parse_Error) {
	start := peek(p).span
	name, name_span, nerr := parse_object_name(p)
	if has_error(nerr) {
		return {}, nerr
	}

	alias := ""
	if peek(p).kind == .Kw_As {
		next(p)
		atok, aerr := expect(p, .Ident)
		if has_error(aerr) {
			delete(name, p.allocator)
			return {}, aerr
		}
		alias = clone_ident_name(atok.text, p.allocator)
	} else if peek(p).kind == .Ident {
		atok := next(p)
		alias = clone_ident_name(atok.text, p.allocator)
	}

	span := name_span
	if alias != "" && p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		span.length = (prev.span.offset + prev.span.length) - start.offset
	}

	return From_Item{table = name, alias = alias, span = span}, ok_error()
}

parse_order_by :: proc(p: ^Parser) -> ([]Order_By_Item, Parse_Error) {
	next(p) // ORDER
	_, err := expect(p, .Kw_By)
	if has_error(err) {
		return nil, err
	}

	items := make([dynamic]Order_By_Item, p.allocator)
	for {
		start := peek(p).span
		expr, eerr := parse_or_expr(p)
		if has_error(eerr) {
			free_order_by_items(items[:], p.allocator)
			delete(items)
			return nil, eerr
		}
		desc := false
		if peek(p).kind == .Kw_Desc {
			next(p)
			desc = true
		} else if peek(p).kind == .Kw_Asc {
			next(p)
		}
		span := start
		if p.pos > 0 {
			prev := p.tokens[p.pos - 1]
			span.length = (prev.span.offset + prev.span.length) - start.offset
		}
		append(&items, Order_By_Item{expr = expr, desc = desc, span = span})
		if peek(p).kind == .Comma {
			next(p)
			continue
		}
		break
	}
	return items[:], ok_error()
}

is_join_start :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Kw_Join, .Kw_Inner, .Kw_Left, .Kw_Right, .Kw_Full, .Kw_Cross, .Kw_Natural, .Kw_Outer:
		return true
	}
	return false
}

free_select_items :: proc(items: []Select_Item, allocator: mem.Allocator) {
	for item in items {
		#partial switch item.kind {
		case .Expr:
			free_expr(item.expr, allocator)
			delete(item.alias, allocator)
		case .Table_Star:
			delete(item.table, allocator)
		case .Star:
		}
	}
}

free_order_by_items :: proc(items: []Order_By_Item, allocator: mem.Allocator) {
	for item in items {
		free_expr(item.expr, allocator)
	}
}

free_join_clauses :: proc(joins: []Join_Clause, allocator: mem.Allocator) {
	for j in joins {
		delete(j.table.table, allocator)
		delete(j.table.alias, allocator)
		free_expr(j.on, allocator)
		for c in j.using_cols {
			delete(c, allocator)
		}
		delete(j.using_cols, allocator)
	}
}

free_group_by :: proc(exprs: []^Expr, allocator: mem.Allocator) {
	for e in exprs {
		free_expr(e, allocator)
	}
}

free_select_core :: proc(
	projection: []Select_Item,
	from: From_Item,
	joins: []Join_Clause,
	where_expr: ^Expr,
	group_by: []^Expr,
	having: ^Expr,
	order_by: []Order_By_Item,
	limit: ^Expr,
	offset: ^Expr,
	allocator: mem.Allocator,
) {
	free_select_items(projection, allocator)
	delete(projection, allocator)
	delete(from.table, allocator)
	delete(from.alias, allocator)
	free_join_clauses(joins, allocator)
	delete(joins, allocator)
	free_expr(where_expr, allocator)
	free_group_by(group_by, allocator)
	delete(group_by, allocator)
	free_expr(having, allocator)
	free_order_by_items(order_by, allocator)
	delete(order_by, allocator)
	free_expr(limit, allocator)
	free_expr(offset, allocator)
}

free_select_stmt :: proc(stmt: Select_Stmt, allocator: mem.Allocator) {
	free_select_core(
		stmt.projection,
		stmt.from,
		stmt.joins,
		stmt.where_expr,
		stmt.group_by,
		stmt.having,
		stmt.order_by,
		stmt.limit,
		stmt.offset,
		allocator,
	)
}
