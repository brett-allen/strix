package cli_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import cli "../../cli"
import exec "../../exec"

@(test)
test_run_bare_non_tty_usage_exits_1 :: proc(t: ^testing.T) {
	testing.expect_value(t, cli.run_bare(false), 1)
}

@(test)
test_run_bare_tty_enters_shell_open_path :: proc(t: ^testing.T) {
	// TTY → shell_run(path). Missing DB returns 1 before stdin read (no hang).
	missing := fmt.tprintf("/tmp/strix-c5-bare-missing-%d.strix", os.get_pid())
	os.remove(missing)
	testing.expect_value(t, cli.run_bare(true, missing), 1)

	// Existing DB: drive real run_bare → shell_run via injected stdin (not shell_run_lines).
	path := fmt.tprintf("/tmp/strix-c5-bare-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	r, w, perr := os.pipe()
	testing.expect(t, perr == nil)
	_, werr := os.write_string(w, ".quit\n")
	testing.expect(t, werr == nil)
	os.close(w)
	old_stdin := os.stdin
	os.stdin = r
	code := cli.run_bare(true, path)
	os.stdin = old_stdin
	os.close(r)
	testing.expect_value(t, code, 0)
}

@(test)
test_shell_run_stdin_quit_and_bail :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c5-shell-run-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	// Clean .quit via real shell_run stdin loop.
	{
		r, w, perr := os.pipe()
		testing.expect(t, perr == nil)
		_, werr := os.write_string(w, ".quit\n")
		testing.expect(t, werr == nil)
		os.close(w)
		old_stdin := os.stdin
		os.stdin = r
		code := cli.shell_run(path, false)
		os.stdin = old_stdin
		os.close(r)
		testing.expect_value(t, code, 0)
	}

	// --bail via shell_run: SQL error stops; later CREATE must not run.
	{
		r, w, perr := os.pipe()
		testing.expect(t, perr == nil)
		_, werr := os.write_string(
			w,
			"SELECT * FROM missing;\nCREATE TABLE should_not_run (id INTEGER PRIMARY KEY);\n",
		)
		testing.expect(t, werr == nil)
		os.close(w)
		old_stdin := os.stdin
		os.stdin = r
		code := cli.shell_run(path, true)
		os.stdin = old_stdin
		os.close(r)
		testing.expect_value(t, code, 1)

		session, err := exec.session_open(path)
		testing.expect(t, !exec.has_error(err))
		defer exec.free_error(err)
		defer exec.session_close(&session)
		names, lerr := exec.list_tables(&session)
		testing.expectf(t, !exec.has_error(lerr), "%s", lerr.message)
		defer exec.free_error(lerr)
		defer exec.free_table_names(names)
		for name in names {
			testing.expect(t, name != "should_not_run")
		}
	}
}

@(test)
test_parse_shell_command_args_bail :: proc(t: ^testing.T) {
	a := cli.parse_shell_command_args([]string{})
	testing.expect(t, a.ok)
	testing.expect_value(t, a.path, cli.DEFAULT_DB_PATH)
	testing.expect(t, !a.bail)

	b := cli.parse_shell_command_args([]string{"--bail"})
	testing.expect(t, b.ok)
	testing.expect(t, b.bail)

	c := cli.parse_shell_command_args([]string{"demo.strix", "--bail"})
	testing.expect(t, c.ok)
	testing.expect_value(t, c.path, "demo.strix")
	testing.expect(t, c.bail)

	d := cli.parse_shell_command_args([]string{"--bail", "demo.strix"})
	testing.expect(t, d.ok)
	testing.expect_value(t, d.path, "demo.strix")
	testing.expect(t, d.bail)

	e := cli.parse_shell_command_args([]string{"a", "b"})
	testing.expect(t, !e.ok)

	f := cli.parse_shell_command_args([]string{"--unknown"})
	testing.expect(t, !f.ok)
}

@(test)
test_shell_bail_exits_1_on_sql_error :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c5-bail-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	code := cli.shell_run_lines(
		path,
		[]string{
			"SELECT * FROM missing;",
			"CREATE TABLE should_not_run (id INTEGER PRIMARY KEY);",
			".quit",
		},
		false,
		true, // bail
	)
	testing.expect_value(t, code, 1)

	session, err := exec.session_open(path)
	testing.expect(t, !exec.has_error(err))
	defer exec.free_error(err)
	defer exec.session_close(&session)
	names, lerr := exec.list_tables(&session)
	testing.expectf(t, !exec.has_error(lerr), "%s", lerr.message)
	defer exec.free_error(lerr)
	defer exec.free_table_names(names)
	testing.expect_value(t, len(names), 0)
}

@(test)
test_shell_bail_stops_sibling_sql_on_same_line :: proc(t: ^testing.T) {
	// --bail must stop drain mid-line: error then sibling CREATE must not run.
	path := fmt.tprintf("/tmp/strix-c5-bail-same-line-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	code := cli.shell_run_lines(
		path,
		[]string{
			"SELECT * FROM missing; CREATE TABLE should_not_run (id INTEGER PRIMARY KEY);",
			".quit",
		},
		false,
		true, // bail
	)
	testing.expect_value(t, code, 1)

	session, err := exec.session_open(path)
	testing.expect(t, !exec.has_error(err))
	defer exec.free_error(err)
	defer exec.session_close(&session)
	names, lerr := exec.list_tables(&session)
	testing.expectf(t, !exec.has_error(lerr), "%s", lerr.message)
	defer exec.free_error(lerr)
	defer exec.free_table_names(names)
	testing.expect_value(t, len(names), 0)
}

@(test)
test_shell_bail_quit_after_error_exits_1 :: proc(t: ^testing.T) {
	// Without immediate stop from a second line: error then .quit still exits 1.
	path := fmt.tprintf("/tmp/strix-c5-bail-quit-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	s.bail = true
	testing.expect_value(t, cli.shell_open_path(&s, path), 0)

	testing.expect(t, !cli.shell_process_line(&s, "SELECT * FROM missing;"))
	testing.expect(t, s.had_sql_error)
	testing.expect(t, s.quit) // bail sets quit
	testing.expect_value(t, cli.shell_finish_eof(&s), 1)
}

@(test)
test_meta_parse_output_separator_nullvalue :: proc(t: ^testing.T) {
	o := cli.meta_parse(".output out.txt;")
	testing.expect(t, o.ok)
	testing.expect_value(t, o.kind, cli.Meta_Kind.Output)
	testing.expect_value(t, o.args, "out.txt")

	o2 := cli.meta_parse(".output stdout")
	testing.expect_value(t, o2.kind, cli.Meta_Kind.Output)
	testing.expect_value(t, o2.args, "stdout")

	sep := cli.meta_parse(".separator ,")
	testing.expect_value(t, sep.kind, cli.Meta_Kind.Separator)
	testing.expect_value(t, sep.args, ",")

	nv := cli.meta_parse(".nullvalue \\N")
	testing.expect_value(t, nv.kind, cli.Meta_Kind.Nullvalue)
	testing.expect_value(t, nv.args, "\\N")
}

@(test)
test_shell_separator_list_mode :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c5-sep-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	r, w, perr := os.pipe()
	testing.expect(t, perr == nil)
	old_stdout := os.stdout
	os.stdout = w
	code := cli.shell_run_lines(
		path,
		[]string{
			"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);",
			"INSERT INTO t (name) VALUES ('a');",
			".mode list",
			".separator ,",
			"SELECT id, name FROM t;",
			".quit",
		},
	)
	os.close(w)
	os.stdout = old_stdout
	data, rerr := os.read_entire_file_from_file(r, context.allocator)
	os.close(r)
	testing.expect(t, rerr == nil)
	out := string(data)
	defer delete(out)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "id,name"))
	testing.expect(t, strings.contains(out, "1,a"))
}

@(test)
test_shell_nullvalue_replaces_null_cells :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c5-null-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	r, w, perr := os.pipe()
	testing.expect(t, perr == nil)
	old_stdout := os.stdout
	os.stdout = w
	code := cli.shell_run_lines(
		path,
		[]string{
			"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);",
			"INSERT INTO t (id, name) VALUES (1, NULL);",
			".mode list",
			".headers off",
			".nullvalue -",
			"SELECT id, name FROM t;",
			".quit",
		},
	)
	os.close(w)
	os.stdout = old_stdout
	data, rerr := os.read_entire_file_from_file(r, context.allocator)
	os.close(r)
	testing.expect(t, rerr == nil)
	out := string(data)
	defer delete(out)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "1|-"))
	testing.expect(t, !strings.contains(out, "1|NULL"))
}

@(test)
test_shell_output_redirect_and_restore :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c5-out-%d.strix", os.get_pid())
	out_path := fmt.tprintf("/tmp/strix-c5-out-%d.txt", os.get_pid())
	defer os.remove(path)
	defer os.remove(out_path)

	testing.expect_value(t, cli.init_database(path), 0)

	r, w, perr := os.pipe()
	testing.expect(t, perr == nil)
	old_stdout := os.stdout
	os.stdout = w
	code := cli.shell_run_lines(
		path,
		[]string{
			"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);",
			"INSERT INTO t (name) VALUES ('redir');",
			fmt.tprintf(".output %s", out_path),
			".mode list",
			".headers off",
			"SELECT name FROM t;",
			".output stdout",
			"SELECT name FROM t;",
			".quit",
		},
	)
	os.close(w)
	os.stdout = old_stdout
	data, rerr := os.read_entire_file_from_file(r, context.allocator)
	os.close(r)
	testing.expect(t, rerr == nil)
	stdout_text := string(data)
	defer delete(stdout_text)
	testing.expect_value(t, code, 0)

	file_data, ferr := os.read_entire_file_from_path(out_path, context.allocator)
	testing.expect(t, ferr == nil)
	file_text := string(file_data)
	defer delete(file_text)

	testing.expect(t, strings.contains(file_text, "redir"))
	// After restore, second SELECT should appear on captured stdout.
	testing.expect(t, strings.contains(stdout_text, "redir"))
}

@(test)
test_meta_help_text_lists_c5_commands :: proc(t: ^testing.T) {
	text := cli.meta_help_text()
	testing.expect(t, strings.contains(text, ".output"))
	testing.expect(t, strings.contains(text, ".separator"))
	testing.expect(t, strings.contains(text, ".nullvalue"))
}

@(test)
test_format_result_set_custom_separator_and_nullvalue :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c5-fmt-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)
	testing.expect_value(
		t,
		cli.run_sql(path, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t (id, name) VALUES (1, NULL);"),
		0,
	)

	session, err := exec.session_open(path)
	testing.expect(t, !exec.has_error(err))
	defer exec.free_error(err)
	defer exec.session_close(&session)
	r, eerr := exec.exec_statement(&session, "SELECT id, name FROM t;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	defer exec.free_error(eerr)
	defer exec.free_result(r)

	text := cli.format_result_set(
		r,
		cli.Display_Opts{headers = true, mode = .List, separator = ",", nullvalue = "?"},
	)
	defer delete(text)
	testing.expect(t, strings.contains(text, "id,name\n"))
	testing.expect(t, strings.contains(text, "1,?\n"))
}

@(test)
test_shell_separator_nullvalue_print_current :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c5-print-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	r, w, perr := os.pipe()
	testing.expect(t, perr == nil)
	old_stdout := os.stdout
	os.stdout = w
	code := cli.shell_run_lines(path, []string{".separator", ".nullvalue", ".quit"})
	os.close(w)
	os.stdout = old_stdout
	data, rerr := os.read_entire_file_from_file(r, context.allocator)
	os.close(r)
	testing.expect(t, rerr == nil)
	out := string(data)
	defer delete(out)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "|\n") || strings.contains(out, "|"))
	testing.expect(t, strings.contains(out, "NULL"))
}
