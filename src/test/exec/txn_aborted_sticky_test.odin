package exec_tests

import "core:strings"
import "core:testing"
import engine "../../engine"
import exec "../../exec"

@(test)
test_txn_aborted_cleared_for_later_independent_script :: proc(t: ^testing.T) {
	// After BEGIN + write failure aborts the txn, a later independent exec_script
	// must not rewrite unrelated errors as "transaction aborted".
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT NOT NULL);" +
		"BEGIN;" +
		"INSERT INTO t (id, n) VALUES (1, NULL);",
	)
	testing.expect(t, exec.has_error(e0))
	testing.expect(t, strings.contains(e0.message, "transaction aborted"))
	testing.expect(t, s.txn_aborted)
	testing.expect(t, !s.explicit_txn)
	exec.free_error(e0)
	exec.free_result(r0)

	// Later script: unknown table — must be a plain error, not abort annotation.
	r1, e1 := exec.exec_script(&s, "SELECT * FROM missing;")
	testing.expect(t, exec.has_error(e1))
	testing.expect_value(t, e1.code, exec.Exec_Error_Code.Unknown_Table)
	testing.expect(t, !strings.contains(e1.message, "transaction aborted"))
	testing.expect(t, !s.txn_aborted)
	exec.free_error(e1)
	exec.free_result(r1)

	// And a successful independent script still works.
	r2, e2 := exec.exec_script(&s, "CREATE TABLE ok (x INT); INSERT INTO ok VALUES (1);")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	exec.free_error(e2)
	exec.free_result(r2)
}
