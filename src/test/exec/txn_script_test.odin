package exec_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import engine "../../engine"
import exec "../../exec"
import sql "../../sql"

@(test)
test_parse_begin_commit_rollback :: proc(t: ^testing.T) {
	cases := []struct {
		src:  string,
		kind: sql.Statement_Kind,
	}{
		{"BEGIN", .Begin},
		{"BEGIN TRANSACTION", .Begin},
		{"COMMIT", .Commit},
		{"COMMIT TRANSACTION", .Commit},
		{"ROLLBACK", .Rollback},
		{"ROLLBACK TRANSACTION", .Rollback},
	}
	for c in cases {
		stmt, err := sql.parse_statement(c.src)
		defer sql.free_error(err)
		defer sql.free_statement(stmt)
		testing.expectf(t, !sql.has_error(err), "%s: %s", c.src, err.message)
		testing.expect_value(t, stmt.kind, c.kind)
		printed := sql.print_statement(stmt)
		defer delete(printed)
		#partial switch c.kind {
		case .Begin:
			testing.expect_value(t, printed, "BEGIN")
		case .Commit:
			testing.expect_value(t, printed, "COMMIT")
		case .Rollback:
			testing.expect_value(t, printed, "ROLLBACK")
		}
	}
}

@(test)
test_begin_commit_persists_and_nested_begin_errors :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-e6-txn-commit-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)
		s := exec.session_adopt(&e)

		r, eerr := exec.exec_script(
			&s,
			"BEGIN; CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT); INSERT INTO t (id, n) VALUES (1, 'a'); COMMIT;",
		)
		testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
		exec.free_error(eerr)
		exec.free_result(r)
		testing.expect(t, !s.explicit_txn)
		testing.expect(t, !e.in_txn)
	}

	{
		e, err := engine.engine_open(path)
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)
		s := exec.session_adopt(&e)
		r, eerr := exec.exec_statement(&s, "SELECT n FROM t WHERE id = 1;")
		testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
		testing.expect_value(t, r.kind, exec.Result_Kind.Result_Set)
		testing.expect_value(t, len(r.rows), 1)
		testing.expect_value(t, r.rows[0][0], "a")
		exec.free_error(eerr)
		exec.free_result(r)
	}

	{
		e, err := engine.engine_open_memory()
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)
		s := exec.session_adopt(&e)
		r0, e0 := exec.exec_statement(&s, "BEGIN;")
		testing.expect(t, !exec.has_error(e0))
		exec.free_error(e0)
		exec.free_result(r0)

		r1, e1 := exec.exec_statement(&s, "BEGIN;")
		testing.expect(t, exec.has_error(e1))
		testing.expect_value(t, e1.code, exec.Exec_Error_Code.In_Txn)
		exec.free_error(e1)
		exec.free_result(r1)

		r2, e2 := exec.exec_statement(&s, "ROLLBACK;")
		testing.expect(t, !exec.has_error(e2))
		exec.free_error(e2)
		exec.free_result(r2)
	}
}

@(test)
test_rollback_undoes_and_no_auto_commit_inside_txn :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-e6-txn-rollback-%d.strix", os.get_pid())
	defer os.remove(path)

	e, err := engine.engine_create(path)
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);")
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)
	exec.free_result(r0)

	r1, e1 := exec.exec_script(
		&s,
		"BEGIN; INSERT INTO t (id, n) VALUES (1, 'x'); INSERT INTO t (id, n) VALUES (2, 'y');",
	)
	testing.expectf(t, !exec.has_error(e1), "%s", e1.message)
	exec.free_error(e1)
	exec.free_result(r1)
	testing.expect(t, s.explicit_txn)
	testing.expect(t, e.in_txn)

	// Visible inside open txn (not auto-committed to durable storage yet)
	rs2, es2 := exec.exec_statement(&s, "SELECT id FROM t ORDER BY id;")
	testing.expectf(t, !exec.has_error(es2), "%s", es2.message)
	testing.expect_value(t, len(rs2.rows), 2)
	exec.free_error(es2)
	exec.free_result(rs2)

	rr, er := exec.exec_statement(&s, "ROLLBACK;")
	testing.expectf(t, !exec.has_error(er), "%s", er.message)
	exec.free_error(er)
	exec.free_result(rr)
	testing.expect(t, !s.explicit_txn)
	testing.expect(t, !e.in_txn)

	rs3, es3 := exec.exec_statement(&s, "SELECT id FROM t;")
	testing.expectf(t, !exec.has_error(es3), "%s", es3.message)
	testing.expect_value(t, len(rs3.rows), 0)
	exec.free_error(es3)
	exec.free_result(rs3)
}

@(test)
test_failed_multirow_insert_inside_begin_aborts_txn :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-e6-txn-partial-insert-%d.strix", os.get_pid())
	defer os.remove(path)

	e, err := engine.engine_create(path)
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);")
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)
	exec.free_result(r0)

	r1, e1 := exec.exec_script(
		&s,
		"BEGIN; INSERT INTO t (id, n) VALUES (1, 'a'), (1, 'b');",
	)
	testing.expect(t, exec.has_error(e1))
	testing.expect_value(t, e1.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(e1)
	exec.free_result(r1)
	testing.expect(t, !s.explicit_txn)
	testing.expect(t, !e.in_txn)

	rs, es := exec.exec_statement(&s, "SELECT id FROM t;")
	testing.expectf(t, !exec.has_error(es), "%s", es.message)
	testing.expect_value(t, len(rs.rows), 0)
	exec.free_error(es)
	exec.free_result(rs)

	rc, ec := exec.exec_statement(&s, "COMMIT;")
	testing.expect_value(t, ec.code, exec.Exec_Error_Code.No_Txn)
	exec.free_error(ec)
	exec.free_result(rc)

	// Durable reopen: no partial row persisted
	e2, err2 := engine.engine_open(path)
	testing.expect(t, engine.ok(err2))
	defer engine.engine_close(&e2)
	s2 := exec.session_adopt(&e2)
	rs2, es2 := exec.exec_statement(&s2, "SELECT id FROM t;")
	testing.expectf(t, !exec.has_error(es2), "%s", es2.message)
	testing.expect_value(t, len(rs2.rows), 0)
	exec.free_error(es2)
	exec.free_result(rs2)
}

@(test)
test_commit_rollback_without_begin :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r1, e1 := exec.exec_statement(&s, "COMMIT;")
	testing.expect_value(t, e1.code, exec.Exec_Error_Code.No_Txn)
	exec.free_error(e1)
	exec.free_result(r1)

	r2, e2 := exec.exec_statement(&s, "ROLLBACK;")
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.No_Txn)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_script_stop_on_error_and_continue_on_error :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	// stop-on-error (default): third CREATE never runs
	r, eerr := exec.exec_script(
		&s,
		"CREATE TABLE a (x INT); CREATE TABLE a (y INT); CREATE TABLE c (z INT);",
	)
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Table_Exists)
	exec.free_error(eerr)
	exec.free_result(r)

	_, gerr_c := engine.catalog_get_table_entry(&e, "c")
	testing.expect_value(t, gerr_c, engine.Engine_Error.Not_Found)

	// continue-on-error: CREATE c still runs after the failure
	r2, eerr2 := exec.exec_script(
		&s,
		"CREATE TABLE a (y INT); CREATE TABLE c (z INT);",
		exec.Exec_Options{continue_on_error = true},
	)
	testing.expect(t, exec.has_error(eerr2))
	testing.expect_value(t, eerr2.code, exec.Exec_Error_Code.Table_Exists)
	exec.free_error(eerr2)
	exec.free_result(r2)

	entry, gerr := engine.catalog_get_table_entry(&e, "c")
	testing.expect(t, engine.ok(gerr))
	engine.free_catalog_entry(entry)
}

@(test)
test_continue_on_error_stops_after_explicit_txn_abort :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	// BEGIN; failing INSERT aborts txn; later CREATE must NOT auto-commit even with continue_on_error.
	r, eerr := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT NOT NULL);" +
		"BEGIN;" +
		"INSERT INTO t (id, n) VALUES (1, NULL);" + // NOT NULL → abort txn
		"CREATE TABLE sneaky (x INT);" +
		"INSERT INTO t (id, n) VALUES (2, 'ok');",
		exec.Exec_Options{continue_on_error = true},
	)
	testing.expect(t, exec.has_error(eerr))
	testing.expect(t, strings.contains(eerr.message, "transaction aborted"))
	testing.expect(t, s.txn_aborted)
	testing.expect(t, !s.explicit_txn)
	exec.free_error(eerr)
	exec.free_result(r)

	_, gerr := engine.catalog_get_table_entry(&e, "sneaky")
	testing.expect_value(t, gerr, engine.Engine_Error.Not_Found)

	tree, oerr := engine.catalog_open_table(&e, "t")
	testing.expect(t, engine.ok(oerr))
	_, g2 := engine.table_get_row(&tree, 2)
	testing.expect_value(t, g2, engine.Engine_Error.Not_Found)
}

@(test)
test_format_error_with_source_path :: proc(t: ^testing.T) {
	err := exec.make_error(.Parse, "boom", span = sql.Span{line = 2, column = 4})
	defer exec.free_error(err)
	f := exec.format_error(err, "script.sql")
	defer delete(f)
	testing.expect_value(t, f, "script.sql:2:4: boom")

	no_span := exec.make_error(.Engine, "io fail")
	defer exec.free_error(no_span)
	f2 := exec.format_error(no_span, "db.strix")
	defer delete(f2)
	testing.expect_value(t, f2, "db.strix: io fail")
}

@(test)
test_fixture_bootstrap_v1_and_crud_against_strix :: proc(t: ^testing.T) {
	run_fixture :: proc(t: ^testing.T, fixture: string) {
		sql_path := strings.concatenate({"src/test/sql/fixtures/", fixture})
		defer delete(sql_path)
		data, read_err := os.read_entire_file_from_path(sql_path, context.allocator)
		testing.expectf(t, read_err == os.ERROR_NONE, "read %s: %v", sql_path, read_err)
		defer delete(data)

		path := fmt.tprintf("/tmp/strix-e6-fix-%s-%d.strix", fixture, os.get_pid())
		defer os.remove(path)

		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)
		s := exec.session_adopt(&e)

		r, eerr := exec.exec_script(&s, string(data), exec.Exec_Options{source_path = sql_path})
		testing.expectf(t, !exec.has_error(eerr), "%s: %s", fixture, exec.format_error(eerr, sql_path))
		exec.free_error(eerr)
		exec.free_result(r)

		// Durable reopen: assert row outcomes (not only table exists).
		// Both fixtures leave (1,'a',11) and (2,'b',20) after UPDATE + DELETE.
		e2, err2 := engine.engine_open(path)
		testing.expect(t, engine.ok(err2))
		defer engine.engine_close(&e2)
		s2 := exec.session_adopt(&e2)
		r2, e2err := exec.exec_statement(&s2, "SELECT id, name, qty FROM items ORDER BY id;")
		testing.expectf(t, !exec.has_error(e2err), "%s reopen: %s", fixture, e2err.message)
		testing.expect_value(t, len(r2.rows), 2)
		testing.expect_value(t, r2.rows[0][0], "1")
		testing.expect_value(t, r2.rows[0][1], "a")
		testing.expect_value(t, r2.rows[0][2], "11")
		testing.expect_value(t, r2.rows[1][0], "2")
		testing.expect_value(t, r2.rows[1][1], "b")
		testing.expect_value(t, r2.rows[1][2], "20")
		exec.free_error(e2err)
		exec.free_result(r2)
	}

	run_fixture(t, "bootstrap_v1.sql")
	run_fixture(t, "crud.sql")
}
