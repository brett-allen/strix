package cli_tests

import "core:strings"
import "core:testing"
import cli "../../cli"

@(test)
test_shell_line_kind_empty_meta_sql :: proc(t: ^testing.T) {
	testing.expect_value(t, cli.shell_line_kind(""), cli.Shell_Line_Kind.Empty)
	testing.expect_value(t, cli.shell_line_kind("   \t  "), cli.Shell_Line_Kind.Empty)
	testing.expect_value(t, cli.shell_line_kind(".help"), cli.Shell_Line_Kind.Meta)
	testing.expect_value(t, cli.shell_line_kind("  .quit"), cli.Shell_Line_Kind.Meta)
	testing.expect_value(t, cli.shell_line_kind("SELECT 1;"), cli.Shell_Line_Kind.Sql)
	testing.expect_value(t, cli.shell_line_kind("  create table t (a int);"), cli.Shell_Line_Kind.Sql)
}

@(test)
test_shell_sql_ready_basic :: proc(t: ^testing.T) {
	testing.expect(t, !cli.shell_sql_ready(""))
	testing.expect(t, !cli.shell_sql_ready("SELECT 1"))
	testing.expect(t, cli.shell_sql_ready("SELECT 1;"))
	testing.expect(t, cli.shell_sql_ready("SELECT 1; SELECT 2"))
	testing.expect_value(t, cli.shell_sql_first_complete_end("SELECT 1; SELECT 2"), 9)
}

@(test)
test_shell_sql_ready_string_and_comment_aware :: proc(t: ^testing.T) {
	testing.expect(t, !cli.shell_sql_ready("SELECT 'a;b'"))
	testing.expect(t, cli.shell_sql_ready("SELECT 'a;b';"))
	testing.expect_value(t, cli.shell_sql_first_complete_end("SELECT 'a;b';"), 13)

	testing.expect(t, !cli.shell_sql_ready("SELECT 1 -- trailing;"))
	testing.expect(t, cli.shell_sql_ready("SELECT 1 -- trailing;\n;"))
	testing.expect(t, !cli.shell_sql_ready("SELECT /* ; */ 1"))
	testing.expect(t, cli.shell_sql_ready("SELECT /* ; */ 1;"))

	testing.expect(t, !cli.shell_sql_ready(`SELECT "col;name"`))
	testing.expect(t, cli.shell_sql_ready(`SELECT "col;name";`))

	testing.expect(t, cli.shell_sql_ready("SELECT 'it''s;ok';"))
	testing.expect(t, cli.shell_sql_ready("SELECT X'ABCD';"))
	testing.expect(t, !cli.shell_sql_ready("SELECT X'AB"))
}

@(test)
test_shell_prompt_primary_vs_continuation :: proc(t: ^testing.T) {
	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)

	testing.expect_value(t, cli.shell_prompt(&s), cli.PROMPT_PRIMARY)
	strings.write_string(&s.sql_buf, "SELECT 1")
	testing.expect_value(t, cli.shell_prompt(&s), cli.PROMPT_CONT)
}
