package sql

import "core:mem"
import "core:strings"

parse_expr :: proc(src: string, allocator := context.allocator) -> (^Expr, Parse_Error) {
	tokens, err := tokenize(src, allocator)
	if has_error(err) {
		return nil, err
	}
	defer delete(tokens, allocator)

	p := make_parser(tokens, allocator, src)
	expr, perr := parse_or_expr(&p)
	if has_error(perr) {
		return nil, perr
	}
	if !at_end(&p) {
		tok := peek(&p)
		free_expr(expr, allocator)
		return nil, make_error(
			tok.span,
			"unexpected token %s after expression",
			token_kind_string(tok.kind),
			code = .Trailing_Token,
			allocator = allocator,
		)
	}
	return expr, ok_error()
}

parse_or_expr :: proc(p: ^Parser) -> (^Expr, Parse_Error) {
	left, err := parse_and_expr(p)
	if has_error(err) {
		return nil, err
	}
	for peek(p).kind == .Kw_Or {
		op_tok := next(p)
		right, rerr := parse_and_expr(p)
		if has_error(rerr) {
			free_expr(left, p.allocator)
			return nil, rerr
		}
		left = make_binary(p, .Or, left, right, op_tok.span)
	}
	return left, ok_error()
}

parse_and_expr :: proc(p: ^Parser) -> (^Expr, Parse_Error) {
	left, err := parse_not_expr(p)
	if has_error(err) {
		return nil, err
	}
	for peek(p).kind == .Kw_And {
		op_tok := next(p)
		right, rerr := parse_not_expr(p)
		if has_error(rerr) {
			free_expr(left, p.allocator)
			return nil, rerr
		}
		left = make_binary(p, .And, left, right, op_tok.span)
	}
	return left, ok_error()
}

parse_not_expr :: proc(p: ^Parser) -> (^Expr, Parse_Error) {
	if peek(p).kind == .Kw_Not {
		op_tok := next(p)
		inner, err := parse_not_expr(p)
		if has_error(err) {
			return nil, err
		}
		node := new(Expr, p.allocator)
		node.kind = .Unary
		node.span = op_tok.span
		node.data = Unary_Data{op = .Not, expr = inner}
		return node, ok_error()
	}
	return parse_postfix_expr(p)
}

parse_postfix_expr :: proc(p: ^Parser) -> (^Expr, Parse_Error) {
	left, err := parse_concat_expr(p)
	if has_error(err) {
		return nil, err
	}

	for {
		#partial switch peek(p).kind {
		case .Kw_Is:
			is_tok := next(p)
			negated := false
			if peek(p).kind == .Kw_Not {
				next(p)
				negated = true
			}
			if peek(p).kind != .Kw_Null {
				free_expr(left, p.allocator)
				return nil, make_error(
					peek(p).span,
					"expected NULL after IS",
					allocator = p.allocator,
				)
			}
			null_tok := next(p)
			span := is_tok.span
			span.length = (null_tok.span.offset + null_tok.span.length) - span.offset
			node := new(Expr, p.allocator)
			node.kind = .Is_Null
			node.span = span
			node.data = Is_Null_Data{expr = left, negated = negated}
			left = node
			continue
		case .Kw_Not:
			// NOT IN / NOT BETWEEN — only when followed by IN or BETWEEN
			if p.pos + 1 < len(p.tokens) &&
			   (p.tokens[p.pos + 1].kind == .Kw_In || p.tokens[p.pos + 1].kind == .Kw_Between) {
				next(p)
				negated := true
				kw := next(p)
				left, err = parse_in_or_between_suffix(p, left, kw, negated)
				if has_error(err) {
					return nil, err
				}
				continue
			}
			if p.pos + 1 < len(p.tokens) {
				#partial switch p.tokens[p.pos + 1].kind {
				case .Kw_Like, .Kw_Glob, .Kw_Match, .Kw_Regexp:
					free_expr(left, p.allocator)
					return nil, make_error(
						p.tokens[p.pos + 1].span,
						"NOT %s expressions are not supported yet",
						token_kind_string(p.tokens[p.pos + 1].kind),
						code = .Unsupported_Syntax,
						allocator = p.allocator,
					)
				}
			}
			return left, ok_error()
		case .Kw_In:
			in_tok := next(p)
			left, err = parse_in_or_between_suffix(p, left, in_tok, false)
			if has_error(err) {
				return nil, err
			}
			continue
		case .Kw_Between:
			bet_tok := next(p)
			left, err = parse_in_or_between_suffix(p, left, bet_tok, false)
			if has_error(err) {
				return nil, err
			}
			continue
		case .Kw_Like, .Kw_Glob, .Kw_Match, .Kw_Regexp, .Kw_Isnull, .Kw_Notnull:
			free_expr(left, p.allocator)
			return nil, make_error(
				peek(p).span,
				"%s expressions are not supported yet",
				token_kind_string(peek(p).kind),
				code = .Unsupported_Syntax,
				allocator = p.allocator,
			)
		case:
			if is_comparison_op(peek(p).kind) {
				op_tok := next(p)
				op := token_to_binary_op(op_tok.kind)
				right, rerr := parse_concat_expr(p)
				if has_error(rerr) {
					free_expr(left, p.allocator)
					return nil, rerr
				}
				left = make_binary(p, op, left, right, op_tok.span)
				continue
			}
			return left, ok_error()
		}
	}
}

parse_in_or_between_suffix :: proc(
	p: ^Parser,
	left: ^Expr,
	kw: Token,
	negated: bool,
) -> (^Expr, Parse_Error) {
	if kw.kind == .Kw_In {
		_, err := expect(p, .LParen)
		if has_error(err) {
			free_expr(left, p.allocator)
			return nil, err
		}
		if peek(p).kind == .RParen {
			free_expr(left, p.allocator)
			return nil, make_error(
				peek(p).span,
				"IN list must contain at least one expression",
				code = .Empty_List,
				allocator = p.allocator,
			)
		}
		values := make([dynamic]^Expr, p.allocator)
		for {
			val, verr := parse_or_expr(p)
			if has_error(verr) {
				free_expr(left, p.allocator)
				for v in values {
					free_expr(v, p.allocator)
				}
				delete(values)
				return nil, verr
			}
			append(&values, val)
			if peek(p).kind == .Comma {
				next(p)
				continue
			}
			break
		}
		_, err2 := expect(p, .RParen)
		if has_error(err2) {
			free_expr(left, p.allocator)
			for v in values {
				free_expr(v, p.allocator)
			}
			delete(values)
			return nil, err2
		}
		span := kw.span
		if len(values) > 0 {
			last := values[len(values) - 1]
			span.length = (last.span.offset + last.span.length) - span.offset
		}
		node := new(Expr, p.allocator)
		node.kind = .In_List
		node.span = span
		node.data = In_List_Data{
			expr    = left,
			values  = values[:],
			negated = negated,
		}
		return node, ok_error()
	}

	// BETWEEN low AND high
	low, lerr := parse_concat_expr(p)
	if has_error(lerr) {
		free_expr(left, p.allocator)
		return nil, lerr
	}
	if peek(p).kind != .Kw_And {
		free_expr(left, p.allocator)
		free_expr(low, p.allocator)
		return nil, make_error(
			peek(p).span,
			"expected AND in BETWEEN expression",
			allocator = p.allocator,
		)
	}
	and_tok := next(p)
	high, herr := parse_concat_expr(p)
	if has_error(herr) {
		free_expr(left, p.allocator)
		free_expr(low, p.allocator)
		return nil, herr
	}
	span := kw.span
	span.length = (high.span.offset + high.span.length) - span.offset
	_ = and_tok
	node := new(Expr, p.allocator)
	node.kind = .Between
	node.span = span
	node.data = Between_Data{
		expr    = left,
		low     = low,
		high    = high,
		negated = negated,
	}
	return node, ok_error()
}

parse_concat_expr :: proc(p: ^Parser) -> (^Expr, Parse_Error) {
	left, err := parse_add_expr(p)
	if has_error(err) {
		return nil, err
	}
	for peek(p).kind == .Concat {
		op_tok := next(p)
		right, rerr := parse_add_expr(p)
		if has_error(rerr) {
			free_expr(left, p.allocator)
			return nil, rerr
		}
		left = make_binary(p, .Concat, left, right, op_tok.span)
	}
	return left, ok_error()
}

parse_add_expr :: proc(p: ^Parser) -> (^Expr, Parse_Error) {
	left, err := parse_mul_expr(p)
	if has_error(err) {
		return nil, err
	}
	for peek(p).kind == .Plus || peek(p).kind == .Minus {
		op_tok := next(p)
		op: Binary_Op = .Add if op_tok.kind == .Plus else .Sub
		right, rerr := parse_mul_expr(p)
		if has_error(rerr) {
			free_expr(left, p.allocator)
			return nil, rerr
		}
		left = make_binary(p, op, left, right, op_tok.span)
	}
	return left, ok_error()
}

parse_mul_expr :: proc(p: ^Parser) -> (^Expr, Parse_Error) {
	left, err := parse_unary_expr(p)
	if has_error(err) {
		return nil, err
	}
	for peek(p).kind == .Star || peek(p).kind == .Slash || peek(p).kind == .Percent {
		op_tok := next(p)
		op: Binary_Op
		#partial switch op_tok.kind {
		case .Star:
			op = .Mul
		case .Slash:
			op = .Div
		case .Percent:
			op = .Mod
		}
		right, rerr := parse_unary_expr(p)
		if has_error(rerr) {
			free_expr(left, p.allocator)
			return nil, rerr
		}
		left = make_binary(p, op, left, right, op_tok.span)
	}
	return left, ok_error()
}

parse_unary_expr :: proc(p: ^Parser) -> (^Expr, Parse_Error) {
	#partial switch peek(p).kind {
	case .Plus, .Minus:
		op_tok := next(p)
		op: Unary_Op = .Plus if op_tok.kind == .Plus else .Minus
		inner, err := parse_unary_expr(p)
		if has_error(err) {
			return nil, err
		}
		node := new(Expr, p.allocator)
		node.kind = .Unary
		node.span = op_tok.span
		node.data = Unary_Data{op = op, expr = inner}
		return node, ok_error()
	}
	return parse_primary_expr(p)
}

parse_primary_expr :: proc(p: ^Parser) -> (^Expr, Parse_Error) {
	tok := peek(p)

	#partial switch tok.kind {
	case .Integer:
		next(p)
		return make_literal(p, .Integer, tok.text, tok.span), ok_error()
	case .Float:
		next(p)
		return make_literal(p, .Float, tok.text, tok.span), ok_error()
	case .String:
		next(p)
		return make_literal(p, .String, tok.text, tok.span), ok_error()
	case .Blob:
		next(p)
		return make_literal(p, .Blob, tok.text, tok.span), ok_error()
	case .Kw_Null:
		next(p)
		return make_literal(p, .Null, tok.text, tok.span), ok_error()
	case .Kw_True, .Kw_False:
		next(p)
		return make_literal(p, .Boolean, tok.text, tok.span), ok_error()
	case .Question:
		next(p)
		idx, iok := assign_placeholder_index(p, tok.text)
		if !iok {
			return nil, make_error(
				tok.span,
				"placeholder index out of range (max %d): %s",
				MAX_PLACEHOLDER_INDEX,
				tok.text,
				code = .Invalid_Number,
			)
		}
		node := new(Expr, p.allocator)
		node.kind = .Placeholder
		node.span = tok.span
		node.data = Placeholder_Data{index = idx}
		return node, ok_error()
	case .Star:
		next(p)
		node := new(Expr, p.allocator)
		node.kind = .Star
		node.span = tok.span
		return node, ok_error()
	case .LParen:
		next(p)
		inner, err := parse_or_expr(p)
		if has_error(err) {
			return nil, err
		}
		_, err2 := expect(p, .RParen)
		if has_error(err2) {
			free_expr(inner, p.allocator)
			return nil, err2
		}
		return inner, ok_error()
	case .Ident:
		return parse_name_or_call(p)
	case .Kw_Cast:
		return parse_cast_expr(p)
	case .Kw_Current_Date, .Kw_Current_Time, .Kw_Current_Timestamp:
		return parse_keyword_primary(p)
	case .Kw_Replace:
		// SQLite REPLACE(...) function — allow as call when followed by '('
		if p.pos + 1 < len(p.tokens) && p.tokens[p.pos + 1].kind == .LParen {
			return parse_keyword_call(p)
		}
		return nil, make_error(
			tok.span,
			"expected expression, got REPLACE (use REPLACE(...) for the function)",
			allocator = p.allocator,
		)
	case .Kw_Like, .Kw_Glob, .Kw_Match, .Kw_Regexp, .Kw_Isnull, .Kw_Notnull:
		return nil, make_error(
			tok.span,
			"%s expressions are not supported yet",
			token_kind_string(tok.kind),
			code = .Unsupported_Syntax,
			allocator = p.allocator,
		)
	}

	return nil, make_error(
		tok.span,
		"expected expression, got %s",
		token_kind_string(tok.kind),
		allocator = p.allocator,
	)
}

parse_keyword_primary :: proc(p: ^Parser) -> (^Expr, Parse_Error) {
	tok := next(p)
	node := new(Expr, p.allocator)
	node.kind = .Call
	node.span = tok.span
	node.data = Call_Data{
		name = strings.clone(tok.text, p.allocator),
		args = nil,
	}
	return node, ok_error()
}

parse_keyword_call :: proc(p: ^Parser) -> (^Expr, Parse_Error) {
	tok := next(p)
	_, err := expect(p, .LParen)
	if has_error(err) {
		return nil, err
	}
	args := make([dynamic]^Expr, p.allocator)
	if peek(p).kind != .RParen {
		for {
			arg, aerr := parse_or_expr(p)
			if has_error(aerr) {
				for a in args {
					free_expr(a, p.allocator)
				}
				delete(args)
				return nil, aerr
			}
			append(&args, arg)
			if peek(p).kind == .Comma {
				next(p)
				continue
			}
			break
		}
	}
	rparen, rerr := expect(p, .RParen)
	if has_error(rerr) {
		for a in args {
			free_expr(a, p.allocator)
		}
		delete(args)
		return nil, rerr
	}
	span := tok.span
	span.length = (rparen.span.offset + rparen.span.length) - span.offset
	node := new(Expr, p.allocator)
	node.kind = .Call
	node.span = span
	node.data = Call_Data{
		name = strings.clone(tok.text, p.allocator),
		args = args[:],
	}
	return node, ok_error()
}

parse_cast_expr :: proc(p: ^Parser) -> (^Expr, Parse_Error) {
	start := peek(p).span
	next(p) // CAST
	_, err := expect(p, .LParen)
	if has_error(err) {
		return nil, err
	}
	inner, ierr := parse_or_expr(p)
	if has_error(ierr) {
		return nil, ierr
	}
	_, aerr := expect(p, .Kw_As)
	if has_error(aerr) {
		free_expr(inner, p.allocator)
		return nil, aerr
	}
	type_name, terr := parse_optional_type_name(p)
	if has_error(terr) {
		free_expr(inner, p.allocator)
		return nil, terr
	}
	if type_name == "" {
		free_expr(inner, p.allocator)
		return nil, make_error(
			peek(p).span,
			"expected type name after CAST AS",
			allocator = p.allocator,
		)
	}
	rparen, rerr := expect(p, .RParen)
	if has_error(rerr) {
		free_expr(inner, p.allocator)
		delete(type_name, p.allocator)
		return nil, rerr
	}
	span := start
	span.length = (rparen.span.offset + rparen.span.length) - start.offset
	node := new(Expr, p.allocator)
	node.kind = .Cast
	node.span = span
	node.data = Cast_Data{expr = inner, type_name = type_name}
	return node, ok_error()
}

parse_name_or_call :: proc(p: ^Parser) -> (^Expr, Parse_Error) {
	tok := next(p)
	segments := make([dynamic]string, p.allocator)
	append(&segments, clone_ident_name(tok.text, p.allocator))
	span := tok.span

	for peek(p).kind == .Dot {
		next(p)
		if peek(p).kind != .Ident {
			for seg in segments {
				delete(seg, p.allocator)
			}
			delete(segments)
			return nil, make_error(
				peek(p).span,
				"expected identifier after '.'",
				allocator = p.allocator,
			)
		}
		part := next(p)
		append(&segments, clone_ident_name(part.text, p.allocator))
		span.length = (part.span.offset + part.span.length) - span.offset
	}

	if peek(p).kind == .LParen {
		next(p)
		args := make([dynamic]^Expr, p.allocator)
		if peek(p).kind != .RParen {
			for {
				arg, aerr := parse_or_expr(p)
				if has_error(aerr) {
					for seg in segments {
						delete(seg, p.allocator)
					}
					delete(segments)
					for a in args {
						free_expr(a, p.allocator)
					}
					delete(args)
					return nil, aerr
				}
				append(&args, arg)
				if peek(p).kind == .Comma {
					next(p)
					continue
				}
				break
			}
		}
		rparen, err := expect(p, .RParen)
		if has_error(err) {
			for seg in segments {
				delete(seg, p.allocator)
			}
			delete(segments)
			for a in args {
				free_expr(a, p.allocator)
			}
			delete(args)
			return nil, err
		}
		span.length = (rparen.span.offset + rparen.span.length) - span.offset
		name := join_segments(segments[:], p.allocator)
		for seg in segments {
			delete(seg, p.allocator)
		}
		delete(segments)
		node := new(Expr, p.allocator)
		node.kind = .Call
		node.span = span
		node.data = Call_Data{name = name, args = args[:]}
		return node, ok_error()
	}

	node := new(Expr, p.allocator)
	node.kind = .Column_Ref
	node.span = span
	node.data = Column_Ref_Data{segments = segments[:]}
	return node, ok_error()
}

make_literal :: proc(p: ^Parser, kind: Literal_Kind, text: string, span: Span) -> ^Expr {
	node := new(Expr, p.allocator)
	node.kind = .Literal
	node.span = span
	node.data = Literal_Data{lit_kind = kind, text = strings.clone(text, p.allocator)}
	return node
}

make_binary :: proc(p: ^Parser, op: Binary_Op, left, right: ^Expr, op_span: Span) -> ^Expr {
	node := new(Expr, p.allocator)
	node.kind = .Binary
	node.span = left.span
	end := right.span.offset + right.span.length
	node.span.length = end - node.span.offset
	node.data = Binary_Data{op = op, left = left, right = right}
	_ = op_span
	return node
}

is_comparison_op :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Eq, .EqEq, .NotEq, .Lt, .LtEq, .Gt, .GtEq:
		return true
	}
	return false
}

token_to_binary_op :: proc(kind: Token_Kind) -> Binary_Op {
	#partial switch kind {
	case .Eq:
		return .Eq
	case .EqEq:
		return .EqEq
	case .NotEq:
		return .NotEq
	case .Lt:
		return .Lt
	case .LtEq:
		return .LtEq
	case .Gt:
		return .Gt
	case .GtEq:
		return .GtEq
	}
	return .Eq
}

join_segments :: proc(segments: []string, allocator: mem.Allocator) -> string {
	if len(segments) == 0 {
		return ""
	}
	if len(segments) == 1 {
		return strings.clone(segments[0], allocator)
	}
	b := strings.builder_make(allocator)
	for seg, i in segments {
		if i > 0 {
			strings.write_byte(&b, '.')
		}
		strings.write_string(&b, seg)
	}
	out := strings.clone(strings.to_string(b), allocator)
	strings.builder_destroy(&b)
	return out
}
