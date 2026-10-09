package exec_tests

import "core:testing"
import engine "../../engine"
import exec "../../exec"

@(test)
test_bind_insert_select_params :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_statement(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL);")
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)
	exec.free_result(r0)

	params := []exec.Value{exec.value_integer(1), exec.value_text("alice")}
	defer exec.free_value(params[1])
	r, eerr := exec.exec_statement_params(
		&s,
		"INSERT INTO t (id, name) VALUES (?, ?)",
		params,
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.rows_affected, 1)
	exec.free_error(eerr)
	exec.free_result(r)
	testing.expect_value(t, exec.session_bind_count(&s), 0) // cleared after params exec

	p2 := []exec.Value{exec.value_integer(1)}
	rs, serr := exec.exec_statement_params(&s, "SELECT id, name FROM t WHERE id = ?", p2)
	testing.expectf(t, !exec.has_error(serr), "%s", serr.message)
	testing.expect_value(t, rs.kind, exec.Result_Kind.Result_Set)
	testing.expect_value(t, len(rs.rows), 1)
	testing.expect_value(t, rs.rows[0][0], "1")
	testing.expect_value(t, rs.rows[0][1], "alice")
	exec.free_error(serr)
	exec.free_result(rs)
}

@(test)
test_bind_update_delete_where_set :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT, n INT);" +
		"INSERT INTO items VALUES (1, 'a', 10), (2, 'b', 20);",
	)
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)
	exec.free_result(r0)

	// UPDATE SET ? WHERE ?
	set_params := []exec.Value{exec.value_text("z"), exec.value_integer(1)}
	defer exec.free_value(set_params[0])
	ru, eu := exec.exec_statement_params(
		&s,
		"UPDATE items SET label = ? WHERE id = ?",
		set_params,
	)
	testing.expectf(t, !exec.has_error(eu), "%s", eu.message)
	testing.expect_value(t, ru.rows_affected, 1)
	exec.free_error(eu)
	exec.free_result(ru)

	rd, ed := exec.exec_statement_params(
		&s,
		"DELETE FROM items WHERE n = ?",
		[]exec.Value{exec.value_integer(20)},
	)
	testing.expectf(t, !exec.has_error(ed), "%s", ed.message)
	testing.expect_value(t, rd.rows_affected, 1)
	exec.free_error(ed)
	exec.free_result(rd)

	rs, es := exec.exec_statement(&s, "SELECT id, label FROM items ORDER BY id")
	testing.expect(t, !exec.has_error(es))
	testing.expect_value(t, len(rs.rows), 1)
	testing.expect_value(t, rs.rows[0][0], "1")
	testing.expect_value(t, rs.rows[0][1], "z")
	exec.free_error(es)
	exec.free_result(rs)
}

@(test)
test_bind_qn_explicit_and_reuse :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	_, e0 := exec.exec_statement(&s, "CREATE TABLE t (a INT, b INT, c INT);")
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)

	// ?1 and ?0 explicit; arity = max+1 = 2
	params := []exec.Value{exec.value_integer(10), exec.value_integer(20)}
	r, eerr := exec.exec_statement_params(
		&s,
		"INSERT INTO t (a, b, c) VALUES (?1, ?0, ?1)",
		params,
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.rows_affected, 1)
	exec.free_error(eerr)
	exec.free_result(r)

	rs, es := exec.exec_statement(&s, "SELECT a, b, c FROM t")
	testing.expect(t, !exec.has_error(es))
	testing.expect_value(t, rs.rows[0][0], "20")
	testing.expect_value(t, rs.rows[0][1], "10")
	testing.expect_value(t, rs.rows[0][2], "20")
	exec.free_error(es)
	exec.free_result(rs)
}

@(test)
test_bind_unbound_and_arity_errors :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	_, e0 := exec.exec_statement(&s, "CREATE TABLE t (a INT);")
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)

	// Arity: too few
	r1, err1 := exec.exec_statement_params(
		&s,
		"INSERT INTO t VALUES (?, ?)",
		[]exec.Value{exec.value_integer(1)},
	)
	testing.expect(t, exec.has_error(err1))
	testing.expect_value(t, err1.code, exec.Exec_Error_Code.Invalid_Schema)
	exec.free_error(err1)
	exec.free_result(r1)

	// Arity: too many
	r2, err2 := exec.exec_statement_params(
		&s,
		"INSERT INTO t VALUES (?)",
		[]exec.Value{exec.value_integer(1), exec.value_integer(2)},
	)
	testing.expect(t, exec.has_error(err2))
	testing.expect_value(t, err2.code, exec.Exec_Error_Code.Invalid_Schema)
	exec.free_error(err2)
	exec.free_result(r2)

	// Arity: params on statement with no placeholders
	r3, err3 := exec.exec_statement_params(
		&s,
		"INSERT INTO t VALUES (1)",
		[]exec.Value{exec.value_integer(9)},
	)
	testing.expect(t, exec.has_error(err3))
	testing.expect_value(t, err3.code, exec.Exec_Error_Code.Invalid_Schema)
	exec.free_error(err3)
	exec.free_result(r3)

	// Dense arity footgun: sole `?2` still requires slots 0..2 (len == max+1)
	r3b, err3b := exec.exec_statement_params(
		&s,
		"INSERT INTO t VALUES (?2)",
		[]exec.Value{exec.value_integer(9)},
	)
	testing.expect(t, exec.has_error(err3b))
	testing.expect_value(t, err3b.code, exec.Exec_Error_Code.Invalid_Schema)
	exec.free_error(err3b)
	exec.free_result(r3b)
	r3c, err3c := exec.exec_statement_params(
		&s,
		"INSERT INTO t VALUES (?2)",
		[]exec.Value{exec.value_integer(0), exec.value_integer(1), exec.value_integer(9)},
	)
	testing.expectf(t, !exec.has_error(err3c), "%s", err3c.message)
	testing.expect_value(t, r3c.rows_affected, 1)
	exec.free_error(err3c)
	exec.free_result(r3c)

	// Unbound via session_bind + exec_statement (no arity pre-check)
	r4, err4 := exec.exec_statement(&s, "INSERT INTO t VALUES (?)")
	testing.expect(t, exec.has_error(err4))
	testing.expect_value(t, err4.code, exec.Exec_Error_Code.Invalid_Schema)
	exec.free_error(err4)
	exec.free_result(r4)
}

@(test)
test_bind_session_persist_and_clear :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	_, e0 := exec.exec_statement(&s, "CREATE TABLE t (a INT, b TEXT);")
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)

	v0 := exec.value_integer(7)
	v1 := exec.value_text("x")
	defer exec.free_value(v1)
	testing.expect(t, !exec.has_error(exec.session_bind(&s, 0, v0)))
	testing.expect(t, !exec.has_error(exec.session_bind(&s, 1, v1)))
	testing.expect_value(t, exec.session_bind_count(&s), 2)

	r, eerr := exec.exec_statement(&s, "INSERT INTO t VALUES (?, ?)")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	exec.free_error(eerr)
	exec.free_result(r)
	// Binds persist after plain exec_statement
	testing.expect_value(t, exec.session_bind_count(&s), 2)

	exec.session_clear_binds(&s)
	testing.expect_value(t, exec.session_bind_count(&s), 0)
}

@(test)
test_bind_type_constraint_on_column :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	_, e0 := exec.exec_statement(&s, "CREATE TABLE t (ok BOOLEAN);")
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)

	// Integer into BOOLEAN → Constraint (same as literal)
	r, eerr := exec.exec_statement_params(
		&s,
		"INSERT INTO t VALUES (?)",
		[]exec.Value{exec.value_integer(1)},
	)
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement_params(
		&s,
		"INSERT INTO t VALUES (?)",
		[]exec.Value{exec.value_boolean(true)},
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, r2.rows_affected, 1)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_bind_select_projection_and_join_on :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE a (id INT PRIMARY KEY, n INT);" +
		"CREATE TABLE b (id INT PRIMARY KEY, a_id INT);" +
		"INSERT INTO a VALUES (1, 100), (2, 200);" +
		"INSERT INTO b VALUES (10, 1), (20, 2);",
	)
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)
	exec.free_result(r0)

	// Projection `?` and JOIN ON `?` (not merely WHERE) must both bind.
	params := []exec.Value{exec.value_integer(50), exec.value_integer(10)}
	rs, es := exec.exec_statement_params(
		&s,
		"SELECT a.n + ? FROM a INNER JOIN b ON a.id = b.a_id AND b.id = ?",
		params,
	)
	testing.expectf(t, !exec.has_error(es), "%s", es.message)
	testing.expect_value(t, len(rs.rows), 1)
	testing.expect_value(t, rs.rows[0][0], "150")
	exec.free_error(es)
	exec.free_result(rs)
}

@(test)
test_bind_having_and_limit_params :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE sales (id INTEGER PRIMARY KEY, region TEXT, amt INT);" +
		"INSERT INTO sales VALUES (1, 'east', 10), (2, 'west', 20), (3, 'east', 30), (4, 'west', 40);",
	)
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)
	exec.free_result(r0)

	// HAVING `?` filters post-aggregate (east/west each COUNT=2; threshold 2 keeps both)
	rh, eh := exec.exec_statement_params(
		&s,
		"SELECT region, COUNT(*) FROM sales GROUP BY region HAVING COUNT(*) >= ? ORDER BY region",
		[]exec.Value{exec.value_integer(2)},
	)
	testing.expectf(t, !exec.has_error(eh), "%s", eh.message)
	testing.expect_value(t, len(rh.rows), 2)
	testing.expect_value(t, rh.rows[0][0], "east")
	testing.expect_value(t, rh.rows[0][1], "2")
	testing.expect_value(t, rh.rows[1][0], "west")
	testing.expect_value(t, rh.rows[1][1], "2")
	exec.free_error(eh)
	exec.free_result(rh)

	rh2, eh2 := exec.exec_statement_params(
		&s,
		"SELECT region, COUNT(*) FROM sales GROUP BY region HAVING COUNT(*) > ? ORDER BY region",
		[]exec.Value{exec.value_integer(2)},
	)
	testing.expectf(t, !exec.has_error(eh2), "%s", eh2.message)
	testing.expect_value(t, len(rh2.rows), 0)
	exec.free_error(eh2)
	exec.free_result(rh2)

	// LIMIT `?` (and OFFSET `?`) bind as integer exprs
	rl, el := exec.exec_statement_params(
		&s,
		"SELECT id FROM sales ORDER BY id LIMIT ? OFFSET ?",
		[]exec.Value{exec.value_integer(1), exec.value_integer(1)},
	)
	testing.expectf(t, !exec.has_error(el), "%s", el.message)
	testing.expect_value(t, len(rl.rows), 1)
	testing.expect_value(t, rl.rows[0][0], "2")
	exec.free_error(el)
	exec.free_result(rl)
}
