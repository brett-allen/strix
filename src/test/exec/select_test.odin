package exec_tests

import "core:fmt"
import "core:os"
import "core:testing"
import engine "../../engine"
import exec "../../exec"

seed_people :: proc(t: ^testing.T, s: ^exec.Exec_Session) {
	r0, e0 := exec.exec_script(
		s,
		"CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, score INT);" +
		"INSERT INTO people (id, name, score) VALUES " +
		"(1, 'alice', 10), (2, 'bob', 30), (3, 'cara', 20), (4, NULL, 5);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)
}

@(test)
test_select_star_and_columns :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_people(t, &s)

	r, eerr := exec.exec_statement(&s, "SELECT * FROM people;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.kind, exec.Result_Kind.Result_Set)
	testing.expect_value(t, len(r.column_names), 3)
	testing.expect_value(t, r.column_names[0], "id")
	testing.expect_value(t, r.column_names[1], "name")
	testing.expect_value(t, len(r.rows), 4)
	testing.expect_value(t, r.rows[0][1], "alice")
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT name, score FROM people AS p;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.column_names), 2)
	testing.expect_value(t, r2.column_names[0], "name")
	testing.expect_value(t, len(r2.rows), 4)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_select_where_filter_and_exprs :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_people(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT name FROM people WHERE score >= 20 AND name IS NOT NULL;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 2)
	// rowid order: bob(30), cara(20)
	testing.expect_value(t, r.rows[0][0], "bob")
	testing.expect_value(t, r.rows[1][0], "cara")
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(
		&s,
		"SELECT id, score + 1 AS s1 FROM people WHERE id IN (1, 3);",
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 2)
	testing.expect_value(t, r2.column_names[1], "s1")
	testing.expect_value(t, r2.rows[0][1], "11")
	testing.expect_value(t, r2.rows[1][1], "21")
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_statement(
		&s,
		"SELECT name FROM people WHERE NOT (score < 10) OR name IS NULL;",
	)
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect(t, len(r3.rows) >= 3)
	exec.free_error(e3)
	exec.free_result(r3)

	// Integer boolean context: 1 = true, 0 = false.
	r4, e4 := exec.exec_statement(&s, "SELECT name FROM people WHERE 1;")
	testing.expectf(t, !exec.has_error(e4), "%s", e4.message)
	testing.expect_value(t, len(r4.rows), 4)
	exec.free_error(e4)
	exec.free_result(r4)

	r5, e5 := exec.exec_statement(&s, "SELECT name FROM people WHERE 0;")
	testing.expectf(t, !exec.has_error(e5), "%s", e5.message)
	testing.expect_value(t, len(r5.rows), 0)
	exec.free_error(e5)
	exec.free_result(r5)

	// S1: Text/Blob in boolean context → Unsupported_Ast (no SQLite truthiness).
	r6, e6 := exec.exec_statement(&s, "SELECT name FROM people WHERE name;")
	testing.expect(t, exec.has_error(e6))
	testing.expect_value(t, e6.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e6)
	exec.free_result(r6)

	r7, e7 := exec.exec_statement(&s, "SELECT name FROM people WHERE NOT name;")
	testing.expect(t, exec.has_error(e7))
	testing.expect_value(t, e7.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e7)
	exec.free_result(r7)

	r8, e8 := exec.exec_statement(&s, "SELECT name FROM people WHERE 0 OR name;")
	testing.expect(t, exec.has_error(e8))
	testing.expect_value(t, e8.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e8)
	exec.free_result(r8)
}

@(test)
test_select_order_by_limit_offset :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_people(t, &s)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT name, score FROM people WHERE name IS NOT NULL ORDER BY score DESC, name ASC LIMIT 2 OFFSET 0;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 2)
	testing.expect_value(t, r.rows[0][0], "bob")
	testing.expect_value(t, r.rows[0][1], "30")
	testing.expect_value(t, r.rows[1][0], "cara")
	testing.expect_value(t, r.rows[1][1], "20")
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(
		&s,
		"SELECT name FROM people WHERE name IS NOT NULL ORDER BY score ASC LIMIT 1 OFFSET 1;",
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "cara")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_select_order_by_incompatible_kinds_errors :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	// Mixed stored kinds in one column: ORDER BY must fail, not silently mis-sort.
	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, v);" +
		"INSERT INTO t VALUES (1, 'a'), (2, 1);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(&s, "SELECT id FROM t ORDER BY v;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_select_create_insert_roundtrip_reopen :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-e3-select-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		s := exec.session_adopt(&e)
		r, eerr := exec.exec_script(
			&s,
			"CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT);" +
			"INSERT INTO items (label) VALUES ('x'), ('y');",
		)
		testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
		exec.free_error(eerr)
		exec.free_result(r)
		engine.engine_close(&e)
	}

	e2, err2 := engine.engine_open(path)
	testing.expect(t, engine.ok(err2))
	defer engine.engine_close(&e2)
	s2 := exec.session_adopt(&e2)
	r2, eerr2 := exec.exec_statement(&s2, "SELECT id, label FROM items ORDER BY id;")
	testing.expectf(t, !exec.has_error(eerr2), "%s", eerr2.message)
	testing.expect_value(t, r2.kind, exec.Result_Kind.Result_Set)
	testing.expect_value(t, len(r2.rows), 2)
	testing.expect_value(t, r2.rows[0][0], "1")
	testing.expect_value(t, r2.rows[0][1], "x")
	testing.expect_value(t, r2.rows[1][1], "y")
	exec.free_error(eerr2)
	exec.free_result(r2)
}

@(test)
test_select_alias_and_table_star :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_people(t, &s)

	r, eerr := exec.exec_statement(&s, "SELECT p.id, p.name FROM people AS p WHERE p.id = 2;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "2")
	testing.expect_value(t, r.rows[0][1], "bob")
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT p.* FROM people p WHERE id = 1;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.column_names), 3)
	testing.expect_value(t, len(r2.rows), 1)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_select_negatives_codes :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_people(t, &s)

	r, eerr := exec.exec_statement(&s, "SELECT * FROM missing;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unknown_Table)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT nope FROM people;")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Unknown_Column)
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_statement(&s, "SELECT * FROM people WHERE missing_col = 1;")
	testing.expect(t, exec.has_error(e3))
	testing.expect_value(t, e3.code, exec.Exec_Error_Code.Unknown_Column)
	exec.free_error(e3)
	exec.free_result(r3)

	r4, e4 := exec.exec_statement(&s, "SELECT DISTINCT name FROM people;")
	testing.expect(t, exec.has_error(e4))
	testing.expect_value(t, e4.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e4)
	exec.free_result(r4)

	r5, e5 := exec.exec_statement(
		&s,
		"SELECT * FROM people JOIN people AS q ON people.id = q.id;",
	)
	testing.expect(t, exec.has_error(e5))
	testing.expect_value(t, e5.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e5)
	exec.free_result(r5)

	// GROUP BY is executed (S5); keep a still-unsupported form in this reject suite.
	r6, e6 := exec.exec_statement(&s, "SELECT DISTINCT name FROM people;")
	testing.expect(t, exec.has_error(e6))
	testing.expect_value(t, e6.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e6)
	exec.free_result(r6)

	// CAST is executed (S2); still reject BETWEEN.
	r8, e8 := exec.exec_statement(&s, "SELECT name FROM people WHERE score BETWEEN 1 AND 9;")
	testing.expect(t, exec.has_error(e8))
	testing.expect_value(t, e8.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e8)
	exec.free_result(r8)

	r9, e9 := exec.exec_statement(&s, "SELECT abs(score) FROM people;")
	testing.expect(t, exec.has_error(e9))
	testing.expect_value(t, e9.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e9)
	exec.free_result(r9)

	r10, e10 := exec.exec_statement(&s, "SELECT name FROM people WHERE id = ?;")
	testing.expect(t, exec.has_error(e10))
	testing.expect_value(t, e10.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e10)
	exec.free_result(r10)
}

@(test)
test_expr_eval_literals_and_logic :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_people(t, &s)

	// Arithmetic + concat projection (text, int, float → text)
	r, eerr := exec.exec_statement(
		&s,
		"SELECT 'hi' || name AS g, -score AS neg, 'x' || 1.5 AS f FROM people WHERE id = 1;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.rows[0][0], "hialice")
	testing.expect_value(t, r.rows[0][1], "-10")
	testing.expect_value(t, r.rows[0][2], "x1.5")
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT name FROM people WHERE name = 'alice';")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_select_blob_and_empty_result :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE b (id INTEGER PRIMARY KEY, data BLOB);" +
		"INSERT INTO b (data) VALUES (X'ABCD');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(&s, "SELECT data FROM b;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.rows[0][0], "X'ABCD'")
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT id FROM b WHERE id = 99;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, r2.kind, exec.Result_Kind.Result_Set)
	testing.expect_value(t, len(r2.rows), 0)
	testing.expect_value(t, len(r2.column_names), 1)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_clone_value_used_by_column_ref :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	seed_people(t, &s)

	// Projection of same column twice must own independent text cells.
	r, eerr := exec.exec_statement(&s, "SELECT name, name AS n2 FROM people WHERE id = 1;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.rows[0][0], "alice")
	testing.expect_value(t, r.rows[0][1], "alice")
	exec.free_error(eerr)
	exec.free_result(r)
}
