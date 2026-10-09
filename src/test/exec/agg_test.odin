package exec_tests

import "core:testing"
import engine "../../engine"
import exec "../../exec"

seed_scores :: proc(t: ^testing.T, s: ^exec.Exec_Session) {
	r0, e0 := exec.exec_script(
		s,
		"CREATE TABLE scores (id INTEGER PRIMARY KEY, name TEXT, pts INT, bonus REAL);" +
		"INSERT INTO scores (id, name, pts, bonus) VALUES " +
		"(1, 'alice', 10, 1.5), (2, 'bob', 30, 2.0), (3, 'cara', NULL, 0.5), (4, NULL, 20, NULL);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)
}

@(test)
test_count_star_basic_and_empty :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_scores(t, &s)

	r, eerr := exec.exec_statement(&s, "SELECT COUNT(*) FROM scores;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.kind, exec.Result_Kind.Result_Set)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "4")
	testing.expect_value(t, r.column_names[0], "COUNT(*)")
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT COUNT(*) AS n FROM scores WHERE pts >= 20;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "2")
	testing.expect_value(t, r2.column_names[0], "n")
	exec.free_error(e2)
	exec.free_result(r2)

	// Empty table → one row with 0
	r3, e3 := exec.exec_script(
		&s,
		"CREATE TABLE empty_t (id INTEGER PRIMARY KEY);" +
		"SELECT COUNT(*) FROM empty_t;",
	)
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, r3.kind, exec.Result_Kind.Result_Set)
	testing.expect_value(t, len(r3.rows), 1)
	testing.expect_value(t, r3.rows[0][0], "0")
	exec.free_error(e3)
	exec.free_result(r3)
}

@(test)
test_count_expr_null_skipping :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_scores(t, &s)

	r, eerr := exec.exec_statement(&s, "SELECT COUNT(pts), COUNT(name), COUNT(bonus) FROM scores;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "3") // pts NULL skipped
	testing.expect_value(t, r.rows[0][1], "3") // name NULL skipped
	testing.expect_value(t, r.rows[0][2], "3") // bonus NULL skipped
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_sum_avg_min_max_numerics :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_scores(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT SUM(pts), AVG(pts), MIN(pts), MAX(pts) FROM scores;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "60") // 10+30+20
	testing.expect_value(t, r.rows[0][1], "20") // AVG promotes to float; 60/3=20
	testing.expect_value(t, r.rows[0][2], "10")
	testing.expect_value(t, r.rows[0][3], "30")
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT SUM(bonus), AVG(bonus), MIN(bonus), MAX(bonus) FROM scores;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "4") // 1.5+2.0+0.5
	testing.expect_value(t, r2.rows[0][1], "1.3333333333333333") // or %g of 4/3
	// %g may print 1.33333 — accept either via float parse tolerance by checking prefix
	testing.expect(t, len(r2.rows[0][1]) > 0 && r2.rows[0][1][0] == '1')
	testing.expect_value(t, r2.rows[0][2], "0.5")
	testing.expect_value(t, r2.rows[0][3], "2")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_agg_empty_sum_avg_min_max_null :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r, eerr := exec.exec_script(
		&s,
		"CREATE TABLE empty_n (id INTEGER PRIMARY KEY, n INT);" +
		"SELECT COUNT(*), SUM(n), AVG(n), MIN(n), MAX(n) FROM empty_n;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "0")
	testing.expect_value(t, r.rows[0][1], "NULL")
	testing.expect_value(t, r.rows[0][2], "NULL")
	testing.expect_value(t, r.rows[0][3], "NULL")
	testing.expect_value(t, r.rows[0][4], "NULL")
	exec.free_error(eerr)
	exec.free_result(r)

	// All-NULL column: COUNT(expr)=0; SUM/AVG/MIN/MAX → NULL
	r2, e2 := exec.exec_script(
		&s,
		"CREATE TABLE allnull (id INTEGER PRIMARY KEY, n INT);" +
		"INSERT INTO allnull (id, n) VALUES (1, NULL), (2, NULL);" +
		"SELECT COUNT(n), SUM(n), AVG(n), MIN(n), MAX(n) FROM allnull;",
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "0")
	testing.expect_value(t, r2.rows[0][1], "NULL")
	testing.expect_value(t, r2.rows[0][2], "NULL")
	testing.expect_value(t, r2.rows[0][3], "NULL")
	testing.expect_value(t, r2.rows[0][4], "NULL")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_agg_with_constant_and_arith :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_scores(t, &s)

	r, eerr := exec.exec_statement(&s, "SELECT COUNT(*), 1, COUNT(*) + 1 FROM scores;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "4")
	testing.expect_value(t, r.rows[0][1], "1")
	testing.expect_value(t, r.rows[0][2], "5")
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_agg_reject_mixed_columns :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_scores(t, &s)

	r, eerr := exec.exec_statement(&s, "SELECT name, COUNT(*) FROM scores;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT *, COUNT(*) FROM scores;")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_agg_reject_unsupported_forms :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_scores(t, &s)

	// Non-aggregate function still rejected
	r, eerr := exec.exec_statement(&s, "SELECT abs(pts) FROM scores;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(eerr)
	exec.free_result(r)

	// SUM(*) rejected
	r2, e2 := exec.exec_statement(&s, "SELECT SUM(*) FROM scores;")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e2)
	exec.free_result(r2)

	// Nested aggregates
	r3, e3 := exec.exec_statement(&s, "SELECT SUM(COUNT(*)) FROM scores;")
	testing.expect(t, exec.has_error(e3))
	testing.expect_value(t, e3.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e3)
	exec.free_result(r3)

	// COUNT() no args
	r4, e4 := exec.exec_statement(&s, "SELECT COUNT() FROM scores;")
	testing.expect(t, exec.has_error(e4))
	testing.expect_value(t, e4.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e4)
	exec.free_result(r4)

	// SUM on text
	r5, e5 := exec.exec_statement(&s, "SELECT SUM(name) FROM scores;")
	testing.expect(t, exec.has_error(e5))
	testing.expect_value(t, e5.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e5)
	exec.free_result(r5)

	// MIN/MAX on text
	r6, e6 := exec.exec_statement(&s, "SELECT MIN(name) FROM scores;")
	testing.expect(t, exec.has_error(e6))
	testing.expect_value(t, e6.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e6)
	exec.free_result(r6)

	// GROUP BY still rejected (S5)
	r7, e7 := exec.exec_statement(&s, "SELECT name, COUNT(*) FROM scores GROUP BY name;")
	testing.expect(t, exec.has_error(e7))
	testing.expect_value(t, e7.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e7)
	exec.free_result(r7)
}

@(test)
test_agg_limit_offset_one_row :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_scores(t, &s)

	r, eerr := exec.exec_statement(&s, "SELECT COUNT(*) FROM scores LIMIT 0;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 0)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT COUNT(*) FROM scores LIMIT 10 OFFSET 1;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 0)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_agg_unknown_column_in_arg :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_scores(t, &s)

	r, eerr := exec.exec_statement(&s, "SELECT SUM(nope) FROM scores;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unknown_Column)
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_agg_reject_where_and_order :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_scores(t, &s)

	r, eerr := exec.exec_statement(&s, "SELECT COUNT(*) FROM scores WHERE COUNT(*) > 0;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT COUNT(*) FROM scores ORDER BY name;")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_agg_cast_count :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_scores(t, &s)

	r, eerr := exec.exec_statement(&s, "SELECT CAST(COUNT(*) AS TEXT) FROM scores;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "4")
	exec.free_error(eerr)
	exec.free_result(r)
}
