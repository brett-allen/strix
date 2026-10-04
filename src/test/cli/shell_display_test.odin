package cli_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import cli "../../cli"
import exec "../../exec"

@(test)
test_format_result_set_headers_off_omits_names :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c3-headers-fmt-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)
	testing.expect_value(
		t,
		cli.run_sql(path, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t (name) VALUES ('a');"),
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

	with_h := cli.format_result_set(r)
	defer delete(with_h)
	testing.expect(t, strings.contains(with_h, "id"))
	testing.expect(t, strings.contains(with_h, "name"))

	no_h := cli.format_result_set(r, cli.Display_Opts{headers = false, mode = .Column})
	defer delete(no_h)
	testing.expect(t, !strings.contains(no_h, "id"))
	testing.expect(t, !strings.contains(no_h, "name"))
	testing.expect(t, strings.contains(no_h, "1"))
	testing.expect(t, strings.contains(no_h, "a"))
}

@(test)
test_format_result_set_list_mode_separators :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c3-list-fmt-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)
	testing.expect_value(
		t,
		cli.run_sql(path, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t (name) VALUES ('a'), ('b');"),
		0,
	)

	session, err := exec.session_open(path)
	testing.expect(t, !exec.has_error(err))
	defer exec.free_error(err)
	defer exec.session_close(&session)
	r, eerr := exec.exec_statement(&session, "SELECT id, name FROM t ORDER BY id;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	defer exec.free_error(eerr)
	defer exec.free_result(r)

	text := cli.format_result_set(r, cli.Display_Opts{headers = true, mode = .List})
	defer delete(text)
	testing.expect(t, strings.contains(text, "id|name\n"))
	testing.expect(t, strings.contains(text, "1|a\n"))
	testing.expect(t, strings.contains(text, "2|b\n"))

	no_h := cli.format_result_set(r, cli.Display_Opts{headers = false, mode = .List})
	defer delete(no_h)
	testing.expect(t, !strings.contains(no_h, "id|name"))
	testing.expect(t, strings.has_prefix(no_h, "1|a\n"))
}

@(test)
test_shell_headers_off_omits_names_stdout :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c3-headers-shell-%d.strix", os.get_pid())
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
			"INSERT INTO t (name) VALUES ('x');",
			".headers off",
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
	testing.expect(t, !strings.contains(out, "id"))
	testing.expect(t, !strings.contains(out, "name"))
	testing.expect(t, strings.contains(out, "x"))
}

@(test)
test_shell_mode_list_stdout :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c3-mode-shell-%d.strix", os.get_pid())
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
	testing.expect(t, strings.contains(out, "id|name"))
	testing.expect(t, strings.contains(out, "1|a"))
}

@(test)
test_shell_read_temp_sql_round_trip :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c3-read-%d.strix", os.get_pid())
	sql_path := fmt.tprintf("/tmp/strix-c3-read-%d.sql", os.get_pid())
	defer os.remove(path)
	defer os.remove(sql_path)

	testing.expect_value(t, cli.init_database(path), 0)
	script :=
		"CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT);\n" +
		"INSERT INTO items (name) VALUES ('round'), ('trip');\n"
	werr := os.write_entire_file(sql_path, transmute([]byte)string(script))
	testing.expect(t, werr == nil)

	code := cli.shell_run_lines(
		path,
		[]string{
			fmt.tprintf(".read %s", sql_path),
			".quit",
		},
	)
	testing.expect_value(t, code, 0)

	session, err := exec.session_open(path)
	testing.expect(t, !exec.has_error(err))
	defer exec.free_error(err)
	defer exec.session_close(&session)

	names, lerr := exec.list_tables(&session)
	testing.expectf(t, !exec.has_error(lerr), "%s", lerr.message)
	defer exec.free_error(lerr)
	defer exec.free_table_names(names)
	testing.expect_value(t, len(names), 1)
	testing.expect_value(t, names[0], "items")

	r, eerr := exec.exec_statement(&session, "SELECT name FROM items ORDER BY id;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	defer exec.free_error(eerr)
	defer exec.free_result(r)
	testing.expect_value(t, r.kind, exec.Result_Kind.Result_Set)
	testing.expect_value(t, len(r.rows), 2)
	testing.expect_value(t, r.rows[0][0], "round")
	testing.expect_value(t, r.rows[1][0], "trip")
}

@(test)
test_shell_read_missing_file_continues :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c3-read-missing-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	testing.expect_value(t, cli.shell_open_path(&s, path), 0)

	cmd := cli.meta_parse(".read /tmp/strix-c3-does-not-exist-xyz.sql")
	testing.expect(t, !cli.meta_dispatch(&s, cmd))
	testing.expect(t, !s.quit)
	testing.expect(t, cli.shell_process_line(&s, ".quit"))
}

@(test)
test_shell_headers_mode_usage_rejects_invalid :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c3-usage-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	testing.expect_value(t, cli.shell_open_path(&s, path), 0)

	testing.expect(t, !cli.meta_dispatch(&s, cli.meta_parse(".headers")))
	testing.expect(t, !cli.meta_dispatch(&s, cli.meta_parse(".headers maybe")))
	testing.expect_value(t, s.headers, true)

	testing.expect(t, !cli.meta_dispatch(&s, cli.meta_parse(".mode")))
	testing.expect(t, !cli.meta_dispatch(&s, cli.meta_parse(".mode csv")))
	testing.expect_value(t, s.mode, cli.Display_Mode.Column)

	testing.expect(t, !cli.meta_dispatch(&s, cli.meta_parse(".read")))
	testing.expect(t, !s.quit)
}

@(test)
test_shell_headers_on_and_mode_column_dispatch :: proc(t: ^testing.T) {
	// Cover .headers on and .mode column arms (not only off/list).
	path := fmt.tprintf("/tmp/strix-c3-on-column-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	testing.expect_value(t, cli.shell_open_path(&s, path), 0)

	testing.expect(t, !cli.meta_dispatch(&s, cli.meta_parse(".headers off")))
	testing.expect_value(t, s.headers, false)
	testing.expect(t, !cli.meta_dispatch(&s, cli.meta_parse(".headers on")))
	testing.expect_value(t, s.headers, true)

	testing.expect(t, !cli.meta_dispatch(&s, cli.meta_parse(".mode list")))
	testing.expect_value(t, s.mode, cli.Display_Mode.List)
	testing.expect(t, !cli.meta_dispatch(&s, cli.meta_parse(".mode column")))
	testing.expect_value(t, s.mode, cli.Display_Mode.Column)
}

@(test)
test_shell_read_dot_commands_are_sql_not_meta :: proc(t: ^testing.T) {
	// .read files are SQL-only: .quit / .tables inside must not run as meta.
	path := fmt.tprintf("/tmp/strix-c3-read-dots-%d.strix", os.get_pid())
	sql_path := fmt.tprintf("/tmp/strix-c3-read-dots-%d.sql", os.get_pid())
	defer os.remove(path)
	defer os.remove(sql_path)

	testing.expect_value(t, cli.init_database(path), 0)
	script := ".quit\n.tables\n"
	werr := os.write_entire_file(sql_path, transmute([]byte)string(script))
	testing.expect(t, werr == nil)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	testing.expect_value(t, cli.shell_open_path(&s, path), 0)

	cmd := cli.meta_parse(fmt.tprintf(".read %s", sql_path))
	testing.expect(t, !cli.meta_dispatch(&s, cmd))
	testing.expect(t, !s.quit) // must not treat .quit in file as meta

	// REPL continues: subsequent SQL works.
	testing.expect(t, !cli.shell_process_line(&s, "CREATE TABLE kept (id INTEGER PRIMARY KEY);"))
	testing.expect(t, cli.shell_process_line(&s, ".quit"))

	session, err := exec.session_open(path)
	testing.expect(t, !exec.has_error(err))
	defer exec.free_error(err)
	defer exec.session_close(&session)
	names, lerr := exec.list_tables(&session)
	testing.expectf(t, !exec.has_error(lerr), "%s", lerr.message)
	defer exec.free_error(lerr)
	defer exec.free_table_names(names)
	testing.expect_value(t, len(names), 1)
	testing.expect_value(t, names[0], "kept")
}

@(test)
test_shell_read_sql_error_continues_then_later_sql :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c3-read-sqlerr-%d.strix", os.get_pid())
	sql_path := fmt.tprintf("/tmp/strix-c3-read-sqlerr-%d.sql", os.get_pid())
	defer os.remove(path)
	defer os.remove(sql_path)

	testing.expect_value(t, cli.init_database(path), 0)
	script :=
		"CREATE TABLE t (id INTEGER PRIMARY KEY);\n" +
		"INSERT INTO missing_table (id) VALUES (1);\n"
	werr := os.write_entire_file(sql_path, transmute([]byte)string(script))
	testing.expect(t, werr == nil)

	code := cli.shell_run_lines(
		path,
		[]string{
			fmt.tprintf(".read %s", sql_path),
			"INSERT INTO t (id) VALUES (42);",
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
	defer exec.free_error(eerr)
	defer exec.free_result(r)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "42")
}

@(test)
test_batch_sql_select_still_headers_on :: proc(t: ^testing.T) {
	// Batch path must keep default aligned+headers even after shell display opts exist.
	path := fmt.tprintf("/tmp/strix-c3-batch-headers-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)
	testing.expect_value(
		t,
		cli.run_sql(path, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t (name) VALUES ('z');"),
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

	text := cli.format_result_set(r) // defaults
	defer delete(text)
	testing.expect(t, strings.has_prefix(text, "id"))
	testing.expect(t, strings.contains(text, "name"))
}
