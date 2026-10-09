package sql_tests

import "core:strings"
import "core:testing"
import sql "../../sql"

literal_case :: struct {
	src:  string,
	kind: sql.Literal_Kind,
}

@(test)
test_expr_literals :: proc(t: ^testing.T) {
	cases := []literal_case{
		{"42", .Integer},
		{"3.14", .Float},
		{"'hi'", .String},
		{"X'AB01'", .Blob},
		{"NULL", .Null},
		{"null", .Null},
		{"TRUE", .Boolean},
		{"false", .Boolean},
	}
	for c in cases {
		expr, err := sql.parse_expr(c.src)
		if sql.has_error(err) {
			testing.expectf(t, false, "%q: %s", c.src, err.message)
			sql.free_error(err)
			continue
		}
		testing.expect_value(t, expr.kind, sql.Expr_Kind.Literal)
		testing.expect_value(t, expr.data.(sql.Literal_Data).lit_kind, c.kind)
		free_expr(expr)
	}
}

@(test)
test_expr_column_refs :: proc(t: ^testing.T) {
	expr, err := sql.parse_expr("t.col")
	defer free_expr(expr)
	defer sql.free_error(err)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, expr.kind, sql.Expr_Kind.Column_Ref)
	segs := expr.data.(sql.Column_Ref_Data).segments
	testing.expect_value(t, len(segs), 2)
	testing.expect_value(t, segs[0], "t")
	testing.expect_value(t, segs[1], "col")

	expr2, err2 := sql.parse_expr(`"SELECT"`)
	defer free_expr(expr2)
	defer sql.free_error(err2)
	testing.expect(t, !sql.has_error(err2))
	testing.expect_value(t, expr2.kind, sql.Expr_Kind.Column_Ref)
	testing.expect_value(t, expr2.data.(sql.Column_Ref_Data).segments[0], "SELECT")
	testing.expect_value(t, len(expr2.data.(sql.Column_Ref_Data).segments), 1)
}

@(test)
test_expr_placeholders :: proc(t: ^testing.T) {
	expr, err := sql.parse_expr("?")
	defer free_expr(expr)
	defer sql.free_error(err)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, expr.data.(sql.Placeholder_Data).index, 0)

	expr2, err2 := sql.parse_expr("?12")
	defer free_expr(expr2)
	defer sql.free_error(err2)
	testing.expect(t, !sql.has_error(err2))
	testing.expect_value(t, expr2.data.(sql.Placeholder_Data).index, 12)
}

@(test)
test_placeholder_print_reparse_preserves_indices :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("SELECT ?2, ?0 FROM t")
	defer sql.free_statement(stmt)
	defer sql.free_error(err)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)

	printed := sql.print_statement(stmt)
	defer delete(printed)
	testing.expect(t, strings.contains(printed, "?2"))
	testing.expect(t, strings.contains(printed, "?0"))

	stmt2, err2 := sql.parse_statement(printed)
	defer sql.free_statement(stmt2)
	defer sql.free_error(err2)
	testing.expectf(t, !sql.has_error(err2), "%s", err2.message)
	sel := stmt2.data.(sql.Select_Stmt)
	testing.expect_value(t, len(sel.projection), 2)
	testing.expect_value(t, sel.projection[0].expr.data.(sql.Placeholder_Data).index, 2)
	testing.expect_value(t, sel.projection[1].expr.data.(sql.Placeholder_Data).index, 0)
}

@(test)
test_placeholder_huge_index_rejected :: proc(t: ^testing.T) {
	// Overflow / past MAX_PLACEHOLDER_INDEX must not wrap.
	cases := []string{"?65536", "?99999999999999999999", "?18446744073709551615"}
	for src in cases {
		expr, err := sql.parse_expr(src)
		testing.expectf(t, sql.has_error(err), "expected reject for %s", src)
		testing.expect_value(t, err.code, sql.Parse_Error_Code.Invalid_Number)
		sql.free_error(err)
		if expr != nil {
			free_expr(expr)
		}
	}

	ok_expr, ok_err := sql.parse_expr("?65535")
	defer free_expr(ok_expr)
	defer sql.free_error(ok_err)
	testing.expect(t, !sql.has_error(ok_err))
	testing.expect_value(t, ok_expr.data.(sql.Placeholder_Data).index, 65535)
}

@(test)
test_expr_placeholder_auto_number :: proc(t: ^testing.T) {
	// Bare `?` auto-assigns 0, 1, … left-to-right; `?N` is explicit.
	stmt, err := sql.parse_statement("INSERT INTO t VALUES (?, ?, ?2, ?)")
	defer sql.free_statement(stmt)
	defer sql.free_error(err)
	testing.expect(t, !sql.has_error(err))
	ins := stmt.data.(sql.Insert_Stmt)
	testing.expect_value(t, len(ins.rows), 1)
	row := ins.rows[0]
	testing.expect_value(t, len(row), 4)
	testing.expect_value(t, row[0].data.(sql.Placeholder_Data).index, 0)
	testing.expect_value(t, row[1].data.(sql.Placeholder_Data).index, 1)
	testing.expect_value(t, row[2].data.(sql.Placeholder_Data).index, 2)
	testing.expect_value(t, row[3].data.(sql.Placeholder_Data).index, 3)
}

@(test)
test_expr_function_call :: proc(t: ^testing.T) {
	expr, err := sql.parse_expr("count(*)")
	defer free_expr(expr)
	defer sql.free_error(err)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, expr.kind, sql.Expr_Kind.Call)
	call := expr.data.(sql.Call_Data)
	testing.expect_value(t, call.name, "count")
	testing.expect_value(t, len(call.args), 1)
	testing.expect_value(t, call.args[0].kind, sql.Expr_Kind.Star)

	expr2, err2 := sql.parse_expr("abs(-1)")
	defer free_expr(expr2)
	defer sql.free_error(err2)
	testing.expect(t, !sql.has_error(err2))
	testing.expect_value(t, expr2.data.(sql.Call_Data).name, "abs")
}

@(test)
test_expr_precedence_mul_over_add :: proc(t: ^testing.T) {
	expr, err := sql.parse_expr("1 + 2 * 3")
	defer free_expr(expr)
	defer sql.free_error(err)
	testing.expect(t, !sql.has_error(err))
	// 1 + (2 * 3)
	testing.expect_value(t, expr.kind, sql.Expr_Kind.Binary)
	testing.expect_value(t, expr.data.(sql.Binary_Data).op, sql.Binary_Op.Add)
	right := expr.data.(sql.Binary_Data).right
	testing.expect_value(t, right.kind, sql.Expr_Kind.Binary)
	testing.expect_value(t, right.data.(sql.Binary_Data).op, sql.Binary_Op.Mul)
}

@(test)
test_expr_precedence_mul_left :: proc(t: ^testing.T) {
	expr, err := sql.parse_expr("2 * 3 + 4")
	defer free_expr(expr)
	defer sql.free_error(err)
	testing.expect(t, !sql.has_error(err))
	// (2 * 3) + 4
	testing.expect_value(t, expr.data.(sql.Binary_Data).op, sql.Binary_Op.Add)
	left := expr.data.(sql.Binary_Data).left
	testing.expect_value(t, left.data.(sql.Binary_Data).op, sql.Binary_Op.Mul)
}

@(test)
test_expr_precedence_and_over_or :: proc(t: ^testing.T) {
	expr, err := sql.parse_expr("a OR b AND c")
	defer free_expr(expr)
	defer sql.free_error(err)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, expr.data.(sql.Binary_Data).op, sql.Binary_Op.Or)
	right := expr.data.(sql.Binary_Data).right
	testing.expect_value(t, right.data.(sql.Binary_Data).op, sql.Binary_Op.And)
}

@(test)
test_expr_precedence_not_and :: proc(t: ^testing.T) {
	expr, err := sql.parse_expr("NOT a AND b")
	defer free_expr(expr)
	defer sql.free_error(err)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, expr.data.(sql.Binary_Data).op, sql.Binary_Op.And)
	left := expr.data.(sql.Binary_Data).left
	testing.expect_value(t, left.kind, sql.Expr_Kind.Unary)
	testing.expect_value(t, left.data.(sql.Unary_Data).op, sql.Unary_Op.Not)
}

@(test)
test_expr_concat_and_unary :: proc(t: ^testing.T) {
	expr, err := sql.parse_expr("'a' || 'b' || 'c'")
	defer free_expr(expr)
	defer sql.free_error(err)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, expr.data.(sql.Binary_Data).op, sql.Binary_Op.Concat)
	left := expr.data.(sql.Binary_Data).left
	right := expr.data.(sql.Binary_Data).right
	testing.expect_value(t, left.data.(sql.Binary_Data).op, sql.Binary_Op.Concat)
	testing.expect_value(t, right.kind, sql.Expr_Kind.Literal)

	neg, err2 := sql.parse_expr("-x")
	defer free_expr(neg)
	defer sql.free_error(err2)
	testing.expect(t, !sql.has_error(err2))
	testing.expect_value(t, neg.data.(sql.Unary_Data).op, sql.Unary_Op.Minus)
}

@(test)
test_expr_is_null :: proc(t: ^testing.T) {
	expr, err := sql.parse_expr("x IS NULL")
	defer free_expr(expr)
	defer sql.free_error(err)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, expr.kind, sql.Expr_Kind.Is_Null)
	testing.expect_value(t, expr.data.(sql.Is_Null_Data).negated, false)

	expr2, err2 := sql.parse_expr("x IS NOT NULL")
	defer free_expr(expr2)
	defer sql.free_error(err2)
	testing.expect(t, !sql.has_error(err2))
	testing.expect_value(t, expr2.data.(sql.Is_Null_Data).negated, true)
}

@(test)
test_expr_in_and_between :: proc(t: ^testing.T) {
	expr, err := sql.parse_expr("a IN (1, 2, 3)")
	defer free_expr(expr)
	defer sql.free_error(err)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, expr.kind, sql.Expr_Kind.In_List)
	testing.expect_value(t, len(expr.data.(sql.In_List_Data).values), 3)

	expr2, err2 := sql.parse_expr("a NOT IN (0)")
	defer free_expr(expr2)
	defer sql.free_error(err2)
	testing.expect(t, !sql.has_error(err2))
	testing.expect_value(t, expr2.data.(sql.In_List_Data).negated, true)

	expr3, err3 := sql.parse_expr("x BETWEEN 1 AND 10")
	defer free_expr(expr3)
	defer sql.free_error(err3)
	testing.expect(t, !sql.has_error(err3))
	testing.expect_value(t, expr3.kind, sql.Expr_Kind.Between)
	testing.expect_value(t, expr3.data.(sql.Between_Data).negated, false)

	expr4, err4 := sql.parse_expr("x NOT BETWEEN 0 AND 1")
	defer free_expr(expr4)
	defer sql.free_error(err4)
	testing.expect(t, !sql.has_error(err4))
	testing.expect_value(t, expr4.data.(sql.Between_Data).negated, true)
}

@(test)
test_expr_comparison_and_parens :: proc(t: ^testing.T) {
	expr, err := sql.parse_expr("(1 + 2) * 3")
	defer free_expr(expr)
	defer sql.free_error(err)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, expr.data.(sql.Binary_Data).op, sql.Binary_Op.Mul)
	left := expr.data.(sql.Binary_Data).left
	testing.expect_value(t, left.data.(sql.Binary_Data).op, sql.Binary_Op.Add)

	cmp, err2 := sql.parse_expr("a <> b")
	defer free_expr(cmp)
	defer sql.free_error(err2)
	testing.expect(t, !sql.has_error(err2))
	testing.expect_value(t, cmp.data.(sql.Binary_Data).op, sql.Binary_Op.NotEq)
}

@(test)
test_lexer_blob_and_placeholder :: proc(t: ^testing.T) {
	tokens, err := sql.tokenize("X'FF' ?3")
	defer delete(tokens)
	defer sql.free_error(err)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, tokens[0].kind, sql.Token_Kind.Blob)
	testing.expect_value(t, tokens[1].kind, sql.Token_Kind.Question)
	testing.expect_value(t, tokens[1].text, "?3")
}
