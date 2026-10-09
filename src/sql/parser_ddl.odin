package sql

import "core:mem"
import "core:strings"

parse_statement_node :: proc(p: ^Parser) -> (Statement, Parse_Error) {
	// Placeholders number per statement (bare `?` restarts at 0 each statement).
	p.next_placeholder = 0
	start := peek(p).span
	#partial switch peek(p).kind {
	case .Kw_Create:
		return parse_create_statement(p, start)
	case .Kw_Drop:
		return parse_drop_statement(p, start)
	case .Kw_Alter:
		return parse_alter_table(p, start)
	case .Kw_Select:
		return parse_select(p, start)
	case .Kw_Insert:
		return parse_insert(p, start)
	case .Kw_Update:
		return parse_update(p, start)
	case .Kw_Delete:
		return parse_delete(p, start)
	case .Kw_Begin:
		return parse_begin(p, start)
	case .Kw_Commit:
		return parse_commit(p, start)
	case .Kw_Rollback:
		return parse_rollback(p, start)
	}
	tok := peek(p)
	return Statement{}, make_error(
		tok.span,
		"expected statement (CREATE, DROP, ALTER, SELECT, INSERT, UPDATE, DELETE, BEGIN, COMMIT, or ROLLBACK), got %s",
		token_kind_string(tok.kind),
		allocator = p.allocator,
	)
}

parse_optional_transaction :: proc(p: ^Parser) {
	if peek(p).kind == .Kw_Transaction {
		next(p)
	}
}

txn_stmt_span :: proc(p: ^Parser, start: Span) -> Span {
	end := peek(p).span.offset
	if p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		end = prev.span.offset + prev.span.length
	}
	stmt_span := start
	stmt_span.length = end - start.offset
	return stmt_span
}

parse_begin :: proc(p: ^Parser, start: Span) -> (Statement, Parse_Error) {
	next(p) // BEGIN
	parse_optional_transaction(p)
	return Statement{
		kind = .Begin,
		span = txn_stmt_span(p, start),
		data = Begin_Stmt{},
	}, ok_error()
}

parse_commit :: proc(p: ^Parser, start: Span) -> (Statement, Parse_Error) {
	next(p) // COMMIT
	parse_optional_transaction(p)
	return Statement{
		kind = .Commit,
		span = txn_stmt_span(p, start),
		data = Commit_Stmt{},
	}, ok_error()
}

parse_rollback :: proc(p: ^Parser, start: Span) -> (Statement, Parse_Error) {
	next(p) // ROLLBACK
	parse_optional_transaction(p)
	return Statement{
		kind = .Rollback,
		span = txn_stmt_span(p, start),
		data = Rollback_Stmt{},
	}, ok_error()
}

parse_create_statement :: proc(p: ^Parser, start: Span) -> (Statement, Parse_Error) {
	next(p) // CREATE
	#partial switch peek(p).kind {
	case .Kw_Table:
		return parse_create_table(p, start)
	case .Kw_Unique:
		next(p) // UNIQUE
		if peek(p).kind != .Kw_Index {
			return Statement{}, make_error(
				peek(p).span,
				"expected INDEX after CREATE UNIQUE",
				allocator = p.allocator,
			)
		}
		return parse_create_index(p, start, unique = true)
	case .Kw_Index:
		return parse_create_index(p, start, unique = false)
	case:
		return Statement{}, make_error(
			peek(p).span,
			"expected TABLE, INDEX, or UNIQUE INDEX after CREATE",
			allocator = p.allocator,
		)
	}
}

parse_drop_statement :: proc(p: ^Parser, start: Span) -> (Statement, Parse_Error) {
	next(p) // DROP
	#partial switch peek(p).kind {
	case .Kw_Table:
		return parse_drop_table(p, start)
	case .Kw_Index:
		return parse_drop_index(p, start)
	case:
		return Statement{}, make_error(
			peek(p).span,
			"expected TABLE or INDEX after DROP",
			allocator = p.allocator,
		)
	}
}

parse_create_table :: proc(p: ^Parser, start: Span) -> (Statement, Parse_Error) {
	next(p) // TABLE
	if_not_exists := false
	if peek(p).kind == .Kw_If {
		next(p)
		_, err := expect(p, .Kw_Not)
		if has_error(err) {
			return Statement{}, err
		}
		_, err2 := expect(p, .Kw_Exists)
		if has_error(err2) {
			return Statement{}, err2
		}
		if_not_exists = true
	}

	name, name_span, nerr := parse_object_name(p)
	if has_error(nerr) {
		return Statement{}, nerr
	}

	_, err := expect(p, .LParen)
	if has_error(err) {
		delete(name, p.allocator)
		return Statement{}, err
	}

	elements := make([dynamic]Table_Element, p.allocator)

	if peek(p).kind != .RParen {
		for {
			elem, elem_span, e := parse_table_element(p)
			if has_error(e) {
				free_table_elements(elements[:], p.allocator)
				delete(name, p.allocator)
				delete(elements)
				return Statement{}, e
			}
			append(&elements, elem)
			_ = elem_span

			if peek(p).kind == .Comma {
				next(p)
				continue
			}
			break
		}
	}

	rparen, err2 := expect(p, .RParen)
	if has_error(err2) {
		free_table_elements(elements[:], p.allocator)
		delete(name, p.allocator)
		delete(elements)
		return Statement{}, err2
	}

	end := rparen.span.offset + rparen.span.length
	stmt_span := start
	stmt_span.length = end - start.offset

	stmt := Statement{
		kind = .Create_Table,
		span = stmt_span,
		data = Create_Table_Stmt{
			name          = name,
			if_not_exists = if_not_exists,
			elements      = elements[:],
		},
	}
	_ = name_span
	return stmt, ok_error()
}

parse_table_element :: proc(p: ^Parser) -> (Table_Element, Span, Parse_Error) {
	start := peek(p).span

	had_constraint_name := false
	if peek(p).kind == .Kw_Constraint {
		next(p)
		_, nerr := expect(p, .Ident)
		if has_error(nerr) {
			return {}, start, nerr
		}
		had_constraint_name = true
		// Name is parse-only for now; body is required below.
	}

	if peek(p).kind == .Kw_Primary {
		tc, err := parse_table_primary_key(p)
		if has_error(err) {
			return {}, start, err
		}
		return Table_Element{kind = .Table_Constraint, table_constraint = tc}, tc.span, ok_error()
	}
	if peek(p).kind == .Kw_Unique && p.pos + 1 < len(p.tokens) && p.tokens[p.pos + 1].kind == .LParen {
		tc, err := parse_table_unique(p)
		if has_error(err) {
			return {}, start, err
		}
		return Table_Element{kind = .Table_Constraint, table_constraint = tc}, tc.span, ok_error()
	}
	if peek(p).kind == .Kw_Check {
		tc, err := parse_table_check(p)
		if has_error(err) {
			return {}, start, err
		}
		return Table_Element{kind = .Table_Constraint, table_constraint = tc}, tc.span, ok_error()
	}
	if peek(p).kind == .Kw_Foreign {
		tc, err := parse_table_foreign_key(p)
		if has_error(err) {
			return {}, start, err
		}
		return Table_Element{kind = .Table_Constraint, table_constraint = tc}, tc.span, ok_error()
	}

	if had_constraint_name {
		return {}, start, make_error(
			peek(p).span,
			"expected table constraint after CONSTRAINT name (PRIMARY KEY, UNIQUE, CHECK, or FOREIGN KEY)",
			allocator = p.allocator,
		)
	}

	col, err := parse_column_def(p)
	if has_error(err) {
		return {}, start, err
	}
	return Table_Element{kind = .Column, column = col}, col.span, ok_error()
}

parse_column_def :: proc(p: ^Parser) -> (Column_Def, Parse_Error) {
	start := peek(p).span
	name_tok, err := expect(p, .Ident)
	if has_error(err) {
		return {}, err
	}
	name := clone_ident_name(name_tok.text, p.allocator)

	type_name, terr := parse_optional_type_name(p)
	if has_error(terr) {
		delete(name, p.allocator)
		return {}, terr
	}

	constraints, cerr := parse_column_constraints(p)
	if has_error(cerr) {
		delete(name, p.allocator)
		delete(type_name, p.allocator)
		return {}, cerr
	}

	end := start.offset
	if len(constraints) > 0 {
		last := constraints[len(constraints) - 1]
		end = last.span.offset + last.span.length
	} else if type_name != "" {
		end = start.offset + len(name_tok.text) + len(type_name) // approximate; use peek
		end = peek(p).span.offset
		if end < start.offset {
			end = name_tok.span.offset + name_tok.span.length
		}
	} else {
		end = name_tok.span.offset + name_tok.span.length
	}
	span := start
	span.length = end - start.offset

	return Column_Def{
		name        = name,
		type_name   = type_name,
		constraints = constraints,
		span        = span,
	}, ok_error()
}

parse_optional_type_name :: proc(p: ^Parser) -> (string, Parse_Error) {
	if !is_type_name_start(peek(p).kind) {
		return "", ok_error()
	}

	b := strings.builder_make(p.allocator)
	for {
		tok := peek(p)
		if tok.kind == .Comma || tok.kind == .RParen {
			break
		}
		if is_column_constraint_start(tok.kind) {
			break
		}
		if tok.kind == .Ident || is_keyword(tok.kind) {
			if strings.builder_len(b) > 0 {
				strings.write_byte(&b, ' ')
			}
			strings.write_string(&b, tok.text)
			next(p)
			if peek(p).kind == .LParen {
				strings.write_byte(&b, '(')
				next(p)
				for {
					if at_end(p) {
						strings.builder_destroy(&b)
						return "", error_at(
							tok.span,
							"unclosed '(' in type name",
							code = .Invalid_Type_Name,
							allocator = p.allocator,
						)
					}
					inner := peek(p)
					#partial switch inner.kind {
					case .RParen:
						strings.write_string(&b, inner.text)
						next(p)
					case .Comma:
						strings.write_string(&b, inner.text)
						next(p)
						continue
					case .Integer, .Float:
						strings.write_string(&b, inner.text)
						next(p)
						continue
					case .Plus, .Minus:
						strings.write_string(&b, inner.text)
						next(p)
						num := peek(p)
						if num.kind != .Integer && num.kind != .Float {
							strings.builder_destroy(&b)
							return "", make_error(
								num.span,
								"expected number after sign in type name parameters",
								code = .Invalid_Type_Name,
								allocator = p.allocator,
							)
						}
						strings.write_string(&b, num.text)
						next(p)
						continue
					case:
						strings.builder_destroy(&b)
						return "", make_error(
							inner.span,
							"unexpected %s inside type name parameters (only numbers and commas allowed)",
							token_kind_string(inner.kind),
							code = .Invalid_Type_Name,
							allocator = p.allocator,
						)
					}
					break // closed )
				}
			}
			continue
		}
		break
	}
	out := strings.clone(strings.to_string(b), p.allocator)
	strings.builder_destroy(&b)
	return out, ok_error()
}

is_type_name_start :: proc(kind: Token_Kind) -> bool {
	return is_type_name_token(kind)
}

is_type_name_token :: proc(kind: Token_Kind) -> bool {
	if kind == .Ident {
		return true
	}
	if is_column_constraint_start(kind) {
		return false
	}
	if is_keyword(kind) {
		// Type names may use keyword spellings (e.g. INT) when not reserved in this position.
		return true
	}
	return false
}

is_column_constraint_start :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Kw_Primary, .Kw_Not, .Kw_Unique, .Kw_Default, .Kw_Check, .Kw_References, .Kw_Constraint:
		return true
	}
	return false
}

parse_column_constraints :: proc(p: ^Parser) -> ([]Column_Constraint, Parse_Error) {
	list := make([dynamic]Column_Constraint, p.allocator)
	for is_column_constraint_start(peek(p).kind) {
		if peek(p).kind == .Kw_Unique &&
		   p.pos + 1 < len(p.tokens) &&
		   p.tokens[p.pos + 1].kind == .LParen {
			break
		}
		start := peek(p).span
		#partial switch peek(p).kind {
		case .Kw_Primary:
			next(p)
			_, err := expect(p, .Kw_Key)
			if has_error(err) {
				free_column_constraints(list[:], p.allocator)
				delete(list)
				return nil, err
			}
			end := peek(p).span.offset
			span := start
			span.length = end - start.offset
			append(&list, Column_Constraint{kind = .Primary_Key, span = span})
		case .Kw_Not:
			next(p)
			null_tok, err := expect(p, .Kw_Null)
			if has_error(err) {
				free_column_constraints(list[:], p.allocator)
				delete(list)
				return nil, err
			}
			span := start
			span.length = (null_tok.span.offset + null_tok.span.length) - start.offset
			append(&list, Column_Constraint{kind = .Not_Null, span = span})
		case .Kw_Unique:
			uniq := next(p)
			span := start
			span.length = (uniq.span.offset + uniq.span.length) - start.offset
			append(&list, Column_Constraint{kind = .Unique, span = span})
		case .Kw_Default:
			next(p)
			expr, err := parse_or_expr(p)
			if has_error(err) {
				free_column_constraints(list[:], p.allocator)
				delete(list)
				return nil, err
			}
			span := start
			span.length = (expr.span.offset + expr.span.length) - start.offset
			append(&list, Column_Constraint{kind = .Default, default_expr = expr, span = span})
		case .Kw_Constraint:
			next(p)
			_, nerr := expect(p, .Ident)
			if has_error(nerr) {
				free_column_constraints(list[:], p.allocator)
				delete(list)
				return nil, nerr
			}
			if !is_column_constraint_start(peek(p).kind) || peek(p).kind == .Kw_Constraint {
				free_column_constraints(list[:], p.allocator)
				delete(list)
				return nil, make_error(
					peek(p).span,
					"expected constraint after CONSTRAINT name (PRIMARY KEY, NOT NULL, UNIQUE, DEFAULT, CHECK, or REFERENCES)",
					allocator = p.allocator,
				)
			}
			continue
		case .Kw_Check:
			cc, cerr := parse_column_check(p, start)
			if has_error(cerr) {
				free_column_constraints(list[:], p.allocator)
				delete(list)
				return nil, cerr
			}
			append(&list, cc)
		case .Kw_References:
			cc, rerr := parse_column_references(p, start)
			if has_error(rerr) {
				free_column_constraints(list[:], p.allocator)
				delete(list)
				return nil, rerr
			}
			append(&list, cc)
		case:
			free_column_constraints(list[:], p.allocator)
			delete(list)
			return nil, make_error(
				start,
				"unsupported column constraint %s",
				token_kind_string(peek(p).kind),
				allocator = p.allocator,
			)
		}
	}
	return list[:], ok_error()
}

parse_column_check :: proc(p: ^Parser, start: Span) -> (Column_Constraint, Parse_Error) {
	next(p) // CHECK
	_, err := expect(p, .LParen)
	if has_error(err) {
		return {}, err
	}
	expr, eerr := parse_or_expr(p)
	if has_error(eerr) {
		return {}, eerr
	}
	rparen, rerr := expect(p, .RParen)
	if has_error(rerr) {
		free_expr(expr, p.allocator)
		return {}, rerr
	}
	span := start
	span.length = (rparen.span.offset + rparen.span.length) - start.offset
	return Column_Constraint{kind = .Check, check_expr = expr, span = span}, ok_error()
}

parse_column_references :: proc(p: ^Parser, start: Span) -> (Column_Constraint, Parse_Error) {
	next(p) // REFERENCES
	fk, ferr := parse_foreign_key_ref(p)
	if has_error(ferr) {
		return {}, ferr
	}
	span := start
	if p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		span.length = (prev.span.offset + prev.span.length) - start.offset
	}
	return Column_Constraint{kind = .References, references = fk, span = span}, ok_error()
}

parse_foreign_key_ref :: proc(p: ^Parser) -> (Foreign_Key_Ref, Parse_Error) {
	table, _, terr := parse_object_name(p)
	if has_error(terr) {
		return {}, terr
	}
	cols: []string = nil
	if peek(p).kind == .LParen {
		c, cerr := parse_name_list(p)
		if has_error(cerr) {
			delete(table, p.allocator)
			return {}, cerr
		}
		cols = c
	}
	return Foreign_Key_Ref{table = table, columns = cols}, ok_error()
}

parse_table_check :: proc(p: ^Parser) -> (Table_Constraint, Parse_Error) {
	start := peek(p).span
	next(p) // CHECK
	_, err := expect(p, .LParen)
	if has_error(err) {
		return {}, err
	}
	expr, eerr := parse_or_expr(p)
	if has_error(eerr) {
		return {}, eerr
	}
	rparen, rerr := expect(p, .RParen)
	if has_error(rerr) {
		free_expr(expr, p.allocator)
		return {}, rerr
	}
	span := start
	span.length = (rparen.span.offset + rparen.span.length) - start.offset
	return Table_Constraint{kind = .Check, check_expr = expr, span = span}, ok_error()
}

parse_table_foreign_key :: proc(p: ^Parser) -> (Table_Constraint, Parse_Error) {
	start := peek(p).span
	next(p) // FOREIGN
	_, err := expect(p, .Kw_Key)
	if has_error(err) {
		return {}, err
	}
	cols, cerr := parse_name_list(p)
	if has_error(cerr) {
		return {}, cerr
	}
	_, rerr := expect(p, .Kw_References)
	if has_error(rerr) {
		for c in cols {
			delete(c, p.allocator)
		}
		delete(cols, p.allocator)
		return {}, rerr
	}
	fk, ferr := parse_foreign_key_ref(p)
	if has_error(ferr) {
		for c in cols {
			delete(c, p.allocator)
		}
		delete(cols, p.allocator)
		return {}, ferr
	}
	span := start
	if p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		span.length = (prev.span.offset + prev.span.length) - start.offset
	}
	return Table_Constraint{
		kind       = .Foreign_Key,
		columns    = cols,
		references = fk,
		span       = span,
	}, ok_error()
}

parse_alter_table :: proc(p: ^Parser, start: Span) -> (Statement, Parse_Error) {
	next(p) // ALTER
	_, err := expect(p, .Kw_Table)
	if has_error(err) {
		return Statement{}, err
	}
	table, _, terr := parse_object_name(p)
	if has_error(terr) {
		return Statement{}, terr
	}
	if peek(p).kind != .Kw_Add {
		delete(table, p.allocator)
		return Statement{}, make_error(
			peek(p).span,
			"only ALTER TABLE ADD COLUMN is supported",
			allocator = p.allocator,
		)
	}
	next(p) // ADD
	if peek(p).kind == .Kw_Column {
		next(p)
	}
	col, cerr := parse_column_def(p)
	if has_error(cerr) {
		delete(table, p.allocator)
		return Statement{}, cerr
	}
	end := peek(p).span.offset
	if p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		end = prev.span.offset + prev.span.length
	}
	stmt_span := start
	stmt_span.length = end - start.offset
	return Statement{
		kind = .Alter_Table,
		span = stmt_span,
		data = Alter_Table_Stmt{table = table, column = col},
	}, ok_error()
}

parse_table_primary_key :: proc(p: ^Parser) -> (Table_Constraint, Parse_Error) {
	start := peek(p).span
	next(p) // PRIMARY
	_, err := expect(p, .Kw_Key)
	if has_error(err) {
		return {}, err
	}
	cols, cerr := parse_name_list(p)
	if has_error(cerr) {
		return {}, cerr
	}
	span := start
	if len(cols) > 0 {
		last_tok := peek(p)
		_ = last_tok
	}
	span.length = (peek(p).span.offset) - start.offset
	if p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		span.length = (prev.span.offset + prev.span.length) - start.offset
	}
	return Table_Constraint{kind = .Primary_Key, columns = cols, span = span}, ok_error()
}

parse_table_unique :: proc(p: ^Parser) -> (Table_Constraint, Parse_Error) {
	start := peek(p).span
	next(p) // UNIQUE
	cols, err := parse_name_list(p)
	if has_error(err) {
		return {}, err
	}
	span := start
	if p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		span.length = (prev.span.offset + prev.span.length) - start.offset
	}
	return Table_Constraint{kind = .Unique, columns = cols, span = span}, ok_error()
}

parse_name_list :: proc(p: ^Parser) -> ([]string, Parse_Error) {
	_, err := expect(p, .LParen)
	if has_error(err) {
		return nil, err
	}
	if peek(p).kind == .RParen {
		return nil, make_error(
			peek(p).span,
			"expected at least one name inside parentheses",
			code = .Empty_List,
			allocator = p.allocator,
		)
	}
	names := make([dynamic]string, p.allocator)
	for {
		name, _, nerr := parse_object_name(p)
		if has_error(nerr) {
			for n in names {
				delete(n, p.allocator)
			}
			delete(names)
			return nil, nerr
		}
		append(&names, name)
		if peek(p).kind == .Comma {
			next(p)
			continue
		}
		break
	}
	_, err2 := expect(p, .RParen)
	if has_error(err2) {
		for n in names {
			delete(n, p.allocator)
		}
		delete(names)
		return nil, err2
	}
	return names[:], ok_error()
}

parse_object_name :: proc(p: ^Parser) -> (string, Span, Parse_Error) {
	tok := peek(p)
	if tok.kind != .Ident {
		return "", tok.span, make_error(
			tok.span,
			"expected identifier, got %s",
			token_kind_string(tok.kind),
			allocator = p.allocator,
		)
	}
	next(p)
	segments := make([dynamic]string, p.allocator)
	append(&segments, clone_ident_name(tok.text, p.allocator))
	span := tok.span

	for peek(p).kind == .Dot {
		next(p)
		part, err := expect(p, .Ident)
		if has_error(err) {
			for s in segments {
				delete(s, p.allocator)
			}
			delete(segments)
			return "", span, err
		}
		append(&segments, clone_ident_name(part.text, p.allocator))
		span.length = (part.span.offset + part.span.length) - span.offset
	}

	name := join_segments(segments[:], p.allocator)
	for s in segments {
		delete(s, p.allocator)
	}
	delete(segments)
	return name, span, ok_error()
}

parse_create_index :: proc(p: ^Parser, start: Span, unique := false) -> (Statement, Parse_Error) {
	next(p) // INDEX
	if_not_exists := false
	if peek(p).kind == .Kw_If {
		next(p)
		_, err := expect(p, .Kw_Not)
		if has_error(err) {
			return Statement{}, err
		}
		_, err2 := expect(p, .Kw_Exists)
		if has_error(err2) {
			return Statement{}, err2
		}
		if_not_exists = true
	}

	idx_name, _, nerr := parse_object_name(p)
	if has_error(nerr) {
		return Statement{}, nerr
	}
	_, err := expect(p, .Kw_On)
	if has_error(err) {
		delete(idx_name, p.allocator)
		return Statement{}, err
	}
	table_name, _, terr := parse_object_name(p)
	if has_error(terr) {
		delete(idx_name, p.allocator)
		return Statement{}, terr
	}

	cols, cerr := parse_index_column_list(p)
	if has_error(cerr) {
		delete(idx_name, p.allocator)
		delete(table_name, p.allocator)
		return Statement{}, cerr
	}

	end := peek(p).span.offset
	if p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		end = prev.span.offset + prev.span.length
	}
	stmt_span := start
	stmt_span.length = end - start.offset

	return Statement{
		kind = .Create_Index,
		span = stmt_span,
		data = Create_Index_Stmt{
			name          = idx_name,
			table_name    = table_name,
			if_not_exists = if_not_exists,
			unique        = unique,
			columns       = cols,
		},
	}, ok_error()
}

parse_index_column_list :: proc(p: ^Parser) -> ([]Index_Column, Parse_Error) {
	_, err := expect(p, .LParen)
	if has_error(err) {
		return nil, err
	}
	if peek(p).kind == .RParen {
		return nil, make_error(
			peek(p).span,
			"expected at least one column in index column list",
			code = .Empty_List,
			allocator = p.allocator,
		)
	}
	cols := make([dynamic]Index_Column, p.allocator)
	for {
		name, _, nerr := parse_object_name(p)
		if has_error(nerr) {
			free_index_columns(cols[:], p.allocator)
			delete(cols)
			return nil, nerr
		}
		desc := false
		if peek(p).kind == .Kw_Desc {
			next(p)
			desc = true
		} else if peek(p).kind == .Kw_Asc {
			next(p)
		}
		append(&cols, Index_Column{name = name, desc = desc})
		if peek(p).kind == .Comma {
			next(p)
			continue
		}
		break
	}
	_, err2 := expect(p, .RParen)
	if has_error(err2) {
		free_index_columns(cols[:], p.allocator)
		delete(cols)
		return nil, err2
	}
	return cols[:], ok_error()
}

parse_drop_table :: proc(p: ^Parser, start: Span) -> (Statement, Parse_Error) {
	next(p) // TABLE
	if_exists := false
	if peek(p).kind == .Kw_If {
		next(p)
		_, err := expect(p, .Kw_Exists)
		if has_error(err) {
			return Statement{}, err
		}
		if_exists = true
	}
	name, _, nerr := parse_object_name(p)
	if has_error(nerr) {
		return Statement{}, nerr
	}
	end := peek(p).span.offset
	if p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		end = prev.span.offset + prev.span.length
	}
	stmt_span := start
	stmt_span.length = end - start.offset
	return Statement{
		kind = .Drop_Table,
		span = stmt_span,
		data = Drop_Table_Stmt{name = name, if_exists = if_exists},
	}, ok_error()
}

parse_drop_index :: proc(p: ^Parser, start: Span) -> (Statement, Parse_Error) {
	next(p) // INDEX
	if_exists := false
	if peek(p).kind == .Kw_If {
		next(p)
		_, err := expect(p, .Kw_Exists)
		if has_error(err) {
			return Statement{}, err
		}
		if_exists = true
	}
	name, _, nerr := parse_object_name(p)
	if has_error(nerr) {
		return Statement{}, nerr
	}
	end := peek(p).span.offset
	if p.pos > 0 {
		prev := p.tokens[p.pos - 1]
		end = prev.span.offset + prev.span.length
	}
	stmt_span := start
	stmt_span.length = end - start.offset
	return Statement{
		kind = .Drop_Index,
		span = stmt_span,
		data = Drop_Index_Stmt{name = name, if_exists = if_exists},
	}, ok_error()
}

// --- internal cleanup helpers (also used on error paths) ---

free_column_constraints :: proc(list: []Column_Constraint, allocator: mem.Allocator) {
	for c in list {
		#partial switch c.kind {
		case .Default:
			free_expr(c.default_expr, allocator)
		case .Check:
			free_expr(c.check_expr, allocator)
		case .References:
			free_foreign_key_ref(c.references, allocator)
		}
	}
}

free_foreign_key_ref :: proc(fk: Foreign_Key_Ref, allocator: mem.Allocator) {
	delete(fk.table, allocator)
	for c in fk.columns {
		delete(c, allocator)
	}
	delete(fk.columns, allocator)
}

free_column_def :: proc(col: Column_Def, allocator: mem.Allocator) {
	delete(col.name, allocator)
	delete(col.type_name, allocator)
	free_column_constraints(col.constraints, allocator)
	delete(col.constraints, allocator)
}

free_table_constraint :: proc(tc: Table_Constraint, allocator: mem.Allocator) {
	for n in tc.columns {
		delete(n, allocator)
	}
	delete(tc.columns, allocator)
	if tc.kind == .Check {
		free_expr(tc.check_expr, allocator)
	}
	if tc.kind == .Foreign_Key {
		free_foreign_key_ref(tc.references, allocator)
	}
}

free_table_elements :: proc(list: []Table_Element, allocator: mem.Allocator) {
	for elem in list {
		#partial switch elem.kind {
		case .Column:
			free_column_def(elem.column, allocator)
		case .Table_Constraint:
			free_table_constraint(elem.table_constraint, allocator)
		}
	}
}

free_index_columns :: proc(cols: []Index_Column, allocator: mem.Allocator) {
	for c in cols {
		delete(c.name, allocator)
	}
}

free_alter_table_stmt :: proc(stmt: Alter_Table_Stmt, allocator: mem.Allocator) {
	delete(stmt.table, allocator)
	delete(stmt.column.name, allocator)
	delete(stmt.column.type_name, allocator)
	free_column_constraints(stmt.column.constraints, allocator)
	delete(stmt.column.constraints, allocator)
}
