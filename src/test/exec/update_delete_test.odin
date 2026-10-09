package exec_tests

import "core:fmt"
import "core:os"
import "core:testing"
import engine "../../engine"
import exec "../../exec"

seed_items :: proc(t: ^testing.T, s: ^exec.Exec_Session) {
	r0, e0 := exec.exec_script(
		s,
		"CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, qty INT);" +
		"INSERT INTO items (id, name, qty) VALUES " +
		"(1, 'apple', 10), (2, 'banana', 20), (3, 'cherry', 30);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)
}

@(test)
test_update_where_then_select :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_items(t, &s)

	r, eerr := exec.exec_statement(&s, "UPDATE items SET qty = qty + 5 WHERE name = 'banana';")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.kind, exec.Result_Kind.Rows_Affected)
	testing.expect_value(t, r.rows_affected, 1)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT qty FROM items WHERE id = 2;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "25")
	exec.free_error(e2)
	exec.free_result(r2)

	// Unmatched WHERE → 0 rows
	r3, e3 := exec.exec_statement(&s, "UPDATE items SET qty = 0 WHERE name = 'missing';")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, r3.rows_affected, 0)
	exec.free_error(e3)
	exec.free_result(r3)
}

@(test)
test_update_all_rows_and_expr_set :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_items(t, &s)

	r, eerr := exec.exec_statement(&s, "UPDATE items SET name = name || '!', qty = qty * 2;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.rows_affected, 3)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT name, qty FROM items ORDER BY id;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 3)
	testing.expect_value(t, r2.rows[0][0], "apple!")
	testing.expect_value(t, r2.rows[0][1], "20")
	testing.expect_value(t, r2.rows[2][0], "cherry!")
	testing.expect_value(t, r2.rows[2][1], "60")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_delete_where_then_select :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_items(t, &s)

	r, eerr := exec.exec_statement(&s, "DELETE FROM items WHERE qty >= 20;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.kind, exec.Result_Kind.Rows_Affected)
	testing.expect_value(t, r.rows_affected, 2)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT id, name FROM items;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "1")
	testing.expect_value(t, r2.rows[0][1], "apple")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_delete_all_rows :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_items(t, &s)

	r, eerr := exec.exec_statement(&s, "DELETE FROM items;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.rows_affected, 3)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT * FROM items;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 0)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_update_delete_reopen_durable :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-e4-crud-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		s := exec.session_adopt(&e)
		r0, e0 := exec.exec_script(
			&s,
			"CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);" +
			"INSERT INTO t (id, v) VALUES (1, 'a'), (2, 'b'), (3, 'c');" +
			"UPDATE t SET v = 'B' WHERE id = 2;" +
			"DELETE FROM t WHERE id = 3;",
		)
		testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
		testing.expect_value(t, r0.rows_affected, 1) // last stmt = DELETE
		exec.free_error(e0)
		exec.free_result(r0)
		engine.engine_close(&e)
	}

	{
		session, err := exec.session_open(path)
		testing.expectf(t, !exec.has_error(err), "%s", err.message)
		defer exec.free_error(err)
		defer exec.session_close(&session)

		r, eerr := exec.exec_statement(&session, "SELECT id, v FROM t ORDER BY id;")
		testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
		testing.expect_value(t, len(r.rows), 2)
		testing.expect_value(t, r.rows[0][1], "a")
		testing.expect_value(t, r.rows[1][1], "B")
		exec.free_error(eerr)
		exec.free_result(r)
	}
}

@(test)
test_update_delete_unknown_table_column :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_items(t, &s)

	r, eerr := exec.exec_statement(&s, "UPDATE missing SET a = 1;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unknown_Table)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "DELETE FROM missing;")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Unknown_Table)
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_statement(&s, "UPDATE items SET nope = 1;")
	testing.expect(t, exec.has_error(e3))
	testing.expect_value(t, e3.code, exec.Exec_Error_Code.Unknown_Column)
	exec.free_error(e3)
	exec.free_result(r3)

	r4, e4 := exec.exec_statement(&s, "DELETE FROM items WHERE nope = 1;")
	testing.expect(t, exec.has_error(e4))
	testing.expect_value(t, e4.code, exec.Exec_Error_Code.Unknown_Column)
	exec.free_error(e4)
	exec.free_result(r4)
}

@(test)
test_update_rejects_ipk_and_not_null :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_items(t, &s)

	r, eerr := exec.exec_statement(&s, "UPDATE items SET id = 99 WHERE id = 1;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "UPDATE items SET name = NULL WHERE id = 1;")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(e2)
	exec.free_result(r2)

	// Row unchanged after failed NOT NULL update
	r3, e3 := exec.exec_statement(&s, "SELECT name FROM items WHERE id = 1;")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, r3.rows[0][0], "apple")
	exec.free_error(e3)
	exec.free_result(r3)
}

@(test)
test_update_delete_reject_when_indexes_lack_columns :: proc(t: ^testing.T) {
	// Legacy v1 index rows (no column list) cannot be maintained — forbid mutate.
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_items(t, &s)

	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	_, ierr := engine.catalog_register_index(&e, "items_by_name", "items")
	testing.expect(t, engine.ok(ierr))
	testing.expect(t, engine.ok(engine.txn_commit(&e)))

	r, eerr := exec.exec_statement(&s, "UPDATE items SET qty = 1;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Has_Indexes)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "DELETE FROM items;")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Has_Indexes)
	exec.free_error(e2)
	exec.free_result(r2)

	// Data intact
	r3, e3 := exec.exec_statement(&s, "SELECT * FROM items;")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, len(r3.rows), 3)
	exec.free_error(e3)
	exec.free_result(r3)
}

@(test)
test_update_delete_closed_session :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	exec.session_close(&s)

	r, eerr := exec.exec_statement(&s, "UPDATE t SET a = 1;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Closed)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "DELETE FROM t;")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Closed)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_update_unsupported_set_expr :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_items(t, &s)

	// CAST is executed (S2); function calls in SET remain unsupported.
	r, eerr := exec.exec_statement(&s, "UPDATE items SET qty = abs(qty);")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(eerr)
	exec.free_result(r)
}
