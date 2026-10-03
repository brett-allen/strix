package sql_tests

import "core:os"
import "core:strings"
import "core:testing"
import sql "../../sql"

@(test)
test_cast_expr :: proc(t: ^testing.T) {
	expr, err := sql.parse_expr("CAST(id AS INTEGER)")
	defer sql.free_error(err)
	defer free_expr(expr)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	testing.expect_value(t, expr.kind, sql.Expr_Kind.Cast)
	testing.expect_value(t, expr.data.(sql.Cast_Data).type_name, "INTEGER")
}

@(test)
test_cast_in_select :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("SELECT CAST(x AS TEXT) FROM t")
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))
	got := sql.print_statement(stmt)
	defer delete(got)
	testing.expect(t, strings.contains(got, "CAST("))
}

@(test)
test_insert_rejects_default_values :: proc(t: ^testing.T) {
	_, err := sql.parse_statement("INSERT INTO t DEFAULT VALUES")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect(t, strings.contains(err.message, "DEFAULT VALUES"))
}

@(test)
test_phase5_fixture :: proc(t: ^testing.T) {
	path := "src/test/sql/fixtures/phase5.sql"
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	testing.expectf(t, read_err == os.ERROR_NONE, "read %s: %v", path, read_err)
	defer delete(data)

	script, err := sql.parse_script(string(data))
	defer sql.free_error(err)
	defer sql.free_script(script)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	testing.expect(t, len(script.statements) >= 4)

	dump := sql.print_script(script)
	defer delete(dump)
	testing.expect(t, strings.contains(dump, "JOIN"))
	testing.expect(t, strings.contains(dump, "GROUP BY"))
	testing.expect(t, strings.contains(dump, "ALTER TABLE"))
	testing.expect(t, strings.contains(dump, "CAST("))
}

@(test)
test_bootstrap_v1_script :: proc(t: ^testing.T) {
	path := "src/test/sql/fixtures/bootstrap_v1.sql"
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	testing.expectf(t, read_err == os.ERROR_NONE, "read %s: %v", path, read_err)
	defer delete(data)

	script, err := sql.parse_script(string(data))
	defer sql.free_error(err)
	defer sql.free_script(script)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	testing.expect_value(t, len(script.statements), 7)
}
