package sql_tests

import "core:os"
import "core:strings"
import "core:testing"
import sql "../../sql"

// Golden AST dumps: sibling `.ast` files next to fixture `.sql` under fixtures/.
// Regenerate with: odin run tools/regen_ast_goldens
// Comparison trims trailing whitespace/newlines then requires a single trailing '\n'.

@(test)
test_golden_bootstrap :: proc(t: ^testing.T) {
	assert_fixture_golden(t, "bootstrap.sql")
}

@(test)
test_golden_bootstrap_v1 :: proc(t: ^testing.T) {
	assert_fixture_golden(t, "bootstrap_v1.sql")
}

@(test)
test_golden_crud :: proc(t: ^testing.T) {
	assert_fixture_golden(t, "crud.sql")
}

@(test)
test_golden_phase5 :: proc(t: ^testing.T) {
	assert_fixture_golden(t, "phase5.sql")
}

assert_fixture_golden :: proc(t: ^testing.T, sql_name: string) {
	sql_path := strings.concatenate({"src/test/sql/fixtures/", sql_name}, context.allocator)
	defer delete(sql_path)
	ast_path := strings.concatenate({sql_path[:len(sql_path) - 4], ".ast"}, context.allocator)
	defer delete(ast_path)

	src, src_err := os.read_entire_file_from_path(sql_path, context.allocator)
	testing.expectf(t, src_err == os.ERROR_NONE, "read %s: %v", sql_path, src_err)
	defer delete(src)

	want_raw, want_err := os.read_entire_file_from_path(ast_path, context.allocator)
	testing.expectf(t, want_err == os.ERROR_NONE, "read %s: %v (regen: odin run tools/regen_ast_goldens)", ast_path, want_err)
	defer delete(want_raw)

	script, err := sql.parse_script(string(src))
	defer sql.free_error(err)
	defer sql.free_script(script)
	testing.expectf(t, !sql.has_error(err), "%s: %s", sql_name, err.message)

	got_raw := sql.print_script(script)
	defer delete(got_raw)

	got := normalize_golden(got_raw)
	defer delete(got)
	want := normalize_golden(string(want_raw))
	defer delete(want)
	testing.expectf(t, got == want, "golden mismatch for %s\n--- got ---\n%s\n--- want ---\n%s", sql_name, got, want)
}

normalize_golden :: proc(s: string) -> string {
	trimmed := strings.trim_right(s, " \t\r\n")
	return strings.concatenate({trimmed, "\n"}, context.allocator)
}
