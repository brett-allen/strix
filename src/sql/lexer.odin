package sql

import "core:mem"

Lexer :: struct {
	src:       string,
	pos:       int,
	line:      int,
	column:    int,
	allocator: mem.Allocator,
}

tokenize :: proc(src: string, allocator := context.allocator) -> ([]Token, Parse_Error) {
	lex := Lexer{
		src       = src,
		pos       = 0,
		line      = 1,
		column    = 1,
		allocator = allocator,
	}

	tokens := make([dynamic]Token, allocator)
	for {
		tok, err := next_token(&lex)
		if has_error(err) {
			delete(tokens)
			return nil, err
		}
		append(&tokens, tok)
		if tok.kind == .EOF {
			break
		}
	}
	return tokens[:], ok_error()
}

next_token :: proc(lex: ^Lexer) -> (Token, Parse_Error) {
	if err := skip_trivia(lex); has_error(err) {
		return Token{}, err
	}

	start_pos := lex.pos
	start_line := lex.line
	start_col := lex.column

	if lex.pos >= len(lex.src) {
		return make_token(.EOF, "", start_pos, start_line, start_col), ok_error()
	}

	ch := lex.src[lex.pos]

	// Blob literal X'...' / x'...'
	if (ch == 'x' || ch == 'X') && lex.pos + 1 < len(lex.src) && lex.src[lex.pos + 1] == '\'' {
		return scan_blob(lex, start_pos, start_line, start_col)
	}

	// Identifiers and keywords
	if is_ident_start(ch) {
		return scan_ident(lex, start_pos, start_line, start_col)
	}

	// Quoted identifiers
	if ch == '"' || ch == '`' || ch == '[' {
		return scan_quoted_ident(lex, start_pos, start_line, start_col)
	}

	// String literal
	if ch == '\'' {
		return scan_string(lex, start_pos, start_line, start_col)
	}

	// Number: digit, or '.' followed by digit
	if is_digit(ch) || (ch == '.' && lex.pos + 1 < len(lex.src) && is_digit(lex.src[lex.pos + 1])) {
		return scan_number(lex, start_pos, start_line, start_col)
	}

	// Punctuators / operators (multi-char first)
	switch ch {
	case '(':
		advance(lex)
		return make_token(.LParen, "(", start_pos, start_line, start_col), ok_error()
	case ')':
		advance(lex)
		return make_token(.RParen, ")", start_pos, start_line, start_col), ok_error()
	case ',':
		advance(lex)
		return make_token(.Comma, ",", start_pos, start_line, start_col), ok_error()
	case ';':
		advance(lex)
		return make_token(.Semicolon, ";", start_pos, start_line, start_col), ok_error()
	case '*':
		advance(lex)
		return make_token(.Star, "*", start_pos, start_line, start_col), ok_error()
	case '/':
		advance(lex)
		return make_token(.Slash, "/", start_pos, start_line, start_col), ok_error()
	case '%':
		advance(lex)
		return make_token(.Percent, "%", start_pos, start_line, start_col), ok_error()
	case '+':
		advance(lex)
		return make_token(.Plus, "+", start_pos, start_line, start_col), ok_error()
	case '-':
		advance(lex)
		return make_token(.Minus, "-", start_pos, start_line, start_col), ok_error()
	case '?':
		advance(lex)
		for lex.pos < len(lex.src) && is_digit(lex.src[lex.pos]) {
			advance(lex)
		}
		text := lex.src[start_pos:lex.pos]
		return make_token(.Question, text, start_pos, start_line, start_col), ok_error()
	case '.':
		advance(lex)
		return make_token(.Dot, ".", start_pos, start_line, start_col), ok_error()
	case '=':
		advance(lex)
		if peek_byte(lex) == '=' {
			advance(lex)
			return make_token(.EqEq, "==", start_pos, start_line, start_col), ok_error()
		}
		return make_token(.Eq, "=", start_pos, start_line, start_col), ok_error()
	case '!':
		advance(lex)
		if peek_byte(lex) == '=' {
			advance(lex)
			return make_token(.NotEq, "!=", start_pos, start_line, start_col), ok_error()
		}
		span := span_from(start_pos, lex.pos - start_pos, start_line, start_col)
		return Token{}, make_error(span, "unexpected '!' (did you mean '!=')?", allocator = lex.allocator)
	case '<':
		advance(lex)
		next := peek_byte(lex)
		if next == '=' {
			advance(lex)
			return make_token(.LtEq, "<=", start_pos, start_line, start_col), ok_error()
		}
		if next == '>' {
			advance(lex)
			return make_token(.NotEq, "<>", start_pos, start_line, start_col), ok_error()
		}
		return make_token(.Lt, "<", start_pos, start_line, start_col), ok_error()
	case '>':
		advance(lex)
		if peek_byte(lex) == '=' {
			advance(lex)
			return make_token(.GtEq, ">=", start_pos, start_line, start_col), ok_error()
		}
		return make_token(.Gt, ">", start_pos, start_line, start_col), ok_error()
	case '|':
		advance(lex)
		if peek_byte(lex) == '|' {
			advance(lex)
			return make_token(.Concat, "||", start_pos, start_line, start_col), ok_error()
		}
		span := span_from(start_pos, lex.pos - start_pos, start_line, start_col)
		return Token{}, make_error(span, "unexpected '|' (did you mean '||')?", allocator = lex.allocator)
	}

	span := span_from(start_pos, 1, start_line, start_col)
	advance(lex)
	return Token{}, make_error(span, "unexpected character %q", rune(ch), allocator = lex.allocator)
}

skip_trivia :: proc(lex: ^Lexer) -> Parse_Error {
	for lex.pos < len(lex.src) {
		ch := lex.src[lex.pos]
		if ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' {
			advance(lex)
			continue
		}
		// Line comment --
		if ch == '-' && lex.pos + 1 < len(lex.src) && lex.src[lex.pos + 1] == '-' {
			advance(lex)
			advance(lex)
			for lex.pos < len(lex.src) && lex.src[lex.pos] != '\n' {
				advance(lex)
			}
			continue
		}
		// Block comment /* */
		if ch == '/' && lex.pos + 1 < len(lex.src) && lex.src[lex.pos + 1] == '*' {
			c_start := lex.pos
			c_line := lex.line
			c_col := lex.column
			advance(lex)
			advance(lex)
			closed := false
			for lex.pos < len(lex.src) {
				if lex.src[lex.pos] == '*' &&
				   lex.pos + 1 < len(lex.src) &&
				   lex.src[lex.pos + 1] == '/' {
					advance(lex)
					advance(lex)
					closed = true
					break
				}
				advance(lex)
			}
			if !closed {
				span := span_from(c_start, lex.pos - c_start, c_line, c_col)
				return error_at(span, "unterminated block comment", code = .Unterminated_Comment, allocator = lex.allocator)
			}
			continue
		}
		break
	}
	return ok_error()
}

scan_ident :: proc(lex: ^Lexer, start_pos, start_line, start_col: int) -> (Token, Parse_Error) {
	for lex.pos < len(lex.src) && is_ident_continue(lex.src[lex.pos]) {
		advance(lex)
	}
	text := lex.src[start_pos:lex.pos]
	kind := Token_Kind.Ident
	if kw, ok := lookup_keyword(text); ok {
		kind = kw
	}
	return make_token(kind, text, start_pos, start_line, start_col), ok_error()
}

scan_quoted_ident :: proc(lex: ^Lexer, start_pos, start_line, start_col: int) -> (Token, Parse_Error) {
	open := lex.src[lex.pos]
	advance(lex) // consume opener

	close: u8
	switch open {
	case '"':
		close = '"'
	case '`':
		close = '`'
	case '[':
		close = ']'
	}

	for lex.pos < len(lex.src) {
		ch := lex.src[lex.pos]
		if ch == close {
			// SQLite doubles the quote to escape inside "..." and `...`
			if close != ']' && lex.pos + 1 < len(lex.src) && lex.src[lex.pos + 1] == close {
				advance(lex)
				advance(lex)
				continue
			}
			advance(lex) // consume closer
			text := lex.src[start_pos:lex.pos]
			return make_token(.Ident, text, start_pos, start_line, start_col), ok_error()
		}
		if ch == '\n' && close != ']' {
			// Unterminated; still allow newline inside brackets like SQLite-ish
		}
		advance(lex)
	}

	span := span_from(start_pos, lex.pos - start_pos, start_line, start_col)
	msg: string
	switch open {
	case '"':
		msg = "unterminated double-quoted identifier"
	case '`':
		msg = "unterminated backtick-quoted identifier"
	case '[':
		msg = "unterminated bracket-quoted identifier"
	}
	return Token{}, error_at(span, msg, code = .Unterminated_Ident, allocator = lex.allocator)
}

scan_blob :: proc(lex: ^Lexer, start_pos, start_line, start_col: int) -> (Token, Parse_Error) {
	advance(lex) // X
	advance(lex) // '
	hex_count := 0
	for lex.pos < len(lex.src) {
		ch := lex.src[lex.pos]
		if ch == '\'' {
			advance(lex)
			if hex_count % 2 != 0 {
				span := span_from(start_pos, lex.pos - start_pos, start_line, start_col)
				return Token{}, error_at(
					span,
					"blob literal must contain an even number of hex digits",
					code = .Invalid_Blob,
					allocator = lex.allocator,
				)
			}
			text := lex.src[start_pos:lex.pos]
			return make_token(.Blob, text, start_pos, start_line, start_col), ok_error()
		}
		if !is_hex_digit(ch) {
			span := span_from(start_pos, lex.pos - start_pos, start_line, start_col)
			return Token{}, error_at(span, "invalid character in blob literal", code = .Invalid_Blob, allocator = lex.allocator)
		}
		advance(lex)
		hex_count += 1
	}
	span := span_from(start_pos, lex.pos - start_pos, start_line, start_col)
	return Token{}, error_at(span, "unterminated blob literal", code = .Unterminated_String, allocator = lex.allocator)
}

scan_string :: proc(lex: ^Lexer, start_pos, start_line, start_col: int) -> (Token, Parse_Error) {
	advance(lex) // consume opening '
	for lex.pos < len(lex.src) {
		ch := lex.src[lex.pos]
		if ch == '\'' {
			// '' escape
			if lex.pos + 1 < len(lex.src) && lex.src[lex.pos + 1] == '\'' {
				advance(lex)
				advance(lex)
				continue
			}
			advance(lex) // closing '
			text := lex.src[start_pos:lex.pos]
			return make_token(.String, text, start_pos, start_line, start_col), ok_error()
		}
		advance(lex)
	}
	span := span_from(start_pos, lex.pos - start_pos, start_line, start_col)
	return Token{}, error_at(span, "unterminated string literal", code = .Unterminated_String, allocator = lex.allocator)
}

scan_number :: proc(lex: ^Lexer, start_pos, start_line, start_col: int) -> (Token, Parse_Error) {
	is_float := false

	// Hex integer 0x...
	if lex.src[lex.pos] == '0' &&
	   lex.pos + 1 < len(lex.src) &&
	   (lex.src[lex.pos + 1] == 'x' || lex.src[lex.pos + 1] == 'X') {
		advance(lex)
		advance(lex)
		if lex.pos >= len(lex.src) || !is_hex_digit(lex.src[lex.pos]) {
			span := span_from(start_pos, lex.pos - start_pos, start_line, start_col)
			return Token{}, error_at(span, "invalid hexadecimal literal", code = .Invalid_Number, allocator = lex.allocator)
		}
		for lex.pos < len(lex.src) && is_hex_digit(lex.src[lex.pos]) {
			advance(lex)
		}
		text := lex.src[start_pos:lex.pos]
		return make_token(.Integer, text, start_pos, start_line, start_col), ok_error()
	}

	for lex.pos < len(lex.src) && is_digit(lex.src[lex.pos]) {
		advance(lex)
	}

	if lex.pos < len(lex.src) && lex.src[lex.pos] == '.' {
		// Only treat as float if digit follows, or we already had digits (e.g. 1.)
		if start_pos < lex.pos || (lex.pos + 1 < len(lex.src) && is_digit(lex.src[lex.pos + 1])) {
			is_float = true
			advance(lex)
			for lex.pos < len(lex.src) && is_digit(lex.src[lex.pos]) {
				advance(lex)
			}
		}
	}

	if lex.pos < len(lex.src) && (lex.src[lex.pos] == 'e' || lex.src[lex.pos] == 'E') {
		is_float = true
		advance(lex)
		if lex.pos < len(lex.src) && (lex.src[lex.pos] == '+' || lex.src[lex.pos] == '-') {
			advance(lex)
		}
		if lex.pos >= len(lex.src) || !is_digit(lex.src[lex.pos]) {
			span := span_from(start_pos, lex.pos - start_pos, start_line, start_col)
			return Token{}, error_at(span, "invalid floating-point exponent", code = .Invalid_Number, allocator = lex.allocator)
		}
		for lex.pos < len(lex.src) && is_digit(lex.src[lex.pos]) {
			advance(lex)
		}
	}

	text := lex.src[start_pos:lex.pos]
	kind: Token_Kind = .Integer if !is_float else .Float
	return make_token(kind, text, start_pos, start_line, start_col), ok_error()
}

make_token :: proc(kind: Token_Kind, text: string, start_pos, start_line, start_col: int) -> Token {
	return Token{
		kind = kind,
		text = text,
		span = span_from(start_pos, len(text), start_line, start_col),
	}
}

span_from :: proc(offset, length, line, column: int) -> Span {
	return Span{
		offset = offset,
		length = length,
		line   = line,
		column = column,
	}
}

advance :: proc(lex: ^Lexer) {
	if lex.pos >= len(lex.src) {
		return
	}
	if lex.src[lex.pos] == '\n' {
		lex.line += 1
		lex.column = 1
	} else {
		lex.column += 1
	}
	lex.pos += 1
}

peek_byte :: proc(lex: ^Lexer) -> u8 {
	if lex.pos >= len(lex.src) {
		return 0
	}
	return lex.src[lex.pos]
}

is_digit :: proc(ch: u8) -> bool {
	return ch >= '0' && ch <= '9'
}

is_hex_digit :: proc(ch: u8) -> bool {
	return is_digit(ch) ||
		(ch >= 'a' && ch <= 'f') ||
		(ch >= 'A' && ch <= 'F')
}

is_ident_start :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') ||
		(ch >= 'A' && ch <= 'Z') ||
		ch == '_'
}

is_ident_continue :: proc(ch: u8) -> bool {
	return is_ident_start(ch) || is_digit(ch)
}
