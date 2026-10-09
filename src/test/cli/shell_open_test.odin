package cli_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import cli "../../cli"
import engine "../../engine"
import exec "../../exec"

@(test)
test_meta_parse_open :: proc(t: ^testing.T) {
	o := cli.meta_parse(".open")
	testing.expect(t, o.ok)
	testing.expect_value(t, o.kind, cli.Meta_Kind.Open)
	testing.expect_value(t, o.args, "")

	o2 := cli.meta_parse(".open other.strix;")
	testing.expect(t, o2.ok)
	testing.expect_value(t, o2.kind, cli.Meta_Kind.Open)
	testing.expect_value(t, o2.args, "other.strix")
}

@(test)
test_meta_help_text_lists_v1_including_open :: proc(t: ^testing.T) {
	text := cli.meta_help_text()
	testing.expect(t, strings.contains(text, ".help"))
	testing.expect(t, strings.contains(text, ".quit"))
	testing.expect(t, strings.contains(text, ".exit"))
	testing.expect(t, strings.contains(text, ".tables"))
	testing.expect(t, strings.contains(text, ".schema"))
	testing.expect(t, strings.contains(text, ".headers"))
	testing.expect(t, strings.contains(text, ".mode"))
	testing.expect(t, strings.contains(text, ".read"))
	testing.expect(t, strings.contains(text, ".open"))
}

@(test)
test_shell_open_no_args_prints_path :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c4-open-print-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	r, w, perr := os.pipe()
	testing.expect(t, perr == nil)
	old_stdout := os.stdout
	os.stdout = w
	code := cli.shell_run_lines(path, []string{".open", ".quit"})
	os.close(w)
	os.stdout = old_stdout
	data, rerr := os.read_entire_file_from_file(r, context.allocator)
	os.close(r)
	testing.expect(t, rerr == nil)
	out := string(data)
	defer delete(out)
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, path))
}

@(test)
test_shell_open_switches_database :: proc(t: ^testing.T) {
	a := fmt.tprintf("/tmp/strix-c4-open-a-%d.strix", os.get_pid())
	b := fmt.tprintf("/tmp/strix-c4-open-b-%d.strix", os.get_pid())
	defer os.remove(a)
	defer os.remove(b)

	testing.expect_value(t, cli.init_database(a), 0)
	testing.expect_value(t, cli.init_database(b), 0)
	testing.expect_value(
		t,
		cli.run_sql(a, "CREATE TABLE only_a (id INTEGER PRIMARY KEY);"),
		0,
	)
	testing.expect_value(
		t,
		cli.run_sql(b, "CREATE TABLE only_b (id INTEGER PRIMARY KEY);"),
		0,
	)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	testing.expect_value(t, cli.shell_open_path(&s, a), 0)
	prev_path := strings.clone(s.db_path)
	defer delete(prev_path)

	testing.expect(t, !cli.meta_dispatch(&s, cli.meta_parse(fmt.tprintf(".open %s", b))))
	testing.expect(t, !s.quit)
	testing.expect(t, s.db_path != prev_path)
	testing.expect(t, strings.has_suffix(s.db_path, "strix") || strings.contains(s.db_path, "open-b-"))
	testing.expect(t, strings.contains(s.db_path, "open-b-"))

	names, lerr := exec.list_tables(&s.session)
	testing.expectf(t, !exec.has_error(lerr), "%s", lerr.message)
	defer exec.free_error(lerr)
	defer exec.free_table_names(names)
	testing.expect_value(t, len(names), 1)
	testing.expect_value(t, names[0], "only_b")
}

@(test)
test_shell_open_failed_keeps_previous_session :: proc(t: ^testing.T) {
	a := fmt.tprintf("/tmp/strix-c4-open-keep-%d.strix", os.get_pid())
	missing := fmt.tprintf("/tmp/strix-c4-open-missing-%d.strix", os.get_pid())
	defer os.remove(a)
	os.remove(missing)

	testing.expect_value(t, cli.init_database(a), 0)
	testing.expect_value(
		t,
		cli.run_sql(a, "CREATE TABLE kept (id INTEGER PRIMARY KEY);"),
		0,
	)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	testing.expect_value(t, cli.shell_open_path(&s, a), 0)
	prev_path := strings.clone(s.db_path)
	defer delete(prev_path)

	ok := cli.shell_switch_path(&s, missing)
	testing.expect(t, !ok)
	testing.expect_value(t, s.db_path, prev_path)
	testing.expect(t, !s.quit)

	names, lerr := exec.list_tables(&s.session)
	testing.expectf(t, !exec.has_error(lerr), "%s", lerr.message)
	defer exec.free_error(lerr)
	defer exec.free_table_names(names)
	testing.expect_value(t, len(names), 1)
	testing.expect_value(t, names[0], "kept")

	// Also via meta dispatch
	testing.expect(t, !cli.meta_dispatch(&s, cli.meta_parse(fmt.tprintf(".open %s", missing))))
	testing.expect_value(t, s.db_path, prev_path)
	names2, lerr2 := exec.list_tables(&s.session)
	testing.expectf(t, !exec.has_error(lerr2), "%s", lerr2.message)
	defer exec.free_error(lerr2)
	defer exec.free_table_names(names2)
	testing.expect_value(t, names2[0], "kept")
}

@(test)
test_shell_clean_eof_exits_0 :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c4-clean-eof-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)
	code := cli.shell_run_lines(
		path,
		[]string{
			"CREATE TABLE t (id INTEGER PRIMARY KEY);",
			// no .quit — clean EOF with empty SQL buffer
		},
	)
	testing.expect_value(t, code, 0)
}

@(test)
test_shell_open_path_with_spaces_keeps_session_on_miss :: proc(t: ^testing.T) {
	// Remainder of line is one path (spaces allowed). Missing path keeps prior session.
	path := fmt.tprintf("/tmp/strix-c4-open-usage-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	testing.expect_value(t, cli.shell_open_path(&s, path), 0)
	prev := strings.clone(s.db_path)
	defer delete(prev)

	testing.expect(t, !cli.meta_dispatch(&s, cli.meta_parse(".open a b")))
	testing.expect_value(t, s.db_path, prev)
	testing.expect(t, !s.quit)

	// Quoted path with spaces also parses (still missing → keep session).
	testing.expect(t, !cli.meta_dispatch(&s, cli.meta_parse(`.open "no such dir/db.strix"`)))
	testing.expect_value(t, s.db_path, prev)
}

@(test)
test_shell_open_refuses_during_explicit_txn :: proc(t: ^testing.T) {
	a := fmt.tprintf("/tmp/strix-open-txn-a-%d.strix", os.get_pid())
	b := fmt.tprintf("/tmp/strix-open-txn-b-%d.strix", os.get_pid())
	defer os.remove(a)
	defer os.remove(b)
	testing.expect_value(t, cli.init_database(a), 0)
	testing.expect_value(t, cli.init_database(b), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	testing.expect_value(t, cli.shell_open_path(&s, a), 0)
	prev := strings.clone(s.db_path)
	defer delete(prev)

	r, eerr := exec.exec_statement(&s.session, "BEGIN;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	exec.free_error(eerr)
	exec.free_result(r)
	testing.expect(t, s.session.explicit_txn)

	ok := cli.shell_switch_path(&s, b)
	testing.expect(t, !ok)
	testing.expect_value(t, s.db_path, prev)
	testing.expect(t, s.session.explicit_txn)

	// Also via meta .open
	testing.expect(t, !cli.meta_dispatch(&s, cli.meta_parse(fmt.tprintf(".open %s", b))))
	testing.expect_value(t, s.db_path, prev)
}

@(test)
test_shell_open_refuses_after_flush_fence :: proc(t: ^testing.T) {
	// After auto-commit Flush_Failed: .open refuses; destroy refuses (session stays
	// open); retry COMMIT recovers; then destroy succeeds.
	a := fmt.tprintf("/tmp/strix-open-fence-a-%d.strix", os.get_pid())
	b := fmt.tprintf("/tmp/strix-open-fence-b-%d.strix", os.get_pid())
	defer os.remove(a)
	defer os.remove(b)
	testing.expect_value(t, cli.init_database(a), 0)
	testing.expect_value(t, cli.init_database(b), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	testing.expect_value(t, cli.shell_open_path(&s, a), 0)
	prev := strings.clone(s.db_path)
	defer delete(prev)

	r0, e0 := exec.exec_statement(
		&s.session,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	eng := exec.session_engine(&s.session)
	testing.expect(t, eng != nil)
	pager := engine.engine_pager_unsafe_for_tests(eng)
	pager.flush_fail_after_data_writes = 1

	r, eerr := exec.exec_statement(&s.session, "INSERT INTO t (id, n) VALUES (1, 'a');")
	testing.expect(t, exec.has_error(eerr))
	testing.expect(t, s.session.explicit_txn)
	testing.expect(t, eng.in_txn)
	testing.expect(t, exec.session_flush_fence(&s.session))
	exec.free_error(eerr)
	exec.free_result(r)

	ok := cli.shell_switch_path(&s, b)
	testing.expect(t, !ok)
	testing.expect_value(t, s.db_path, prev)
	testing.expect(t, s.session.explicit_txn)

	// .quit refused while fenced.
	testing.expect(t, !cli.meta_dispatch(&s, cli.meta_parse(".quit")))
	testing.expect(t, !s.quit)

	pager.flush_fail_after_data_writes = 0
	// Destroy refuses — session must remain open for recovery (not theater close).
	testing.expect(t, !cli.shell_state_destroy(&s))
	testing.expect(t, !s.session.closed)
	testing.expect(t, exec.session_engine(&s.session) != nil)
	testing.expect(t, exec.session_flush_fence(&s.session))
	// EOF/quit while fenced: refuse exit (same spirit as .quit); finish code stays non-zero.
	testing.expect(t, cli.shell_refuse_exit_while_fenced(&s))
	testing.expect_value(t, cli.shell_finish_eof(&s), 1)

	r2, e2 := exec.exec_statement(&s.session, "COMMIT;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect(t, !s.session.explicit_txn)
	testing.expect(t, !exec.session_flush_fence(&s.session))
	exec.free_error(e2)
	exec.free_result(r2)

	testing.expect(t, !cli.shell_refuse_exit_while_fenced(&s))
	testing.expect_value(t, cli.shell_finish_eof(&s), 0)
	testing.expect(t, cli.shell_state_destroy(&s))
}

@(test)
test_shell_typed_sql_fence_blocks_writes_allows_commit :: proc(t: ^testing.T) {
	// Shell typed SQL uses exec_statement: after fence, further INSERTs hard-stop;
	// recovery COMMIT still works.
	path := fmt.tprintf("/tmp/strix-shell-typed-fence-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	testing.expect_value(t, cli.shell_open_path(&s, path), 0)

	testing.expect(t, !cli.shell_process_line(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);"))

	eng := exec.session_engine(&s.session)
	pager := engine.engine_pager_unsafe_for_tests(eng)
	pager.flush_fail_after_data_writes = 1

	testing.expect(t, !cli.shell_process_line(&s, "INSERT INTO t VALUES (1, 'a');"))
	testing.expect(t, exec.session_flush_fence(&s.session))
	testing.expect(t, s.had_sql_error)

	s.had_sql_error = false
	testing.expect(t, !cli.shell_process_line(&s, "INSERT INTO t VALUES (2, 'b');"))
	testing.expect(t, s.had_sql_error)
	testing.expect(t, exec.session_flush_fence(&s.session))

	pager.flush_fail_after_data_writes = 0
	s.had_sql_error = false
	testing.expect(t, !cli.shell_process_line(&s, "COMMIT;"))
	testing.expect(t, !s.had_sql_error)
	testing.expect(t, !exec.session_flush_fence(&s.session))

	testing.expect(t, cli.shell_state_destroy(&s))

	session, err := exec.session_open(path)
	testing.expectf(t, !exec.has_error(err), "%s", err.message)
	exec.free_error(err)
	defer exec.session_close(&session)
	r, eerr := exec.exec_statement(&session, "SELECT id FROM t ORDER BY id;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_shell_bail_refuses_exit_while_fenced :: proc(t: ^testing.T) {
	// --bail must not set quit / process-exit over a live fence; COMMIT then exit works.
	path := fmt.tprintf("/tmp/strix-shell-bail-fence-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	s.bail = true
	testing.expect_value(t, cli.shell_open_path(&s, path), 0)

	testing.expect(t, !cli.shell_process_line(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);"))

	eng := exec.session_engine(&s.session)
	pager := engine.engine_pager_unsafe_for_tests(eng)
	pager.flush_fail_after_data_writes = 1

	testing.expect(t, !cli.shell_process_line(&s, "INSERT INTO t VALUES (1, 'a');"))
	testing.expect(t, exec.session_flush_fence(&s.session))
	testing.expect(t, s.had_sql_error)
	testing.expect(t, !s.quit) // bail must not quit over fence

	// Sibling on same line must not run; quit still refused.
	s.had_sql_error = false
	testing.expect(t, !cli.shell_process_line(
		&s,
		"INSERT INTO t VALUES (2, 'b'); INSERT INTO t VALUES (3, 'c');",
	))
	testing.expect(t, s.had_sql_error)
	testing.expect(t, !s.quit)
	testing.expect(t, cli.shell_should_stop_sql(&s))

	pager.flush_fail_after_data_writes = 0
	s.had_sql_error = false
	testing.expect(t, !cli.shell_process_line(&s, "COMMIT;"))
	testing.expect(t, !exec.session_flush_fence(&s.session))
	testing.expect(t, !s.had_sql_error)

	// After recovery, bail on a normal SQL error may quit.
	testing.expect(t, !cli.shell_process_line(&s, "SELECT * FROM missing;"))
	testing.expect(t, s.had_sql_error)
	testing.expect(t, s.quit)
	testing.expect_value(t, cli.shell_finish_eof(&s), 1)
	testing.expect(t, cli.shell_state_destroy(&s))
}

@(test)
test_shell_eof_refuses_exit_while_fenced_then_commit :: proc(t: ^testing.T) {
	// TTY-style stay path: refuse exit while fenced; COMMIT then destroy.
	path := fmt.tprintf("/tmp/strix-shell-eof-fence-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	testing.expect_value(t, cli.shell_open_path(&s, path), 0)
	testing.expect(t, !cli.shell_process_line(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);"))

	eng := exec.session_engine(&s.session)
	pager := engine.engine_pager_unsafe_for_tests(eng)
	pager.flush_fail_after_data_writes = 1
	testing.expect(t, !cli.shell_process_line(&s, "INSERT INTO t VALUES (1, 'a');"))
	testing.expect(t, exec.session_flush_fence(&s.session))

	// EOF / quit attempt while fenced: refuse exit; session stays open.
	testing.expect(t, cli.shell_refuse_exit_while_fenced(&s))
	testing.expect(t, !cli.shell_state_destroy(&s))
	testing.expect(t, !s.session.closed)

	pager.flush_fail_after_data_writes = 0
	testing.expect(t, !cli.shell_process_line(&s, "COMMIT;"))
	testing.expect(t, !exec.session_flush_fence(&s.session))
	testing.expect_value(t, cli.shell_finish_eof(&s), 0)
	testing.expect(t, cli.shell_state_destroy(&s))
}

@(test)
test_shell_run_lines_eof_while_fenced_forfeits :: proc(t: ^testing.T) {
	// Non-TTY shell_run_lines: input ends while fenced → exit 1 + forfeit-only
	// abandon messaging (no refuse-exit / retry-COMMIT-first coaching).
	path := fmt.tprintf("/tmp/strix-shell-lines-forfeit-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)
	testing.expect_value(
		t,
		cli.run_sql(path, "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);"),
		0,
	)

	r, w, perr := os.pipe()
	testing.expect(t, perr == nil)
	old_stderr := os.stderr
	os.stderr = w
	code := cli.shell_run_lines(
		path,
		[]string{"INSERT INTO t VALUES (1, 'a');"},
		false,
		false,
		1, // flush_fail_after_data_writes
	)
	os.close(w)
	os.stderr = old_stderr
	data, rerr := os.read_entire_file_from_file(r, context.allocator)
	os.close(r)
	testing.expect(t, rerr == nil)
	err_out := string(data)
	defer delete(err_out)

	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(err_out, cli.SHELL_FORFEIT_INPUT_ENDED))
	// Abandon path must not print refuse-exit / close-refused retry coaching.
	testing.expect(t, !strings.contains(err_out, "cannot exit while flush recovery"))
	testing.expect(t, !strings.contains(err_out, "retry COMMIT first"))
	testing.expect(t, !strings.contains(err_out, "close refused"))
}

@(test)
test_shell_open_success_resets_buffer_output_and_error_flags :: proc(t: ^testing.T) {
	a := fmt.tprintf("/tmp/strix-open-hygiene-a-%d.strix", os.get_pid())
	b := fmt.tprintf("/tmp/strix-open-hygiene-b-%d.strix", os.get_pid())
	out_path := fmt.tprintf("/tmp/strix-open-hygiene-out-%d.txt", os.get_pid())
	defer os.remove(a)
	defer os.remove(b)
	defer os.remove(out_path)
	testing.expect_value(t, cli.init_database(a), 0)
	testing.expect_value(t, cli.init_database(b), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	testing.expect_value(t, cli.shell_open_path(&s, a), 0)

	strings.write_string(&s.sql_buf, "SELECT 1")
	testing.expect(t, cli.shell_output_set(&s, out_path))
	s.had_sql_error = true
	s.quit = true
	s.bail = true // process-level flag must be kept

	testing.expect(t, cli.shell_switch_path(&s, b))
	testing.expect_value(t, strings.builder_len(s.sql_buf), 0)
	testing.expect(t, s.out_file == nil)
	testing.expect(t, !s.had_sql_error)
	testing.expect(t, !s.quit)
	testing.expect(t, s.bail)
	testing.expect(t, strings.contains(s.db_path, "hygiene-b-"))
}
