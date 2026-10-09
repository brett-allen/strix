package exec_tests

import "core:testing"
import engine "../../engine"
import exec "../../exec"

seed_sales :: proc(t: ^testing.T, s: ^exec.Exec_Session) {
	r0, e0 := exec.exec_script(
		s,
		"CREATE TABLE sales (id INTEGER PRIMARY KEY, region TEXT, amt INT, qty INT);" +
		"INSERT INTO sales (id, region, amt, qty) VALUES " +
		"(1, 'east', 10, 1), (2, 'west', 20, 2), (3, 'east', 30, 3), " +
		"(4, 'west', 40, 4), (5, NULL, 5, 1), (6, NULL, 15, 1);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)
}

@(test)
test_group_by_count_sum :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_sales(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT region, COUNT(*) AS n, SUM(amt) FROM sales GROUP BY region ORDER BY region;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.kind, exec.Result_Kind.Result_Set)
	testing.expect_value(t, len(r.rows), 3)
	// NULL sorts first (compare_values: NULL < non-NULL)
	testing.expect_value(t, r.rows[0][0], "NULL")
	testing.expect_value(t, r.rows[0][1], "2")
	testing.expect_value(t, r.rows[0][2], "20")
	testing.expect_value(t, r.rows[1][0], "east")
	testing.expect_value(t, r.rows[1][1], "2")
	testing.expect_value(t, r.rows[1][2], "40")
	testing.expect_value(t, r.rows[2][0], "west")
	testing.expect_value(t, r.rows[2][1], "2")
	testing.expect_value(t, r.rows[2][2], "60")
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_group_by_having :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_sales(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT region, COUNT(*) AS n FROM sales GROUP BY region HAVING COUNT(*) >= 2 AND region IS NOT NULL ORDER BY region;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 2)
	testing.expect_value(t, r.rows[0][0], "east")
	testing.expect_value(t, r.rows[0][1], "2")
	testing.expect_value(t, r.rows[1][0], "west")
	testing.expect_value(t, r.rows[1][1], "2")
	exec.free_error(eerr)
	exec.free_result(r)

	// HAVING on aggregate only
	r2, e2 := exec.exec_statement(
		&s,
		"SELECT region, SUM(amt) AS total FROM sales WHERE region IS NOT NULL GROUP BY region HAVING SUM(amt) > 50;",
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "west")
	testing.expect_value(t, r2.rows[0][1], "60")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_group_by_where_pre_filter :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_sales(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT region, COUNT(*) FROM sales WHERE amt >= 20 GROUP BY region ORDER BY region;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 2)
	testing.expect_value(t, r.rows[0][0], "east")
	testing.expect_value(t, r.rows[0][1], "1")
	testing.expect_value(t, r.rows[1][0], "west")
	testing.expect_value(t, r.rows[1][1], "2")
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_group_by_empty_zero_rows :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r, eerr := exec.exec_script(
		&s,
		"CREATE TABLE empty_g (id INTEGER PRIMARY KEY, g TEXT, n INT);" +
		"SELECT g, COUNT(*) FROM empty_g GROUP BY g;" +
		"SELECT COUNT(*) FROM empty_g;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	// Script returns last statement result: whole-query COUNT → one row "0"
	testing.expect_value(t, r.kind, exec.Result_Kind.Result_Set)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "0")
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT g, COUNT(*) FROM empty_g GROUP BY g;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 0)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_group_by_no_agg_keys_only :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_sales(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT region FROM sales WHERE region IS NOT NULL GROUP BY region ORDER BY region;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 2)
	testing.expect_value(t, r.rows[0][0], "east")
	testing.expect_value(t, r.rows[1][0], "west")
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_group_by_order_by_agg :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_sales(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT region, SUM(amt) AS total FROM sales WHERE region IS NOT NULL GROUP BY region ORDER BY SUM(amt) DESC;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 2)
	testing.expect_value(t, r.rows[0][0], "west")
	testing.expect_value(t, r.rows[0][1], "60")
	testing.expect_value(t, r.rows[1][0], "east")
	testing.expect_value(t, r.rows[1][1], "40")
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_group_by_avg_min_max :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_sales(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT region, AVG(amt), MIN(amt), MAX(qty) FROM sales WHERE region = 'east' GROUP BY region;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "east")
	testing.expect_value(t, r.rows[0][1], "20") // (10+30)/2
	testing.expect_value(t, r.rows[0][2], "10")
	testing.expect_value(t, r.rows[0][3], "3")
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_group_by_strict_select_reject :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_sales(t, &s)

	// Bare non-group column (SQLite would pick-any; we reject)
	r, eerr := exec.exec_statement(&s, "SELECT region, amt, COUNT(*) FROM sales GROUP BY region;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT * FROM sales GROUP BY region;")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_group_by_reject_expr_and_having_bare :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_sales(t, &s)

	r, eerr := exec.exec_statement(&s, "SELECT amt + 1, COUNT(*) FROM sales GROUP BY amt + 1;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(
		&s,
		"SELECT region, COUNT(*) FROM sales GROUP BY region HAVING amt > 10;",
	)
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_group_by_limit_offset :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_sales(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT region, COUNT(*) FROM sales WHERE region IS NOT NULL GROUP BY region ORDER BY region LIMIT 1;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "east")
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(
		&s,
		"SELECT region, COUNT(*) FROM sales WHERE region IS NOT NULL GROUP BY region ORDER BY region LIMIT 1 OFFSET 1;",
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "west")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_group_by_multi_keys :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE items (id INTEGER PRIMARY KEY, a TEXT, b TEXT, n INT);" +
		"INSERT INTO items (id, a, b, n) VALUES " +
		"(1, 'x', 'p', 1), (2, 'x', 'p', 2), (3, 'x', 'q', 3), (4, 'y', 'p', 4);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT a, b, COUNT(*), SUM(n) FROM items GROUP BY a, b ORDER BY a, b;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 3)
	testing.expect_value(t, r.rows[0][0], "x")
	testing.expect_value(t, r.rows[0][1], "p")
	testing.expect_value(t, r.rows[0][2], "2")
	testing.expect_value(t, r.rows[0][3], "3")
	testing.expect_value(t, r.rows[1][0], "x")
	testing.expect_value(t, r.rows[1][1], "q")
	testing.expect_value(t, r.rows[1][2], "1")
	testing.expect_value(t, r.rows[2][0], "y")
	testing.expect_value(t, r.rows[2][1], "p")
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_whole_query_agg_still_works :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_sales(t, &s)

	r, eerr := exec.exec_statement(&s, "SELECT COUNT(*), SUM(amt) FROM sales;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "6")
	testing.expect_value(t, r.rows[0][1], "120")
	exec.free_error(eerr)
	exec.free_result(r)

	// Mix without GROUP BY still rejected
	r2, e2 := exec.exec_statement(&s, "SELECT region, COUNT(*) FROM sales;")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e2)
	exec.free_result(r2)
}
