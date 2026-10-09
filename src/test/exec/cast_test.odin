package exec_tests

import "core:testing"
import engine "../../engine"
import exec "../../exec"

@(test)
test_cast_happy_paths_projection :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, i INT, f REAL, s TEXT, b BLOB);" +
		"INSERT INTO t (id, i, f, s, b) VALUES (1, 42, 3.5, '99', X'4142');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	// Integer → TEXT / REAL; REAL → INTEGER (truncate toward zero); TEXT → INTEGER
	r1, e1 := exec.exec_statement(
		&s,
		"SELECT CAST(i AS TEXT), CAST(i AS REAL), CAST(f AS INTEGER), CAST(s AS INT), CAST(f AS FLOAT) FROM t;",
	)
	testing.expectf(t, !exec.has_error(e1), "%s", e1.message)
	testing.expect_value(t, len(r1.rows), 1)
	testing.expect_value(t, r1.rows[0][0], "42")
	testing.expect_value(t, r1.rows[0][1], "42")
	testing.expect_value(t, r1.rows[0][2], "3")
	testing.expect_value(t, r1.rows[0][3], "99")
	testing.expect_value(t, r1.rows[0][4], "3.5")
	exec.free_error(e1)
	exec.free_result(r1)

	// TEXT ↔ BLOB; BLOB → TEXT; VARCHAR / DOUBLE aliases; UUID text round-trip (F3)
	r2, e2 := exec.exec_statement(
		&s,
		"SELECT CAST(s AS BLOB), CAST(b AS TEXT), CAST(i AS VARCHAR), CAST(i AS DOUBLE), " +
		"CAST(CAST('550e8400-e29b-41d4-a716-446655440000' AS UUID) AS TEXT) FROM t;",
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "X'3939'") // '99' as blob hex display
	testing.expect_value(t, r2.rows[0][1], "AB")
	testing.expect_value(t, r2.rows[0][2], "42")
	testing.expect_value(t, r2.rows[0][3], "42")
	testing.expect_value(t, r2.rows[0][4], "550e8400-e29b-41d4-a716-446655440000")
	exec.free_error(e2)
	exec.free_result(r2)

	// NULL → NULL
	r3, e3 := exec.exec_statement(&s, "SELECT CAST(NULL AS INTEGER) FROM t;")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, len(r3.rows), 1)
	testing.expect_value(t, r3.rows[0][0], "NULL")
	exec.free_error(e3)
	exec.free_result(r3)

	// Identity casts
	r4, e4 := exec.exec_statement(&s, "SELECT CAST(i AS INTEGER), CAST(s AS TEXT), CAST(b AS BLOB) FROM t;")
	testing.expectf(t, !exec.has_error(e4), "%s", e4.message)
	testing.expect_value(t, r4.rows[0][0], "42")
	testing.expect_value(t, r4.rows[0][1], "99")
	testing.expect_value(t, r4.rows[0][2], "X'4142'")
	exec.free_error(e4)
	exec.free_result(r4)
}

@(test)
test_cast_in_where_and_set :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT, n INT);" +
		"INSERT INTO t (id, label, n) VALUES (1, '10', 0), (2, '20', 0);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	// WHERE: CAST text → int then compare (S1 interaction — without CAST this errors)
	r1, e1 := exec.exec_statement(&s, "SELECT id FROM t WHERE CAST(label AS INTEGER) = 10;")
	testing.expectf(t, !exec.has_error(e1), "%s", e1.message)
	testing.expect_value(t, len(r1.rows), 1)
	testing.expect_value(t, r1.rows[0][0], "1")
	exec.free_error(e1)
	exec.free_result(r1)

	// SET via CAST
	r2, e2 := exec.exec_statement(&s, "UPDATE t SET n = CAST(label AS INT) WHERE id = 2;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, r2.rows_affected, 1)
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_statement(&s, "SELECT n FROM t WHERE id = 2;")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, r3.rows[0][0], "20")
	exec.free_error(e3)
	exec.free_result(r3)
}

@(test)
test_cast_reject_matrix :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, s TEXT, b BLOB, f REAL);" +
		"INSERT INTO t (id, s, b, f) VALUES (1, 'abc', X'FF', 1.5);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	// Garbage text → INTEGER
	r1, e1 := exec.exec_statement(&s, "SELECT CAST(s AS INTEGER) FROM t;")
	testing.expect(t, exec.has_error(e1))
	testing.expect_value(t, e1.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e1)
	exec.free_result(r1)

	// Partial / non-decimal text → INTEGER (literals need FROM in execute)
	r2, e2 := exec.exec_statement(&s, "SELECT CAST('10x' AS INT) FROM t;")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_statement(&s, "SELECT CAST('10.5' AS INTEGER) FROM t;")
	testing.expect(t, exec.has_error(e3))
	testing.expect_value(t, e3.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e3)
	exec.free_result(r3)

	r4, e4 := exec.exec_statement(&s, "SELECT CAST('0x10' AS INTEGER) FROM t;")
	testing.expect(t, exec.has_error(e4))
	testing.expect_value(t, e4.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e4)
	exec.free_result(r4)

	// Blob → numeric
	r5, e5 := exec.exec_statement(&s, "SELECT CAST(b AS INTEGER) FROM t;")
	testing.expect(t, exec.has_error(e5))
	testing.expect_value(t, e5.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e5)
	exec.free_result(r5)

	r6, e6 := exec.exec_statement(&s, "SELECT CAST(b AS REAL) FROM t;")
	testing.expect(t, exec.has_error(e6))
	testing.expect_value(t, e6.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e6)
	exec.free_result(r6)

	// Numeric → BLOB
	r7, e7 := exec.exec_statement(&s, "SELECT CAST(1 AS BLOB) FROM t;")
	testing.expect(t, exec.has_error(e7))
	testing.expect_value(t, e7.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e7)
	exec.free_result(r7)

	r8, e8 := exec.exec_statement(&s, "SELECT CAST(f AS BLOB) FROM t;")
	testing.expect(t, exec.has_error(e8))
	testing.expect_value(t, e8.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e8)
	exec.free_result(r8)

	// Unknown target type (BOOLEAN is executed as of F3 — use a nonsense name)
	r9, e9 := exec.exec_statement(&s, "SELECT CAST(1 AS NOTATYPE) FROM t;")
	testing.expect(t, exec.has_error(e9))
	testing.expect_value(t, e9.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e9)
	exec.free_result(r9)

	// Invalid text → UUID
	r9b, e9b := exec.exec_statement(&s, "SELECT CAST(s AS UUID) FROM t;")
	testing.expect(t, exec.has_error(e9b))
	testing.expect_value(t, e9b.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e9b)
	exec.free_result(r9b)

	// Invalid REAL text
	r10, e10 := exec.exec_statement(&s, "SELECT CAST('nope' AS REAL) FROM t;")
	testing.expect(t, exec.has_error(e10))
	testing.expect_value(t, e10.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e10)
	exec.free_result(r10)

	// Empty / whitespace-only → INTEGER
	r11, e11 := exec.exec_statement(&s, "SELECT CAST('' AS INTEGER) FROM t;")
	testing.expect(t, exec.has_error(e11))
	testing.expect_value(t, e11.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e11)
	exec.free_result(r11)

	r12, e12 := exec.exec_statement(&s, "SELECT CAST('   ' AS INT) FROM t;")
	testing.expect(t, exec.has_error(e12))
	testing.expect_value(t, e12.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e12)
	exec.free_result(r12)
}

@(test)
test_cast_text_integer_overflow_rejects :: proc(t: ^testing.T) {
	// Text→INTEGER must reject (not wrap) when digits do not fit i64 —
	// same honesty as Float→INTEGER out-of-range.
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY);" +
		"INSERT INTO t (id) VALUES (1);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	// i64 max = 9223372036854775807; max+1 must reject
	r1, e1 := exec.exec_statement(&s, "SELECT CAST('9223372036854775808' AS INTEGER) FROM t;")
	testing.expect(t, exec.has_error(e1))
	testing.expect_value(t, e1.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e1)
	exec.free_result(r1)

	// i64 min = -9223372036854775808; min-1 must reject
	r2, e2 := exec.exec_statement(&s, "SELECT CAST('-9223372036854775809' AS INTEGER) FROM t;")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e2)
	exec.free_result(r2)

	// Oversized digit string (wraps under naive strconv) must reject
	r3, e3 := exec.exec_statement(&s, "SELECT CAST('99999999999999999999' AS INT) FROM t;")
	testing.expect(t, exec.has_error(e3))
	testing.expect_value(t, e3.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e3)
	exec.free_result(r3)

	// Boundaries that do fit still succeed
	r4, e4 := exec.exec_statement(
		&s,
		"SELECT CAST('9223372036854775807' AS INTEGER), CAST('-9223372036854775808' AS INTEGER) FROM t;",
	)
	testing.expectf(t, !exec.has_error(e4), "%s", e4.message)
	testing.expect_value(t, r4.rows[0][0], "9223372036854775807")
	testing.expect_value(t, r4.rows[0][1], "-9223372036854775808")
	exec.free_error(e4)
	exec.free_result(r4)
}

@(test)
test_cast_text_integer_whitespace_and_sign :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY);" +
		"INSERT INTO t (id) VALUES (1);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r1, e1 := exec.exec_statement(
		&s,
		"SELECT CAST('  -42  ' AS INTEGER), CAST('+7' AS INT) FROM t;",
	)
	testing.expectf(t, !exec.has_error(e1), "%s", e1.message)
	testing.expect_value(t, r1.rows[0][0], "-42")
	testing.expect_value(t, r1.rows[0][1], "7")
	exec.free_error(e1)
	exec.free_result(r1)

	// Text → REAL with whitespace
	r2, e2 := exec.exec_statement(&s, "SELECT CAST(' 3.25 ' AS REAL) FROM t;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, r2.rows[0][0], "3.25")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_cast_s1_compare_still_rejects_without_cast :: proc(t: ^testing.T) {
	// Regression: S1 Text↔numeric without CAST remains an error.
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, s TEXT);" +
		"INSERT INTO t (id, s) VALUES (1, '10');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r1, e1 := exec.exec_statement(&s, "SELECT id FROM t WHERE s = 10;")
	testing.expect(t, exec.has_error(e1))
	testing.expect_value(t, e1.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e1)
	exec.free_result(r1)

	r2, e2 := exec.exec_statement(&s, "SELECT id FROM t WHERE CAST(s AS INTEGER) = 10;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	exec.free_error(e2)
	exec.free_result(r2)
}
