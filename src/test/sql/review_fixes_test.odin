package sql_tests

import "core:mem"
import "core:testing"
import sql "../../sql"

@(test)
test_reject_type_name_paren_swallows_default :: proc(t: ^testing.T) {
	_, err := sql.parse_statement("CREATE TABLE t (id VARCHAR(10 DEFAULT 1))")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect(t, err.message != "")
}

@(test)
test_reject_unclosed_type_name_paren :: proc(t: ^testing.T) {
	// Type paren left open (no ')' after VARCHAR(10); not merely a missing table ')'.
	_, err := sql.parse_statement("CREATE TABLE t (id VARCHAR(10")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect(t, contains_ci(err.message, "unclosed"))
	testing.expect_value(t, err.code, sql.Parse_Error_Code.Invalid_Type_Name)
}

@(test)
test_reject_table_constraint_name_fallthrough :: proc(t: ^testing.T) {
	// Must not accept and drop CONSTRAINT foo into a following column def.
	_, err := sql.parse_statement("CREATE TABLE t (a INT, CONSTRAINT foo bar INT)")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect(t, contains_ci(err.message, "CONSTRAINT") || contains_ci(err.message, "constraint"))
}

@(test)
test_reject_empty_in_list :: proc(t: ^testing.T) {
	_, err := sql.parse_expr("a IN ()")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect_value(t, err.code, sql.Parse_Error_Code.Empty_List)
}

@(test)
test_reject_not_like_clearly :: proc(t: ^testing.T) {
	_, err := sql.parse_expr("a NOT LIKE b")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect(t, contains_ci(err.message, "LIKE"))
	testing.expect_value(t, err.code, sql.Parse_Error_Code.Unsupported_Syntax)
}

@(test)
test_reject_bare_constraint_name :: proc(t: ^testing.T) {
	_, err := sql.parse_statement("CREATE TABLE t (id INT CONSTRAINT foo)")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect(t, contains_ci(err.message, "CONSTRAINT") || contains_ci(err.message, "constraint"))
}

@(test)
test_reject_unterminated_block_comment :: proc(t: ^testing.T) {
	tokens, err := sql.tokenize("SELECT 1 /* never closed")
	defer delete(tokens)
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect(t, tokens == nil)
	testing.expect(t, contains_ci(err.message, "unterminated"))
	testing.expect_value(t, err.code, sql.Parse_Error_Code.Unterminated_Comment)
}

@(test)
test_parse_expr_trailing_token_no_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	expr, err := sql.parse_expr("1 + 2 FROM")
	testing.expect(t, sql.has_error(err))
	testing.expect(t, expr == nil)
	sql.free_error(err)

	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_reject_empty_primary_key_list :: proc(t: ^testing.T) {
	_, err := sql.parse_statement("CREATE TABLE t (a INT, PRIMARY KEY ())")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect_value(t, err.code, sql.Parse_Error_Code.Empty_List)
}

@(test)
test_reject_empty_foreign_key_list :: proc(t: ^testing.T) {
	_, err := sql.parse_statement("CREATE TABLE t (a INT, FOREIGN KEY () REFERENCES o(id))")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect_value(t, err.code, sql.Parse_Error_Code.Empty_List)
}

@(test)
test_reject_empty_using_list :: proc(t: ^testing.T) {
	_, err := sql.parse_statement("SELECT * FROM a JOIN b USING ()")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect_value(t, err.code, sql.Parse_Error_Code.Empty_List)
}

@(test)
test_reject_empty_values_row :: proc(t: ^testing.T) {
	_, err := sql.parse_statement("INSERT INTO t VALUES ()")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect_value(t, err.code, sql.Parse_Error_Code.Empty_List)
}

@(test)
test_reject_empty_index_column_list :: proc(t: ^testing.T) {
	_, err := sql.parse_statement("CREATE INDEX i ON t ()")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect_value(t, err.code, sql.Parse_Error_Code.Empty_List)
}

@(test)
test_reject_odd_length_blob :: proc(t: ^testing.T) {
	tokens, err := sql.tokenize("X'ABC'")
	defer delete(tokens)
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect(t, contains_ci(err.message, "even"))
	testing.expect_value(t, err.code, sql.Parse_Error_Code.Invalid_Blob)
}

@(test)
test_reject_like_clearly :: proc(t: ^testing.T) {
	_, err := sql.parse_expr("a LIKE b")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect(t, contains_ci(err.message, "LIKE"))
	testing.expect_value(t, err.code, sql.Parse_Error_Code.Unsupported_Syntax)
}

@(test)
test_replace_function_call_ok :: proc(t: ^testing.T) {
	expr, err := sql.parse_expr("REPLACE('a', 'b', 'c')")
	defer sql.free_error(err)
	defer free_expr(expr)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	testing.expect_value(t, expr.kind, sql.Expr_Kind.Call)
}

@(test)
test_current_date_primary_ok :: proc(t: ^testing.T) {
	expr, err := sql.parse_expr("CURRENT_DATE")
	defer sql.free_error(err)
	defer free_expr(expr)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, expr.kind, sql.Expr_Kind.Call)
}

contains_ci :: proc(s, sub: string) -> bool {
	// simple ASCII contains for assertions
	for i in 0 ..< len(s) {
		if i + len(sub) > len(s) {
			break
		}
		ok := true
		for j in 0 ..< len(sub) {
			a := s[i + j]
			b := sub[j]
			if a >= 'A' && a <= 'Z' {
				a += 'a' - 'A'
			}
			if b >= 'A' && b <= 'Z' {
				b += 'a' - 'A'
			}
			if a != b {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}
