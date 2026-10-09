package exec_tests

import "core:strings"
import "core:testing"
import engine "../../engine"
import exec "../../exec"

seed_join_tables :: proc(t: ^testing.T, s: ^exec.Exec_Session) {
	r0, e0 := exec.exec_script(
		s,
		"CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT);" +
		"CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INT, qty INT);" +
		"INSERT INTO customers (id, name) VALUES (1, 'alice'), (2, 'bob'), (3, 'cara');" +
		"INSERT INTO orders (id, customer_id, qty) VALUES " +
		"(10, 1, 2), (11, 1, 5), (12, 2, 1), (13, 9, 3);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)
}

@(test)
test_inner_join_equi_filter :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_join_tables(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT customers.name, orders.qty FROM customers " +
		"INNER JOIN orders ON customers.id = orders.customer_id " +
		"ORDER BY customers.name, orders.qty;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.kind, exec.Result_Kind.Result_Set)
	testing.expect_value(t, len(r.rows), 3)
	testing.expect_value(t, r.rows[0][0], "alice")
	testing.expect_value(t, r.rows[0][1], "2")
	testing.expect_value(t, r.rows[1][0], "alice")
	testing.expect_value(t, r.rows[1][1], "5")
	testing.expect_value(t, r.rows[2][0], "bob")
	testing.expect_value(t, r.rows[2][1], "1")
	exec.free_error(eerr)
	exec.free_result(r)

	// JOIN without INNER keyword + WHERE
	r2, e2 := exec.exec_statement(
		&s,
		"SELECT c.name, o.qty FROM customers AS c " +
		"JOIN orders AS o ON c.id = o.customer_id " +
		"WHERE o.qty >= 5 ORDER BY c.name;",
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "alice")
	testing.expect_value(t, r2.rows[0][1], "5")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_join_qualified_and_table_star :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_join_tables(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT c.name, o.id FROM customers AS c " +
		"JOIN orders AS o ON c.id = o.customer_id " +
		"WHERE c.name = 'bob';",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "bob")
	testing.expect_value(t, r.rows[0][1], "12")
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(
		&s,
		"SELECT o.* FROM customers AS c JOIN orders AS o ON c.id = o.customer_id WHERE c.id = 2;",
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.column_names), 3)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "12")
	testing.expect_value(t, r2.rows[0][1], "2")
	testing.expect_value(t, r2.rows[0][2], "1")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_join_unknown_column :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_join_tables(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT nope FROM customers JOIN orders ON customers.id = orders.customer_id;",
	)
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unknown_Column)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(
		&s,
		"SELECT customers.name FROM customers JOIN orders ON customers.id = orders.missing;",
	)
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Unknown_Column)
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_statement(
		&s,
		"SELECT x.name FROM customers AS c JOIN orders AS o ON c.id = o.customer_id;",
	)
	testing.expect(t, exec.has_error(e3))
	testing.expect_value(t, e3.code, exec.Exec_Error_Code.Unknown_Column)
	exec.free_error(e3)
	exec.free_result(r3)
}

@(test)
test_join_ambiguous_column :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_join_tables(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT id FROM customers JOIN orders ON customers.id = orders.customer_id;",
	)
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unknown_Column)
	testing.expect(t, strings.contains(eerr.message, "ambiguous"))
	exec.free_error(eerr)
	exec.free_result(r)

	// Qualified clears ambiguity
	r2, e2 := exec.exec_statement(
		&s,
		"SELECT customers.id, orders.id FROM customers " +
		"JOIN orders ON customers.id = orders.customer_id " +
		"WHERE customers.id = 2;",
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "2")
	testing.expect_value(t, r2.rows[0][1], "12")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_cross_join_and_comma :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE a (x INT); CREATE TABLE b (y INT);" +
		"INSERT INTO a (x) VALUES (1), (2);" +
		"INSERT INTO b (y) VALUES (10), (20);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(&s, "SELECT a.x, b.y FROM a CROSS JOIN b ORDER BY a.x, b.y;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 4)
	testing.expect_value(t, r.rows[0][0], "1")
	testing.expect_value(t, r.rows[0][1], "10")
	testing.expect_value(t, r.rows[3][0], "2")
	testing.expect_value(t, r.rows[3][1], "20")
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT a.x, b.y FROM a, b WHERE a.x = 1 AND b.y = 20;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "1")
	testing.expect_value(t, r2.rows[0][1], "20")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_join_rejects_left_using_multi :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_join_tables(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT * FROM customers LEFT JOIN orders ON customers.id = orders.customer_id;",
	)
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(
		&s,
		"SELECT * FROM customers JOIN orders USING (id);",
	)
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_statement(
		&s,
		"SELECT * FROM customers " +
		"JOIN orders ON customers.id = orders.customer_id " +
		"JOIN customers AS c2 ON c2.id = orders.customer_id;",
	)
	testing.expect(t, exec.has_error(e3))
	testing.expect_value(t, e3.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e3)
	exec.free_result(r3)
}

@(test)
test_join_with_aggregate :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_join_tables(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT COUNT(*) FROM customers JOIN orders ON customers.id = orders.customer_id;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "3")
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(
		&s,
		"SELECT c.name, COUNT(*) AS n FROM customers AS c " +
		"JOIN orders AS o ON c.id = o.customer_id " +
		"GROUP BY c.name ORDER BY c.name;",
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 2)
	testing.expect_value(t, r2.rows[0][0], "alice")
	testing.expect_value(t, r2.rows[0][1], "2")
	testing.expect_value(t, r2.rows[1][0], "bob")
	testing.expect_value(t, r2.rows[1][1], "1")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_join_duplicate_alias_and_unknown_table :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_join_tables(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT * FROM customers AS t JOIN orders AS t ON t.id = t.customer_id;",
	)
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Invalid_Schema)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(
		&s,
		"SELECT * FROM customers JOIN missing ON customers.id = missing.id;",
	)
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Unknown_Table)
	exec.free_error(e2)
	exec.free_result(r2)
}
