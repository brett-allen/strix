package exec_tests

import "core:fmt"
import "core:os"
import "core:testing"
import engine "../../engine"
import exec "../../exec"

@(test)
test_insert_reopen_table_get_row_decode :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-e2-insert-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		s := exec.session_adopt(&e)
		r, eerr := exec.exec_script(
			&s,
			"CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL);" +
			"INSERT INTO users (id, name, score) VALUES (1, 'alice', 3.5);",
		)
		testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
		testing.expect_value(t, r.kind, exec.Result_Kind.Rows_Affected)
		testing.expect_value(t, r.rows_affected, 1)
		exec.free_error(eerr)
		exec.free_result(r)
		engine.engine_close(&e)
	}

	e2, err2 := engine.engine_open(path)
	testing.expect(t, engine.ok(err2))
	defer engine.engine_close(&e2)

	tree, oerr := engine.catalog_open_table(&e2, "users")
	testing.expect(t, engine.ok(oerr))
	payload, gerr := engine.table_get_row(&tree, 1)
	testing.expect(t, engine.ok(gerr))
	defer delete(payload)

	vals, derr := exec.decode_heap_row(payload)
	testing.expectf(t, !exec.has_error(derr), "%s", derr.message)
	defer exec.free_error(derr)
	defer exec.free_values(vals)

	testing.expect_value(t, len(vals), 3)
	testing.expect_value(t, vals[0].kind, exec.Value_Kind.Integer)
	testing.expect_value(t, vals[0].i, i64(1))
	testing.expect_value(t, string(vals[1].bytes), "alice")
	testing.expect_value(t, vals[2].f, f64(3.5))
}

@(test)
test_insert_multi_row_named_null :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_statement(&s, "CREATE TABLE t (a INT, b TEXT);")
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(
		&s,
		"INSERT INTO t (b, a) VALUES ('x', 1), (NULL, 2);",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.rows_affected, 2)
	exec.free_error(eerr)
	exec.free_result(r)

	tree, oerr := engine.catalog_open_table(&e, "t")
	testing.expect(t, engine.ok(oerr))

	p1, g1 := engine.table_get_row(&tree, 1)
	testing.expect(t, engine.ok(g1))
	defer delete(p1)
	v1, d1 := exec.decode_heap_row(p1)
	testing.expect(t, !exec.has_error(d1))
	defer exec.free_error(d1)
	defer exec.free_values(v1)
	testing.expect_value(t, v1[0].i, i64(1))
	testing.expect_value(t, string(v1[1].bytes), "x")

	p2, g2 := engine.table_get_row(&tree, 2)
	testing.expect(t, engine.ok(g2))
	defer delete(p2)
	v2, d2 := exec.decode_heap_row(p2)
	testing.expect(t, !exec.has_error(d2))
	defer exec.free_error(d2)
	defer exec.free_values(v2)
	testing.expect_value(t, v2[0].i, i64(2))
	testing.expect_value(t, v2[1].kind, exec.Value_Kind.Null)
}

@(test)
test_insert_not_null_violation :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_statement(&s, "CREATE TABLE t (a INT NOT NULL);")
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(&s, "INSERT INTO t VALUES (NULL);")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_insert_rowid_allocation_persists_next_rowid :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-e2-rowid-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		s := exec.session_adopt(&e)
		r, eerr := exec.exec_script(
			&s,
			"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);" +
			"INSERT INTO t (name) VALUES ('a'), ('b');",
		)
		testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
		testing.expect_value(t, r.rows_affected, 2)
		exec.free_error(eerr)
		exec.free_result(r)

		entry, gerr := engine.catalog_get_table_entry(&e, "t")
		testing.expect(t, engine.ok(gerr))
		testing.expect_value(t, entry.next_rowid, u64(3))
		engine.free_catalog_entry(entry)
		engine.engine_close(&e)
	}

	e2, err2 := engine.engine_open(path)
	testing.expect(t, engine.ok(err2))
	defer engine.engine_close(&e2)
	entry2, g2 := engine.catalog_get_table_entry(&e2, "t")
	testing.expect(t, engine.ok(g2))
	defer engine.free_catalog_entry(entry2)
	testing.expect_value(t, entry2.next_rowid, u64(3))

	s2 := exec.session_adopt(&e2)
	r2, eerr2 := exec.exec_statement(&s2, "INSERT INTO t (name) VALUES ('c');")
	testing.expectf(t, !exec.has_error(eerr2), "%s", eerr2.message)
	exec.free_error(eerr2)
	exec.free_result(r2)

	tree, oerr := engine.catalog_open_table(&e2, "t")
	testing.expect(t, engine.ok(oerr))
	payload, gerr := engine.table_get_row(&tree, 3)
	testing.expect(t, engine.ok(gerr))
	defer delete(payload)
	vals, derr := exec.decode_heap_row(payload)
	testing.expect(t, !exec.has_error(derr))
	defer exec.free_error(derr)
	defer exec.free_values(vals)
	testing.expect_value(t, vals[0].i, i64(3))
	testing.expect_value(t, string(vals[1].bytes), "c")
}

@(test)
test_insert_explicit_pk_updates_next_rowid :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);" +
		"INSERT INTO t VALUES (10, 'x');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	entry, gerr := engine.catalog_get_table_entry(&e, "t")
	testing.expect(t, engine.ok(gerr))
	testing.expect_value(t, entry.next_rowid, u64(11))
	engine.free_catalog_entry(entry)
}

@(test)
test_insert_rejects_unsupported_shapes :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	rc, ec := exec.exec_script(&s, "CREATE TABLE t (a INT); CREATE TABLE src (a INT);")
	testing.expectf(t, !exec.has_error(ec), "%s", ec.message)
	exec.free_error(ec)
	exec.free_result(rc)

	{
		r, eerr := exec.exec_statement(&s, "INSERT OR REPLACE INTO t VALUES (1);")
		testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
		exec.free_error(eerr)
		exec.free_result(r)
	}
	{
		r, eerr := exec.exec_statement(&s, "INSERT OR IGNORE INTO t VALUES (1);")
		testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
		exec.free_error(eerr)
		exec.free_result(r)
	}
	{
		r, eerr := exec.exec_statement(&s, "INSERT INTO t SELECT a FROM src;")
		testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
		exec.free_error(eerr)
		exec.free_result(r)
	}
	{
		// DEFAULT VALUES rejected at parse → Parse
		r, eerr := exec.exec_statement(&s, "INSERT INTO t DEFAULT VALUES;")
		testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Parse)
		exec.free_error(eerr)
		exec.free_result(r)
	}
	{
		r, eerr := exec.exec_statement(&s, "INSERT INTO t (nope) VALUES (1);")
		testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unknown_Column)
		exec.free_error(eerr)
		exec.free_result(r)
	}
	{
		r, eerr := exec.exec_statement(&s, "INSERT INTO missing VALUES (1);")
		testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unknown_Table)
		exec.free_error(eerr)
		exec.free_result(r)
	}
}

@(test)
test_insert_uses_column_default :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (a INT DEFAULT 9, b TEXT);" +
		"INSERT INTO t (b) VALUES ('z');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	tree, oerr := engine.catalog_open_table(&e, "t")
	testing.expect(t, engine.ok(oerr))
	payload, gerr := engine.table_get_row(&tree, 1)
	testing.expect(t, engine.ok(gerr))
	defer delete(payload)
	vals, derr := exec.decode_heap_row(payload)
	testing.expect(t, !exec.has_error(derr))
	defer exec.free_error(derr)
	defer exec.free_values(vals)
	testing.expect_value(t, vals[0].i, i64(9))
	testing.expect_value(t, string(vals[1].bytes), "z")
}

@(test)
test_insert_duplicate_rowid_constraint :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);" +
		"INSERT INTO t VALUES (1, 'a');",
	)
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(&s, "INSERT INTO t VALUES (1, 'b');")
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_insert_int_primary_key_auto_rowid :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INT PRIMARY KEY, n TEXT);" +
		"INSERT INTO t (n) VALUES ('a'), ('b');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	testing.expect_value(t, r0.rows_affected, 2)
	exec.free_error(e0)
	exec.free_result(r0)

	entry, gerr := engine.catalog_get_table_entry(&e, "t")
	testing.expect(t, engine.ok(gerr))
	testing.expect_value(t, entry.next_rowid, u64(3))
	engine.free_catalog_entry(entry)

	tree, oerr := engine.catalog_open_table(&e, "t")
	testing.expect(t, engine.ok(oerr))
	{
		payload, gerr := engine.table_get_row(&tree, 1)
		testing.expect(t, engine.ok(gerr))
		defer delete(payload)
		vals, derr := exec.decode_heap_row(payload)
		testing.expect(t, !exec.has_error(derr))
		defer exec.free_error(derr)
		defer exec.free_values(vals)
		testing.expect_value(t, vals[0].kind, exec.Value_Kind.Integer)
		testing.expect_value(t, vals[0].i, i64(1))
		testing.expect_value(t, string(vals[1].bytes), "a")
	}
	{
		payload, gerr := engine.table_get_row(&tree, 2)
		testing.expect(t, engine.ok(gerr))
		defer delete(payload)
		vals, derr := exec.decode_heap_row(payload)
		testing.expect(t, !exec.has_error(derr))
		defer exec.free_error(derr)
		defer exec.free_values(vals)
		testing.expect_value(t, vals[0].kind, exec.Value_Kind.Integer)
		testing.expect_value(t, vals[0].i, i64(2))
		testing.expect_value(t, string(vals[1].bytes), "b")
	}
}

@(test)
test_insert_multi_row_mid_failure_rolls_back :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_statement(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);")
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(&s, "INSERT INTO t VALUES (1, 'a'), (1, 'b');")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(eerr)
	exec.free_result(r)

	tree, oerr := engine.catalog_open_table(&e, "t")
	testing.expect(t, engine.ok(oerr))
	_, g1 := engine.table_get_row(&tree, 1)
	testing.expect_value(t, g1, engine.Engine_Error.Not_Found)

	entry, gerr := engine.catalog_get_table_entry(&e, "t")
	testing.expect(t, engine.ok(gerr))
	testing.expect_value(t, entry.next_rowid, u64(1))
	engine.free_catalog_entry(entry)
}

@(test)
test_insert_blob_literal_x_hex :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, b BLOB);" +
		"INSERT INTO t VALUES (1, X'ABCD');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	tree, oerr := engine.catalog_open_table(&e, "t")
	testing.expect(t, engine.ok(oerr))
	payload, gerr := engine.table_get_row(&tree, 1)
	testing.expect(t, engine.ok(gerr))
	defer delete(payload)
	vals, derr := exec.decode_heap_row(payload)
	testing.expect(t, !exec.has_error(derr))
	defer exec.free_error(derr)
	defer exec.free_values(vals)
	testing.expect_value(t, vals[1].kind, exec.Value_Kind.Blob)
	testing.expect_value(t, len(vals[1].bytes), 2)
	testing.expect_value(t, vals[1].bytes[0], u8(0xAB))
	testing.expect_value(t, vals[1].bytes[1], u8(0xCD))
}
