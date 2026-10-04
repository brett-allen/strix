package exec_tests

import "core:testing"
import engine "../../engine"
import exec "../../exec"

@(test)
test_integer_compare_exact_beyond_f64_mantissa :: proc(t: ^testing.T) {
	// 2^53 = 9007199254740992 is the last consecutive integer exactly representable
	// in f64. Comparing via f64 would make N and N+1 look equal.
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE nums (id INTEGER PRIMARY KEY, v INTEGER);" +
		"INSERT INTO nums (id, v) VALUES " +
		"(1, 9007199254740992), (2, 9007199254740993), (3, 9007199254740991);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT id FROM nums WHERE v = 9007199254740993;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "2")
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(
		&s,
		"SELECT id FROM nums WHERE v > 9007199254740992 ORDER BY v ASC;",
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "2")
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_statement(&s, "SELECT id FROM nums ORDER BY v ASC;")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, len(r3.rows), 3)
	testing.expect_value(t, r3.rows[0][0], "3") // N-1
	testing.expect_value(t, r3.rows[1][0], "1") // N
	testing.expect_value(t, r3.rows[2][0], "2") // N+1
	exec.free_error(e3)
	exec.free_result(r3)
}
