package cli_tests

import "core:fmt"
import "core:os"
import "core:testing"
import cli "../../cli"
import engine "../../engine"
import exec "../../exec"

@(test)
test_shell_missing_file_exits_1 :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c1-missing-%d.strix", os.get_pid())
	os.remove(path)
	code := cli.shell_run_lines(path, []string{".quit"})
	testing.expect_value(t, code, 1)
}

@(test)
test_shell_open_exec_quit_smoke :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c1-shell-%d.strix", os.get_pid())
	defer os.remove(path)

	testing.expect_value(t, cli.init_database(path), 0)
	code := cli.shell_run_lines(
		path,
		[]string{
			"CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);",
			"INSERT INTO users (name) VALUES ('a'), ('b');",
			"SELECT id, name FROM users ORDER BY id;",
			".quit",
		},
	)
	testing.expect_value(t, code, 0)

	session, err := exec.session_open(path)
	testing.expect(t, !exec.has_error(err))
	defer exec.free_error(err)
	defer exec.session_close(&session)
	r, eerr := exec.exec_statement(&session, "SELECT id, name FROM users ORDER BY id;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 2)
	testing.expect_value(t, r.rows[0][1], "a")
	testing.expect_value(t, r.rows[1][1], "b")
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_shell_multiline_sql_then_quit :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c1-multiline-%d.strix", os.get_pid())
	defer os.remove(path)

	testing.expect_value(t, cli.init_database(path), 0)
	code := cli.shell_run_lines(
		path,
		[]string{
			"CREATE TABLE t (",
			"  id INTEGER PRIMARY KEY,",
			"  n TEXT",
			");",
			".exit",
		},
	)
	testing.expect_value(t, code, 0)

	e, err := engine.engine_open(path)
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	entry, gerr := engine.catalog_get_table_entry(&e, "t")
	testing.expect(t, engine.ok(gerr))
	testing.expect_value(t, len(entry.columns), 2)
	engine.free_catalog_entry(entry)
}

@(test)
test_shell_sql_error_continues_then_quit :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c1-continue-%d.strix", os.get_pid())
	defer os.remove(path)

	testing.expect_value(t, cli.init_database(path), 0)
	code := cli.shell_run_lines(
		path,
		[]string{
			"CREATE TABLE t (id INTEGER PRIMARY KEY);",
			"INSERT INTO missing VALUES (1);", // error — REPL must continue
			"INSERT INTO t (id) VALUES (1);",
			".quit",
		},
	)
	testing.expect_value(t, code, 0)

	session, err := exec.session_open(path)
	testing.expect(t, !exec.has_error(err))
	defer exec.free_error(err)
	defer exec.session_close(&session)
	r, eerr := exec.exec_statement(&session, "SELECT id FROM t;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_shell_meta_while_sql_buffer_rejected :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c1-metabuf-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	testing.expect_value(t, cli.shell_open_path(&s, path), 0)

	testing.expect(t, !cli.shell_process_line(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY"))
	testing.expect(t, !cli.shell_process_line(&s, ".help"))
	testing.expect(t, !s.quit)
	// Buffer preserved — finishing the statement still works.
	testing.expect(t, !cli.shell_process_line(&s, ");"))
	testing.expect(t, cli.shell_process_line(&s, ".quit"))

	e, err := engine.engine_open(path)
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	entry, gerr := engine.catalog_get_table_entry(&e, "t")
	testing.expect(t, engine.ok(gerr))
	engine.free_catalog_entry(entry)
}

@(test)
test_shell_empty_lines_ignored_at_primary :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c1-empty-%d.strix", os.get_pid())
	defer os.remove(path)

	testing.expect_value(t, cli.init_database(path), 0)
	code := cli.shell_run_lines(path, []string{"", "   ", "\t", ".quit"})
	testing.expect_value(t, code, 0)
}

@(test)
test_shell_incomplete_eof_exits_1 :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c1-incomplete-%d.strix", os.get_pid())
	defer os.remove(path)

	testing.expect_value(t, cli.init_database(path), 0)
	code := cli.shell_run_lines(path, []string{"SELECT 1"})
	testing.expect_value(t, code, 1)
}

@(test)
test_run_dispatches_shell_subcommand :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c1-run-shell-%d", os.get_pid())
	strix_path := fmt.tprintf("%s.strix", path)
	defer os.remove(strix_path)

	testing.expect_value(t, cli.run([]string{"init", path}), 0)
	// Missing file path for shell via run with injected driver is shell_run_lines;
	// verify dispatch rejects too many args and accepts shell path open failure.
	missing := fmt.tprintf("/tmp/strix-c1-run-missing-%d.strix", os.get_pid())
	os.remove(missing)
	testing.expect_value(t, cli.run_shell_command([]string{missing}), 1)
	testing.expect_value(t, cli.run_shell_command([]string{"a", "b"}), 1)
}

@(test)
test_shell_string_semicolon_not_terminator_via_repl :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c1-strsemi-%d.strix", os.get_pid())
	defer os.remove(path)

	testing.expect_value(t, cli.init_database(path), 0)
	code := cli.shell_run_lines(
		path,
		[]string{
			"CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);",
			"INSERT INTO t (n) VALUES ('a;b');",
			"SELECT n FROM t;",
			".quit",
		},
	)
	testing.expect_value(t, code, 0)

	session, err := exec.session_open(path)
	testing.expect(t, !exec.has_error(err))
	defer exec.free_error(err)
	defer exec.session_close(&session)
	r, eerr := exec.exec_statement(&session, "SELECT n FROM t;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.rows[0][0], "a;b")
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_meta_dispatch_help_and_quit :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c1-meta-disp-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	testing.expect_value(t, cli.shell_open_path(&s, path), 0)

	help := cli.meta_parse(".help")
	testing.expect(t, !cli.meta_dispatch(&s, help))
	testing.expect(t, !s.quit)

	quit := cli.meta_parse(".quit")
	testing.expect(t, cli.meta_dispatch(&s, quit))
	testing.expect(t, s.quit)
}

@(test)
test_usage_mentions_shell :: proc(t: ^testing.T) {
	testing.expect_value(t, cli.run([]string{"help"}), 0)
	// shell verb is recognized (missing DB → 1, not unknown-command path alone)
	missing := fmt.tprintf("/tmp/strix-c1-usage-missing-%d.strix", os.get_pid())
	os.remove(missing)
	testing.expect_value(t, cli.run([]string{"shell", missing}), 1)
}
