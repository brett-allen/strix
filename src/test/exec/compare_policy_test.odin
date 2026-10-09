package exec_tests

import "core:testing"
import engine "../../engine"
import exec "../../exec"

@(test)
test_compare_policy_matrix :: proc(t: ^testing.T) {
	// S1 comparison policy: Integer–Integer exact; mixed int/float via f64;
	// same-kind Text/Blob ok; Text/Blob ↔ numeric without CAST → Unsupported_Ast.
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, i INTEGER, f REAL, s TEXT, b BLOB);" +
		"INSERT INTO t (id, i, f, s, b) VALUES " +
		"(1, 10, 10.0, 'aa', X'AA'), " +
		"(2, 20, 20.5, 'bb', X'BB');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	// Integer–Integer
	r1, e1 := exec.exec_statement(&s, "SELECT id FROM t WHERE i = 10;")
	testing.expectf(t, !exec.has_error(e1), "%s", e1.message)
	testing.expect_value(t, len(r1.rows), 1)
	testing.expect_value(t, r1.rows[0][0], "1")
	exec.free_error(e1)
	exec.free_result(r1)

	// Mixed int/float via f64 (north star default)
	r2, e2 := exec.exec_statement(&s, "SELECT id FROM t WHERE i = 10.0;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "1")
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_statement(&s, "SELECT id FROM t WHERE f > 10;")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, len(r3.rows), 1)
	testing.expect_value(t, r3.rows[0][0], "2")
	exec.free_error(e3)
	exec.free_result(r3)

	// Same-kind Text
	r4, e4 := exec.exec_statement(&s, "SELECT id FROM t WHERE s = 'aa';")
	testing.expectf(t, !exec.has_error(e4), "%s", e4.message)
	testing.expect_value(t, len(r4.rows), 1)
	exec.free_error(e4)
	exec.free_result(r4)

	// Same-kind Blob
	r5, e5 := exec.exec_statement(&s, "SELECT id FROM t WHERE b = X'AA';")
	testing.expectf(t, !exec.has_error(e5), "%s", e5.message)
	testing.expect_value(t, len(r5.rows), 1)
	exec.free_error(e5)
	exec.free_result(r5)

	// Text ↔ numeric without CAST → error
	r6, e6 := exec.exec_statement(&s, "SELECT id FROM t WHERE s = 10;")
	testing.expect(t, exec.has_error(e6))
	testing.expect_value(t, e6.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e6)
	exec.free_result(r6)

	r7, e7 := exec.exec_statement(&s, "SELECT id FROM t WHERE i = '10';")
	testing.expect(t, exec.has_error(e7))
	testing.expect_value(t, e7.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e7)
	exec.free_result(r7)

	// Blob ↔ numeric without CAST → error
	r8, e8 := exec.exec_statement(&s, "SELECT id FROM t WHERE b = 1;")
	testing.expect(t, exec.has_error(e8))
	testing.expect_value(t, e8.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e8)
	exec.free_result(r8)

	// Text ↔ Blob → error (kind mismatch)
	r9, e9 := exec.exec_statement(&s, "SELECT id FROM t WHERE s = X'AA';")
	testing.expect(t, exec.has_error(e9))
	testing.expect_value(t, e9.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e9)
	exec.free_result(r9)
}

@(test)
test_boolean_context_blob_and_and :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, data BLOB, flag INT);" +
		"INSERT INTO t (id, data, flag) VALUES (1, X'AB', 1), (2, NULL, 0);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r1, e1 := exec.exec_statement(&s, "SELECT id FROM t WHERE data;")
	testing.expect(t, exec.has_error(e1))
	testing.expect_value(t, e1.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e1)
	exec.free_result(r1)

	r2, e2 := exec.exec_statement(&s, "SELECT id FROM t WHERE flag AND data;")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e2)
	exec.free_result(r2)

	// Short-circuit: false left of AND does not evaluate Text/Blob right.
	r3, e3 := exec.exec_statement(&s, "SELECT id FROM t WHERE 0 AND data;")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, len(r3.rows), 0)
	exec.free_error(e3)
	exec.free_result(r3)

	// NULL in boolean context remains unknown (WHERE drops; no error).
	r4, e4 := exec.exec_statement(&s, "SELECT id FROM t WHERE NULL;")
	testing.expectf(t, !exec.has_error(e4), "%s", e4.message)
	testing.expect_value(t, len(r4.rows), 0)
	exec.free_error(e4)
	exec.free_result(r4)

	// Integer flag column as predicate still works.
	r5, e5 := exec.exec_statement(&s, "SELECT id FROM t WHERE flag;")
	testing.expectf(t, !exec.has_error(e5), "%s", e5.message)
	testing.expect_value(t, len(r5.rows), 1)
	testing.expect_value(t, r5.rows[0][0], "1")
	exec.free_error(e5)
	exec.free_result(r5)
}

@(test)
test_ipk_crud_still_works_after_s1 :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT);" +
		"INSERT INTO items (label) VALUES ('x'), ('y');" +
		"UPDATE items SET label = 'z' WHERE id = 1;" +
		"DELETE FROM items WHERE id = 2;",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(&s, "SELECT id, label FROM items ORDER BY id;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "1")
	testing.expect_value(t, r.rows[0][1], "z")
	exec.free_error(eerr)
	exec.free_result(r)
}
