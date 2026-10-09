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
test_left_join_preserves_unmatched :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_join_tables(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT c.name, o.qty FROM customers AS c " +
		"LEFT JOIN orders AS o ON c.id = o.customer_id " +
		"ORDER BY c.name, o.qty;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 4) // alice×2, bob×1, cara×1 (NULL qty)
	testing.expect_value(t, r.rows[0][0], "alice")
	testing.expect_value(t, r.rows[0][1], "2")
	testing.expect_value(t, r.rows[1][0], "alice")
	testing.expect_value(t, r.rows[1][1], "5")
	testing.expect_value(t, r.rows[2][0], "bob")
	testing.expect_value(t, r.rows[2][1], "1")
	testing.expect_value(t, r.rows[3][0], "cara")
	testing.expect_value(t, r.rows[3][1], "NULL")
	exec.free_error(eerr)
	exec.free_result(r)

	// LEFT OUTER spelling
	r2, e2 := exec.exec_statement(
		&s,
		"SELECT c.name FROM customers AS c " +
		"LEFT OUTER JOIN orders AS o ON c.id = o.customer_id " +
		"WHERE o.id IS NULL;",
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "cara")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_left_join_on_vs_where :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_join_tables(t, &s)

	// WHERE after LEFT drops NULL-extended unmatched left rows.
	r, eerr := exec.exec_statement(
		&s,
		"SELECT c.name, o.qty FROM customers AS c " +
		"LEFT JOIN orders AS o ON c.id = o.customer_id " +
		"WHERE o.qty IS NOT NULL " +
		"ORDER BY c.name, o.qty;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 3)
	testing.expect_value(t, r.rows[0][0], "alice")
	testing.expect_value(t, r.rows[2][0], "bob")
	exec.free_error(eerr)
	exec.free_result(r)

	// Filter in ON keeps unmatched left (bob/cara NULL-padded when qty predicate fails).
	r2, e2 := exec.exec_statement(
		&s,
		"SELECT c.name, o.qty FROM customers AS c " +
		"LEFT JOIN orders AS o ON c.id = o.customer_id AND o.qty >= 5 " +
		"ORDER BY c.name, o.qty;",
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 3) // alice match, bob NULL, cara NULL
	testing.expect_value(t, r2.rows[0][0], "alice")
	testing.expect_value(t, r2.rows[0][1], "5")
	testing.expect_value(t, r2.rows[1][0], "bob")
	testing.expect_value(t, r2.rows[1][1], "NULL")
	testing.expect_value(t, r2.rows[2][0], "cara")
	testing.expect_value(t, r2.rows[2][1], "NULL")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_three_table_join_chain :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT);" +
		"CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INT);" +
		"CREATE TABLE items (id INTEGER PRIMARY KEY, order_id INT, sku TEXT);" +
		"INSERT INTO customers (id, name) VALUES (1, 'alice'), (2, 'bob'), (3, 'cara');" +
		"INSERT INTO orders (id, customer_id) VALUES (10, 1), (11, 2);" +
		"INSERT INTO items (id, order_id, sku) VALUES (100, 10, 'A'), (101, 10, 'B'), (102, 11, 'C');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT c.name, o.id, i.sku FROM customers AS c " +
		"JOIN orders AS o ON c.id = o.customer_id " +
		"JOIN items AS i ON i.order_id = o.id " +
		"ORDER BY c.name, i.sku;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 3)
	testing.expect_value(t, r.rows[0][0], "alice")
	testing.expect_value(t, r.rows[0][2], "A")
	testing.expect_value(t, r.rows[1][0], "alice")
	testing.expect_value(t, r.rows[1][2], "B")
	testing.expect_value(t, r.rows[2][0], "bob")
	testing.expect_value(t, r.rows[2][2], "C")
	exec.free_error(eerr)
	exec.free_result(r)

	// Mix LEFT + INNER left-deep: unmatched left (cara) drops when INNER requires order.
	r2, e2 := exec.exec_statement(
		&s,
		"SELECT c.name, i.sku FROM customers AS c " +
		"LEFT JOIN orders AS o ON c.id = o.customer_id " +
		"INNER JOIN items AS i ON i.order_id = o.id " +
		"ORDER BY c.name, i.sku;",
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 3)
	exec.free_error(e2)
	exec.free_result(r2)

	// LEFT through the chain preserves cara with NULLs.
	r3, e3 := exec.exec_statement(
		&s,
		"SELECT c.name, o.id, i.sku FROM customers AS c " +
		"LEFT JOIN orders AS o ON c.id = o.customer_id " +
		"LEFT JOIN items AS i ON i.order_id = o.id " +
		"ORDER BY c.name, i.sku;",
	)
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, len(r3.rows), 4) // alice×2, bob×1, cara×1
	testing.expect_value(t, r3.rows[3][0], "cara")
	testing.expect_value(t, r3.rows[3][1], "NULL")
	testing.expect_value(t, r3.rows[3][2], "NULL")
	exec.free_error(e3)
	exec.free_result(r3)
}

@(test)
test_join_three_table_ambiguous :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE a (id INT, x INT);" +
		"CREATE TABLE b (id INT, y INT);" +
		"CREATE TABLE c (id INT, z INT);" +
		"INSERT INTO a (id, x) VALUES (1, 10);" +
		"INSERT INTO b (id, y) VALUES (1, 20);" +
		"INSERT INTO c (id, z) VALUES (1, 30);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT id FROM a JOIN b ON a.id = b.id JOIN c ON a.id = c.id;",
	)
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unknown_Column)
	testing.expect(t, strings.contains(eerr.message, "ambiguous"))
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_join_rejects_using_right_full_natural :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_join_tables(t, &s)

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
		"SELECT * FROM customers RIGHT JOIN orders ON customers.id = orders.customer_id;",
	)
	testing.expect(t, exec.has_error(e3))
	testing.expect_value(t, e3.code, exec.Exec_Error_Code.Parse)
	exec.free_error(e3)
	exec.free_result(r3)

	r4, e4 := exec.exec_statement(
		&s,
		"SELECT * FROM customers FULL JOIN orders ON customers.id = orders.customer_id;",
	)
	testing.expect(t, exec.has_error(e4))
	testing.expect_value(t, e4.code, exec.Exec_Error_Code.Parse)
	exec.free_error(e4)
	exec.free_result(r4)

	r5, e5 := exec.exec_statement(
		&s,
		"SELECT * FROM customers NATURAL JOIN orders;",
	)
	testing.expect(t, exec.has_error(e5))
	testing.expect_value(t, e5.code, exec.Exec_Error_Code.Parse)
	exec.free_error(e5)
	exec.free_result(r5)
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

	// Aggs / GROUP BY / HAVING over LEFT join stream (unmatched left counted).
	r3, e3 := exec.exec_statement(
		&s,
		"SELECT c.name, COUNT(o.id) AS n FROM customers AS c " +
		"LEFT JOIN orders AS o ON c.id = o.customer_id " +
		"GROUP BY c.name HAVING COUNT(o.id) = 0 ORDER BY c.name;",
	)
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, len(r3.rows), 1)
	testing.expect_value(t, r3.rows[0][0], "cara")
	testing.expect_value(t, r3.rows[0][1], "0")
	exec.free_error(e3)
	exec.free_result(r3)
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
