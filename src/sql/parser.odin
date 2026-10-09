package sql

import "core:mem"

/*
String ownership (hard contract):
  - Lexer Token.text aliases the `src` string passed to tokenize/parse_*.
  - AST strings (names, aliases, literal text, type names, call names, etc.) are
    cloned into the parse allocator. free_expr / free_statement / free_script
    free those clones. Callers may discard `src` after a successful parse.
  - Quoted identifiers are stored normalized (delimiters stripped, escapes undone).
  - Parse_Error.message is always allocator-owned; free with free_error.
*/

Parser :: struct {
	tokens:           []Token,
	pos:              int,
	allocator:        mem.Allocator,
	src:              string,
	next_placeholder: int, // next index for bare `?` (SQLite-style auto-number, 0-based)
}

make_parser :: proc(tokens: []Token, allocator := context.allocator, src := "") -> Parser {
	return Parser{
		tokens           = tokens,
		pos              = 0,
		allocator        = allocator,
		src              = src,
		next_placeholder = 0,
	}
}

peek :: proc(p: ^Parser, offset := 0) -> Token {
	i := p.pos + offset
	if i < 0 || i >= len(p.tokens) {
		if len(p.tokens) > 0 {
			return p.tokens[len(p.tokens) - 1]
		}
		return Token{kind = .EOF}
	}
	return p.tokens[i]
}

next :: proc(p: ^Parser) -> Token {
	tok := peek(p)
	if tok.kind != .EOF && p.pos < len(p.tokens) {
		p.pos += 1
	}
	return tok
}

expect :: proc(p: ^Parser, kind: Token_Kind) -> (Token, Parse_Error) {
	tok := peek(p)
	if tok.kind != kind {
		code := Parse_Error_Code.Unexpected_Token
		if tok.kind == .EOF {
			code = .Unexpected_EOF
		}
		return Token{}, make_error(
			tok.span,
			"expected %s, got %s",
			token_kind_string(kind),
			token_kind_string(tok.kind),
			code = code,
			allocator = p.allocator,
		)
	}
	return next(p), ok_error()
}

// synchronize advances to the next semicolon (consumed) or EOF.
// parse_script calls this after a statement error, then returns the prefix Script
// and that error — it does not continue parsing later statements.
synchronize :: proc(p: ^Parser) {
	for {
		tok := peek(p)
		if tok.kind == .EOF {
			return
		}
		if tok.kind == .Semicolon {
			next(p)
			return
		}
		next(p)
	}
}

at_end :: proc(p: ^Parser) -> bool {
	return peek(p).kind == .EOF
}

skip_semicolons :: proc(p: ^Parser) {
	for peek(p).kind == .Semicolon {
		next(p)
	}
}

parse_statement :: proc(src: string, allocator := context.allocator) -> (Statement, Parse_Error) {
	tokens, err := tokenize(src, allocator)
	if has_error(err) {
		return Statement{}, err
	}
	defer delete(tokens, allocator)

	p := make_parser(tokens, allocator, src)
	skip_semicolons(&p)
	if at_end(&p) {
		return Statement{}, error_at(
			peek(&p).span,
			"expected statement",
			code = .Expected_Statement,
			allocator = allocator,
		)
	}
	stmt, perr := parse_statement_node(&p)
	if has_error(perr) {
		return Statement{}, perr
	}
	skip_semicolons(&p)
	if !at_end(&p) {
		tok := peek(&p)
		free_statement(stmt, allocator)
		return Statement{}, make_error(
			tok.span,
			"unexpected token after statement",
			code = .Trailing_Token,
			allocator = allocator,
		)
	}
	return stmt, ok_error()
}

// parse_script parses semicolon-separated statements.
// On the first statement error: statements successfully parsed before the failure
// are returned in Script, tokens are synchronized to the next `;`, and the error
// is returned. Callers must free_script even when has_error is true.
// Statements after the first failure are not parsed further in this version.
parse_script :: proc(src: string, allocator := context.allocator) -> (Script, Parse_Error) {
	tokens, err := tokenize(src, allocator)
	if has_error(err) {
		return Script{}, err
	}
	defer delete(tokens, allocator)

	trimmed_empty := true
	for tok in tokens {
		if tok.kind != .EOF {
			trimmed_empty = false
			break
		}
	}
	if trimmed_empty {
		return Script{}, ok_error()
	}

	p := make_parser(tokens, allocator, src)
	stmts := make([dynamic]Statement, allocator)

	for {
		skip_semicolons(&p)
		if at_end(&p) {
			break
		}
		stmt, perr := parse_statement_node(&p)
		if has_error(perr) {
			synchronize(&p)
			return Script{statements = stmts[:]}, perr
		}
		append(&stmts, stmt)
		skip_semicolons(&p)
	}

	return Script{statements = stmts[:]}, ok_error()
}
