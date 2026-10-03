package sql_tests

import "core:testing"
import sql "../../sql"

@(test)
test_tokenize_keywords_and_idents :: proc(t: ^testing.T) {
	src := "SELECT name FROM users WHERE id = 1"
	tokens, err := sql.tokenize(src)
	testing.expectf(t, !sql.has_error(err), "unexpected error: %s", err.message)
	defer delete(tokens)

	expect_kinds(t, tokens, {
		.Kw_Select,
		.Ident,
		.Kw_From,
		.Ident,
		.Kw_Where,
		.Ident,
		.Eq,
		.Integer,
		.EOF,
	})

	testing.expect_value(t, tokens[0].text, "SELECT")
	testing.expect_value(t, tokens[1].text, "name")
	testing.expect_value(t, tokens[3].text, "users")
}

@(test)
test_keyword_case_insensitive :: proc(t: ^testing.T) {
	tokens, err := sql.tokenize("select From WHERE")
	testing.expect(t, !sql.has_error(err))
	defer delete(tokens)

	expect_kinds(t, tokens, {.Kw_Select, .Kw_From, .Kw_Where, .EOF})
}

@(test)
test_quoted_identifiers :: proc(t: ^testing.T) {
	src := `SELECT "Weird Name", ` + "`tbl`" + `, [col] FROM t`
	tokens, err := sql.tokenize(src)
	testing.expectf(t, !sql.has_error(err), "unexpected error: %s", err.message)
	defer delete(tokens)

	testing.expect_value(t, tokens[0].kind, sql.Token_Kind.Kw_Select)
	testing.expect_value(t, tokens[1].kind, sql.Token_Kind.Ident)
	testing.expect_value(t, tokens[1].text, `"Weird Name"`)
	testing.expect_value(t, tokens[3].kind, sql.Token_Kind.Ident)
	testing.expect_value(t, tokens[3].text, "`tbl`")
	testing.expect_value(t, tokens[5].kind, sql.Token_Kind.Ident)
	testing.expect_value(t, tokens[5].text, "[col]")
}

@(test)
test_strings_and_escapes :: proc(t: ^testing.T) {
	tokens, err := sql.tokenize("'hello''world'")
	testing.expect(t, !sql.has_error(err))
	defer delete(tokens)

	expect_kinds(t, tokens, {.String, .EOF})
	testing.expect_value(t, tokens[0].text, "'hello''world'")
}

@(test)
test_numbers :: proc(t: ^testing.T) {
	tokens, err := sql.tokenize("42 3.14 .5 1. 1e10 2.5E-3 0xFF")
	testing.expectf(t, !sql.has_error(err), "unexpected error: %s", err.message)
	defer delete(tokens)

	expect_kinds(t, tokens, {
		.Integer,
		.Float,
		.Float,
		.Float,
		.Float,
		.Float,
		.Integer,
		.EOF,
	})
	testing.expect_value(t, tokens[0].text, "42")
	testing.expect_value(t, tokens[6].text, "0xFF")
}

@(test)
test_comments_skipped :: proc(t: ^testing.T) {
	src := "SELECT -- line comment\n1 /* block\ncomment */ + 2"
	tokens, err := sql.tokenize(src)
	testing.expectf(t, !sql.has_error(err), "unexpected error: %s", err.message)
	defer delete(tokens)

	expect_kinds(t, tokens, {.Kw_Select, .Integer, .Plus, .Integer, .EOF})
}

@(test)
test_operators :: proc(t: ^testing.T) {
	tokens, err := sql.tokenize("a <> b != c <= d >= e == f || g")
	testing.expect(t, !sql.has_error(err))
	defer delete(tokens)

	expect_kinds(t, tokens, {
		.Ident, .NotEq, .Ident,
		.NotEq, .Ident,
		.LtEq, .Ident,
		.GtEq, .Ident,
		.EqEq, .Ident,
		.Concat, .Ident,
		.EOF,
	})
}

@(test)
test_spans_line_column :: proc(t: ^testing.T) {
	tokens, err := sql.tokenize("SELECT\nid")
	testing.expect(t, !sql.has_error(err))
	defer delete(tokens)

	testing.expect_value(t, tokens[0].span.line, 1)
	testing.expect_value(t, tokens[0].span.column, 1)
	testing.expect_value(t, tokens[1].span.line, 2)
	testing.expect_value(t, tokens[1].span.column, 1)
	testing.expect_value(t, tokens[1].text, "id")
}

@(test)
test_reject_unterminated_string :: proc(t: ^testing.T) {
	tokens, err := sql.tokenize("'oops")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect(t, tokens == nil)
	testing.expect(t, err.span.line == 1)
}

@(test)
test_reject_bad_character :: proc(t: ^testing.T) {
	tokens, err := sql.tokenize("SELECT @")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect(t, tokens == nil)
}

@(test)
test_reject_lone_bang :: proc(t: ^testing.T) {
	_, err := sql.tokenize("a ! b")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
}

@(test)
test_create_table_snippet :: proc(t: ^testing.T) {
	src := "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, name TEXT);"
	tokens, err := sql.tokenize(src)
	testing.expectf(t, !sql.has_error(err), "unexpected error: %s", err.message)
	defer delete(tokens)

	expect_kinds(t, tokens, {
		.Kw_Create, .Kw_Table, .Kw_If, .Kw_Not, .Kw_Exists, .Ident,
		.LParen, .Ident, .Ident, .Kw_Primary, .Kw_Key,
		.Comma, .Ident, .Ident, .RParen, .Semicolon, .EOF,
	})
}

@(test)
test_parser_scaffolding_peek_expect :: proc(t: ^testing.T) {
	tokens, err := sql.tokenize("SELECT 1;")
	testing.expect(t, !sql.has_error(err))
	defer delete(tokens)

	p := sql.make_parser(tokens)
	testing.expect_value(t, sql.peek(&p).kind, sql.Token_Kind.Kw_Select)
	tok := sql.next(&p)
	testing.expect_value(t, tok.kind, sql.Token_Kind.Kw_Select)

	got, e := sql.expect(&p, .Integer)
	testing.expect(t, !sql.has_error(e))
	testing.expect_value(t, got.kind, sql.Token_Kind.Integer)

	_, e2 := sql.expect(&p, .Kw_From)
	defer sql.free_error(e2)
	testing.expect(t, sql.has_error(e2))

	sql.synchronize(&p)
	testing.expect(t, sql.at_end(&p))
}

@(test)
test_parse_script_empty_ok :: proc(t: ^testing.T) {
	script, err := sql.parse_script("   -- just a comment\n")
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, len(script.statements), 0)
}

@(test)
test_parse_statement_ddl_ok :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("CREATE TABLE t (id INT)")
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, stmt.kind, sql.Statement_Kind.Create_Table)
}

@(test)
test_parse_statement_accepts_select :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("SELECT * FROM t")
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, stmt.kind, sql.Statement_Kind.Select)
}

@(test)
test_parse_statement_accepts_insert :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("INSERT INTO t VALUES (1)")
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, stmt.kind, sql.Statement_Kind.Insert)
}

@(test)
test_parse_statement_accepts_alter :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("ALTER TABLE t ADD COLUMN x INT")
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, stmt.kind, sql.Statement_Kind.Alter_Table)
}

@(test)
test_parse_statement_rejects_with :: proc(t: ^testing.T) {
	_, err := sql.parse_statement("WITH cte AS (SELECT 1) SELECT * FROM cte")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
}


free_expr :: proc(expr: ^sql.Expr) {
	sql.free_expr(expr)
}

expect_kinds :: proc(t: ^testing.T, tokens: []sql.Token, kinds: []sql.Token_Kind) {
	testing.expectf(t, len(tokens) == len(kinds), "token count %d != %d", len(tokens), len(kinds))
	n := min(len(tokens), len(kinds))
	for i in 0 ..< n {
		testing.expectf(
			t,
			tokens[i].kind == kinds[i],
			"token[%d]: got %v want %v (text=%q)",
			i,
			tokens[i].kind,
			kinds[i],
			tokens[i].text,
		)
	}
}
