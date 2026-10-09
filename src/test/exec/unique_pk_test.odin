package exec_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import engine "../../engine"
import exec "../../exec"

@(test)
test_text_pk_crud_and_null_reject :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id TEXT PRIMARY KEY, name TEXT);" +
		"INSERT INTO t VALUES ('a', 'alice'), ('b', 'bob');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(&s, "SELECT id, name FROM t WHERE id = 'b';")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "b")
	testing.expect_value(t, r.rows[0][1], "bob")
	exec.free_error(eerr)
	exec.free_result(r)

	ru, eu := exec.exec_statement(&s, "UPDATE t SET name = 'bobby' WHERE id = 'b';")
	testing.expectf(t, !exec.has_error(eu), "%s", eu.message)
	testing.expect_value(t, ru.rows_affected, 1)
	exec.free_error(eu)
	exec.free_result(ru)

	rd, ed := exec.exec_statement(&s, "DELETE FROM t WHERE id = 'a';")
	testing.expectf(t, !exec.has_error(ed), "%s", ed.message)
	testing.expect_value(t, rd.rows_affected, 1)
	exec.free_error(ed)
	exec.free_result(rd)

	rn, en := exec.exec_statement(&s, "INSERT INTO t (id, name) VALUES (NULL, 'x');")
	testing.expect(t, exec.has_error(en))
	testing.expect_value(t, en.code, exec.Exec_Error_Code.Constraint)
	testing.expect(t, strings.contains(en.message, "NOT NULL") || strings.contains(en.message, "NULL"))
	exec.free_error(en)
	exec.free_result(rn)
}

@(test)
test_text_pk_duplicate_constraint :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id TEXT PRIMARY KEY, n INT);" +
		"INSERT INTO t VALUES ('x', 1);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(&s, "INSERT INTO t VALUES ('x', 2);")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Constraint)
	testing.expect(t, strings.contains(eerr.message, "UNIQUE"))
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_column_and_table_unique_enforced :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, email TEXT UNIQUE, code TEXT, UNIQUE (code));" +
		"INSERT INTO t (email, code) VALUES ('a@x.com', 'A');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	re, ee := exec.exec_statement(&s, "INSERT INTO t (email, code) VALUES ('a@x.com', 'B');")
	testing.expect(t, exec.has_error(ee))
	testing.expect_value(t, ee.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(ee)
	exec.free_result(re)

	rc, ec := exec.exec_statement(&s, "INSERT INTO t (email, code) VALUES ('b@x.com', 'A');")
	testing.expect(t, exec.has_error(ec))
	testing.expect_value(t, ec.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(ec)
	exec.free_result(rc)

	rok, eok := exec.exec_statement(&s, "INSERT INTO t (email, code) VALUES ('b@x.com', 'B');")
	testing.expectf(t, !exec.has_error(eok), "%s", eok.message)
	exec.free_error(eok)
	exec.free_result(rok)
}

@(test)
test_unique_allows_multiple_nulls :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, email TEXT UNIQUE);" +
		"INSERT INTO t (email) VALUES (NULL), (NULL);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r2, e2 := exec.exec_statement(&s, "SELECT id FROM t;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 2)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_create_unique_index_enforced :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);" +
		"INSERT INTO t VALUES (1, 'a'), (2, 'b');" +
		"CREATE UNIQUE INDEX t_name ON t (name);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	entry, gerr := engine.catalog_get_index_entry(&e, "t_name")
	testing.expect(t, engine.ok(gerr))
	testing.expect(t, engine.catalog_index_is_unique(entry))
	engine.free_catalog_entry(entry)

	r, eerr := exec.exec_statement(&s, "INSERT INTO t VALUES (3, 'a');")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(eerr)
	exec.free_result(r)

	// Backfill collision
	r2, e2 := exec.exec_script(
		&s,
		"CREATE TABLE u (id INTEGER PRIMARY KEY, name TEXT);" +
		"INSERT INTO u VALUES (1, 'x'), (2, 'x');" +
		"CREATE UNIQUE INDEX u_name ON u (name);",
	)
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_ipk_regression_no_autoindex :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);" +
		"INSERT INTO t (n) VALUES ('a'), ('b');" +
		"INSERT INTO t (id, n) VALUES (10, 'c');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	_, gerr := engine.catalog_get_index_entry(&e, "strix_autoindex_t_1")
	testing.expect_value(t, gerr, engine.Engine_Error.Not_Found)

	rdup, edup := exec.exec_statement(&s, "INSERT INTO t (id, n) VALUES (10, 'dup');")
	testing.expect(t, exec.has_error(edup))
	testing.expect_value(t, edup.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(edup)
	exec.free_result(rdup)

	r, eerr := exec.exec_statement(&s, "SELECT id, n FROM t ORDER BY id;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 3)
	testing.expect_value(t, r.rows[0][0], "1")
	testing.expect_value(t, r.rows[2][0], "10")
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_text_pk_update_unique_and_drop_table :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id TEXT PRIMARY KEY, n INT);" +
		"INSERT INTO t VALUES ('a', 1), ('b', 2);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	ru, eu := exec.exec_statement(&s, "UPDATE t SET id = 'a' WHERE id = 'b';")
	testing.expect(t, exec.has_error(eu))
	testing.expect_value(t, eu.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(eu)
	exec.free_result(ru)

	rok, eok := exec.exec_statement(&s, "UPDATE t SET id = 'c' WHERE id = 'b';")
	testing.expectf(t, !exec.has_error(eok), "%s", eok.message)
	exec.free_error(eok)
	exec.free_result(rok)

	// DROP TABLE auto-drops system unique index.
	rd, ed := exec.exec_statement(&s, "DROP TABLE t;")
	testing.expectf(t, !exec.has_error(ed), "%s", ed.message)
	exec.free_error(ed)
	exec.free_result(rd)

	_, gerr := engine.catalog_get_index_entry(&e, "strix_autoindex_t_1")
	testing.expect_value(t, gerr, engine.Engine_Error.Not_Found)
}

@(test)
test_text_pk_durable_reopen :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-s3-text-pk-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		s := exec.session_adopt(&e)
		r, eerr := exec.exec_script(
			&s,
			"CREATE TABLE t (id TEXT PRIMARY KEY, n INT);" +
			"INSERT INTO t VALUES ('uuid-1', 1), ('uuid-2', 2);",
		)
		testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
		exec.free_error(eerr)
		exec.free_result(r)
		exec.session_close(&s)
		engine.engine_close(&e)
	}

	{
		e, err := engine.engine_open(path)
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)
		s := exec.session_adopt(&e)

		idx, ierr := engine.catalog_get_index_entry(&e, "strix_autoindex_t_1")
		testing.expect(t, engine.ok(ierr))
		testing.expect(t, engine.catalog_index_is_unique(idx))
		engine.free_catalog_entry(idx)

		r, eerr := exec.exec_statement(&s, "SELECT n FROM t WHERE id = 'uuid-2';")
		testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
		testing.expect_value(t, len(r.rows), 1)
		testing.expect_value(t, r.rows[0][0], "2")
		exec.free_error(eerr)
		exec.free_result(r)

		rdup, edup := exec.exec_statement(&s, "INSERT INTO t VALUES ('uuid-1', 99);")
		testing.expect(t, exec.has_error(edup))
		testing.expect_value(t, edup.code, exec.Exec_Error_Code.Constraint)
		exec.free_error(edup)
		exec.free_result(rdup)
	}
}

@(test)
test_schema_sql_shows_text_pk_and_unique :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r1, e1 := exec.exec_script(
		&s,
		"CREATE TABLE t (id TEXT PRIMARY KEY, email TEXT UNIQUE);" +
		"CREATE UNIQUE INDEX u_code ON t (email);",
	)
	testing.expectf(t, !exec.has_error(e1), "%s", e1.message)
	exec.free_error(e1)
	exec.free_result(r1)

	text, serr := exec.schema_sql(&s, "t")
	testing.expectf(t, !exec.has_error(serr), "%s", serr.message)
	defer exec.free_error(serr)
	defer delete(text)
	testing.expect(t, strings.contains(text, "id TEXT PRIMARY KEY"))
	testing.expect(t, strings.contains(text, "email TEXT UNIQUE"))
	testing.expect(t, !strings.contains(text, "strix_autoindex_"))
	testing.expect(t, strings.contains(text, "CREATE UNIQUE INDEX u_code ON t (email);"))
}

@(test)
test_schema_sql_shows_table_level_single_unique :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_statement(&s, "CREATE TABLE s (a TEXT, UNIQUE (a));")
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	entry, gerr := engine.catalog_get_table_entry(&e, "s")
	testing.expect(t, engine.ok(gerr))
	testing.expect(t, .Unique in entry.columns[0].flags)
	engine.free_catalog_entry(entry)

	text, serr := exec.schema_sql(&s, "s")
	testing.expectf(t, !exec.has_error(serr), "%s", serr.message)
	defer exec.free_error(serr)
	defer delete(text)
	has_col_unique := strings.contains(text, "a TEXT UNIQUE")
	has_idx_unique := strings.contains(text, "CREATE UNIQUE INDEX") && strings.contains(text, "(a)")
	testing.expect(t, has_col_unique || has_idx_unique)
	if has_col_unique {
		testing.expect(t, !strings.contains(text, "strix_autoindex_"))
	}
}

@(test)
test_text_pk_update_null_constraint :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id TEXT PRIMARY KEY, n INT);" +
		"INSERT INTO t VALUES ('a', 1);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	ru, eu := exec.exec_statement(&s, "UPDATE t SET id = NULL WHERE id = 'a';")
	testing.expect(t, exec.has_error(eu))
	testing.expect_value(t, eu.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(eu)
	exec.free_result(ru)
}

@(test)
test_create_index_rejects_system_autoindex_prefix :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_statement(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);")
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	cases := []string{
		"CREATE INDEX strix_autoindex_user ON t (n);",
		"CREATE UNIQUE INDEX STRIX_AUTOINDEX_x ON t (n);",
	}
	for sql_text in cases {
		r, eerr := exec.exec_statement(&s, sql_text)
		testing.expect(t, exec.has_error(eerr))
		testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Invalid_Schema)
		testing.expect(t, strings.contains(eerr.message, "reserved") || strings.contains(eerr.message, "strix_autoindex_"))
		exec.free_error(eerr)
		exec.free_result(r)
	}
}

@(test)
test_ipk_unique_skips_redundant_autoindex :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_statement(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY UNIQUE, n TEXT);")
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	_, gerr := engine.catalog_get_index_entry(&e, "strix_autoindex_t_1")
	testing.expect_value(t, gerr, engine.Engine_Error.Not_Found)

	entry, terr := engine.catalog_get_table_entry(&e, "t")
	testing.expect(t, engine.ok(terr))
	testing.expect(t, .Primary_Key in entry.columns[0].flags)
	testing.expect(t, .Unique in entry.columns[0].flags)
	engine.free_catalog_entry(entry)
}

@(test)
test_uuid_type_as_text_pk :: proc(t: ^testing.T) {
	// F3: UUID PRIMARY KEY is typed 16-byte storage (string bind still accepted).
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id UUID PRIMARY KEY, label TEXT);" +
		"INSERT INTO t VALUES ('550e8400-e29b-41d4-a716-446655440000', 'x');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(
		&s,
		"SELECT id, label FROM t WHERE id = '550e8400-e29b-41d4-a716-446655440000';",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "550e8400-e29b-41d4-a716-446655440000")
	testing.expect_value(t, r.rows[0][1], "x")
	exec.free_error(eerr)
	exec.free_result(r)

	rdup, edup := exec.exec_statement(
		&s,
		"INSERT INTO t VALUES ('550e8400-e29b-41d4-a716-446655440000', 'y');",
	)
	testing.expect(t, exec.has_error(edup))
	testing.expect_value(t, edup.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(edup)
	exec.free_result(rdup)
}

@(test)
test_composite_pk_crud_duplicate_and_null :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (a TEXT, b TEXT, n INT, PRIMARY KEY (a, b));" +
		"INSERT INTO t VALUES ('x', '1', 10), ('x', '2', 20);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(&s, "SELECT a, b, n FROM t WHERE a = 'x' AND b = '2';")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][2], "20")
	exec.free_error(eerr)
	exec.free_result(r)

	ru, eu := exec.exec_statement(&s, "UPDATE t SET n = 21 WHERE a = 'x' AND b = '2';")
	testing.expectf(t, !exec.has_error(eu), "%s", eu.message)
	testing.expect_value(t, ru.rows_affected, 1)
	exec.free_error(eu)
	exec.free_result(ru)

	rdup, edup := exec.exec_statement(&s, "INSERT INTO t VALUES ('x', '1', 99);")
	testing.expect(t, exec.has_error(edup))
	testing.expect_value(t, edup.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(edup)
	exec.free_result(rdup)

	// UPDATE that would collide on composite PK.
	rcoll, ecoll := exec.exec_statement(&s, "UPDATE t SET b = '1' WHERE a = 'x' AND b = '2';")
	testing.expect(t, exec.has_error(ecoll))
	testing.expect_value(t, ecoll.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(ecoll)
	exec.free_result(rcoll)

	rn, en := exec.exec_statement(&s, "INSERT INTO t VALUES (NULL, '1', 1);")
	testing.expect(t, exec.has_error(en))
	testing.expect_value(t, en.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(en)
	exec.free_result(rn)

	rn2, en2 := exec.exec_statement(&s, "INSERT INTO t VALUES ('y', NULL, 1);")
	testing.expect(t, exec.has_error(en2))
	testing.expect_value(t, en2.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(en2)
	exec.free_result(rn2)

	rd, ed := exec.exec_statement(&s, "DELETE FROM t WHERE a = 'x' AND b = '1';")
	testing.expectf(t, !exec.has_error(ed), "%s", ed.message)
	testing.expect_value(t, rd.rows_affected, 1)
	exec.free_error(ed)
	exec.free_result(rd)

	// After delete, the pair can be re-inserted.
	rok, eok := exec.exec_statement(&s, "INSERT INTO t VALUES ('x', '1', 11);")
	testing.expectf(t, !exec.has_error(eok), "%s", eok.message)
	exec.free_error(eok)
	exec.free_result(rok)

	rdrop, edrop := exec.exec_statement(&s, "DROP TABLE t;")
	testing.expectf(t, !exec.has_error(edrop), "%s", edrop.message)
	exec.free_error(edrop)
	exec.free_result(rdrop)
	_, gerr := engine.catalog_get_index_entry(&e, "strix_autoindex_t_1")
	testing.expect_value(t, gerr, engine.Engine_Error.Not_Found)
}

@(test)
test_composite_pk_durable_reopen :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-f2-composite-pk-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		s := exec.session_adopt(&e)
		r, eerr := exec.exec_script(
			&s,
			"CREATE TABLE t (a TEXT, b TEXT, n INT, PRIMARY KEY (a, b));" +
			"INSERT INTO t VALUES ('u', '1', 1), ('u', '2', 2);",
		)
		testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
		exec.free_error(eerr)
		exec.free_result(r)
		exec.session_close(&s)
		engine.engine_close(&e)
	}

	{
		e, err := engine.engine_open(path)
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)
		s := exec.session_adopt(&e)

		idx, ierr := engine.catalog_get_index_entry(&e, "strix_autoindex_t_1")
		testing.expect(t, engine.ok(ierr))
		testing.expect(t, engine.catalog_index_is_unique(idx))
		testing.expect_value(t, len(idx.columns), 2)
		engine.free_catalog_entry(idx)

		r, eerr := exec.exec_statement(&s, "SELECT n FROM t WHERE a = 'u' AND b = '2';")
		testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
		testing.expect_value(t, len(r.rows), 1)
		testing.expect_value(t, r.rows[0][0], "2")
		exec.free_error(eerr)
		exec.free_result(r)

		rdup, edup := exec.exec_statement(&s, "INSERT INTO t VALUES ('u', '1', 99);")
		testing.expect(t, exec.has_error(edup))
		testing.expect_value(t, edup.code, exec.Exec_Error_Code.Constraint)
		exec.free_error(edup)
		exec.free_result(rdup)
	}
}

@(test)
test_composite_pk_never_aliases_rowid :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	// Two INTEGER PRIMARY KEY columns → composite unique index, not IPK.
	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (a INTEGER PRIMARY KEY, b INTEGER PRIMARY KEY, n TEXT);" +
		"INSERT INTO t VALUES (1, 1, 'a'), (1, 2, 'b');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	idx, ierr := engine.catalog_get_index_entry(&e, "strix_autoindex_t_1")
	testing.expect(t, engine.ok(ierr))
	testing.expect(t, engine.catalog_index_is_unique(idx))
	testing.expect_value(t, len(idx.columns), 2)
	engine.free_catalog_entry(idx)

	// NULL in a PK column fails (no IPK auto-allocate).
	rn, en := exec.exec_statement(&s, "INSERT INTO t VALUES (NULL, 3, 'c');")
	testing.expect(t, exec.has_error(en))
	testing.expect_value(t, en.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(en)
	exec.free_result(rn)

	rdup, edup := exec.exec_statement(&s, "INSERT INTO t VALUES (1, 1, 'x');")
	testing.expect(t, exec.has_error(edup))
	testing.expect_value(t, edup.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(edup)
	exec.free_result(rdup)
}

@(test)
test_composite_pk_schema_sql :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_statement(&s, "CREATE TABLE t (a TEXT, b TEXT, PRIMARY KEY (a, b));")
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	text, serr := exec.schema_sql(&s, "t")
	testing.expectf(t, !exec.has_error(serr), "%s", serr.message)
	defer exec.free_error(serr)
	defer delete(text)
	testing.expect(t, strings.contains(text, "PRIMARY KEY (a, b)"))
	testing.expect(t, !strings.contains(text, "strix_autoindex_"))
}

@(test)
test_multi_column_table_unique :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (a TEXT, b TEXT, UNIQUE (a, b));" +
		"INSERT INTO t VALUES ('x', '1'), ('x', '2');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	rdup, edup := exec.exec_statement(&s, "INSERT INTO t VALUES ('x', '1');")
	testing.expect(t, exec.has_error(edup))
	testing.expect_value(t, edup.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(edup)
	exec.free_result(rdup)

	text, serr := exec.schema_sql(&s, "t")
	testing.expectf(t, !exec.has_error(serr), "%s", serr.message)
	defer exec.free_error(serr)
	defer delete(text)
	testing.expect(t, strings.contains(text, "CREATE UNIQUE INDEX strix_autoindex_t_1 ON t (a, b);"))
}
