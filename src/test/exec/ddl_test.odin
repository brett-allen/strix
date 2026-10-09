package exec_tests

import "core:testing"
import engine "../../engine"
import exec "../../exec"
import sql "../../sql"

@(test)
test_create_preserves_type_names_and_table_pk :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	s := exec.session_adopt(&e)
	r, eerr := exec.exec_statement(
		&s,
		"CREATE TABLE t (id INTEGER, name VARCHAR(32), PRIMARY KEY (id));",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	exec.free_error(eerr)
	exec.free_result(r)

	entry, gerr := engine.catalog_get_table_entry(&e, "t")
	testing.expect(t, engine.ok(gerr))
	defer engine.free_catalog_entry(entry)
	testing.expect_value(t, len(entry.columns), 2)
	testing.expect_value(t, entry.columns[0].type_name, "INTEGER")
	testing.expect(t, .Primary_Key in entry.columns[0].flags)
	testing.expect_value(t, entry.columns[1].type_name, "VARCHAR(32)")
}

@(test)
test_bind_rejects_empty_columns :: proc(t: ^testing.T) {
	cols, uniq, pk, err := exec.bind_create_table_columns(sql.Create_Table_Stmt{name = "t", elements = nil})
	testing.expect(t, exec.has_error(err))
	testing.expect_value(t, err.code, exec.Exec_Error_Code.Invalid_Schema)
	testing.expect(t, cols == nil)
	testing.expect(t, uniq == nil)
	testing.expect(t, pk == nil)
	exec.free_error(err)
}

@(test)
test_bind_rejects_duplicate_column_names :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r, eerr := exec.exec_statement(&s, "CREATE TABLE t (a INT, a TEXT);")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Invalid_Schema)
	exec.free_error(eerr)
	exec.free_result(r)

	// Case-only duplicates are also rejected (unquoted identifiers fold).
	r2, e2 := exec.exec_statement(&s, "CREATE TABLE t (a INT, A INT);")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Invalid_Schema)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_identifier_case_fold_create_insert_select_update :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (Id INT PRIMARY KEY, Name TEXT);" +
		"INSERT INTO t (id, name) VALUES (1, 'a');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(&s, "SELECT ID, NAME FROM t WHERE id = 1;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "1")
	testing.expect_value(t, r.rows[0][1], "a")
	exec.free_error(eerr)
	exec.free_result(r)

	ru, eu := exec.exec_statement(&s, "UPDATE t SET name = 'b' WHERE ID = 1;")
	testing.expectf(t, !exec.has_error(eu), "%s", eu.message)
	testing.expect_value(t, ru.rows_affected, 1)
	exec.free_error(eu)
	exec.free_result(ru)

	r2, e2 := exec.exec_statement(&s, "SELECT Name FROM t WHERE Id = 1;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, r2.rows[0][0], "b")
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_bind_rejects_unsupported_column_constraints :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	cases := []string{
		"CREATE TABLE t (a INT CHECK (a > 0));",
		"CREATE TABLE t (a INT REFERENCES other(a));",
		"CREATE TABLE t (a INT DEFAULT (a + 1));",
	}
	for sql_text in cases {
		r, eerr := exec.exec_statement(&s, sql_text)
		testing.expectf(t, exec.has_error(eerr), "expected error for %s", sql_text)
		testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
		exec.free_error(eerr)
		exec.free_result(r)
	}
}

@(test)
test_create_accepts_literal_default :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r, eerr := exec.exec_statement(&s, "CREATE TABLE t (a INT DEFAULT 42, b TEXT DEFAULT 'x');")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	exec.free_error(eerr)
	exec.free_result(r)

	entry, gerr := engine.catalog_get_table_entry(&e, "t")
	testing.expect(t, engine.ok(gerr))
	defer engine.free_catalog_entry(entry)
	testing.expect(t, .Has_Default in entry.columns[0].flags)
	testing.expect_value(t, entry.columns[0].default_kind, engine.Catalog_Default_Kind.Integer)
	testing.expect_value(t, entry.columns[0].default_i, i64(42))
	testing.expect(t, .Has_Default in entry.columns[1].flags)
	testing.expect_value(t, entry.columns[1].default_kind, engine.Catalog_Default_Kind.Text)
	testing.expect_value(t, entry.columns[1].default_bytes, "x")
}

@(test)
test_bind_rejects_unsupported_table_constraints :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	cases := []string{
		"CREATE TABLE t (a INT, CHECK (a > 0));",
		"CREATE TABLE t (a INT, FOREIGN KEY (a) REFERENCES other(a));",
	}
	for sql_text in cases {
		r, eerr := exec.exec_statement(&s, sql_text)
		testing.expectf(t, exec.has_error(eerr), "expected error for %s", sql_text)
		testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
		exec.free_error(eerr)
		exec.free_result(r)
	}
}

@(test)
test_bind_rejects_table_pk_unknown_column :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r, eerr := exec.exec_statement(&s, "CREATE TABLE t (a INT, PRIMARY KEY (missing));")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Invalid_Schema)
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_create_accepts_composite_primary_key :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r, eerr := exec.exec_statement(&s, "CREATE TABLE c (a INTEGER, b INTEGER, PRIMARY KEY (a, b));")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	exec.free_error(eerr)
	exec.free_result(r)

	entry, gerr := engine.catalog_get_table_entry(&e, "c")
	testing.expect(t, engine.ok(gerr))
	testing.expect(t, .Primary_Key in entry.columns[0].flags)
	testing.expect(t, .Primary_Key in entry.columns[1].flags)
	testing.expect(t, .Not_Null in entry.columns[0].flags)
	testing.expect(t, .Not_Null in entry.columns[1].flags)
	engine.free_catalog_entry(entry)

	idx, ierr := engine.catalog_get_index_entry(&e, "strix_autoindex_c_1")
	testing.expect(t, engine.ok(ierr))
	testing.expect(t, engine.catalog_index_is_unique(idx))
	testing.expect_value(t, len(idx.columns), 2)
	engine.free_catalog_entry(idx)
}

@(test)
test_create_rejects_conflicting_primary_key :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	// Column IPK + different composite table PK.
	r, eerr := exec.exec_statement(
		&s,
		"CREATE TABLE c (id INTEGER PRIMARY KEY, a TEXT, b TEXT, PRIMARY KEY (a, b));",
	)
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Invalid_Schema)
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_create_accepts_non_integer_primary_key :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	cases := []string{
		"CREATE TABLE t_text (id TEXT PRIMARY KEY);",
		"CREATE TABLE t_real (id REAL PRIMARY KEY);",
		"CREATE TABLE t_vc (id VARCHAR(32) PRIMARY KEY);",
		"CREATE TABLE t_tbl (id TEXT, PRIMARY KEY (id));",
	}
	for sql_text in cases {
		r, eerr := exec.exec_statement(&s, sql_text)
		testing.expectf(t, !exec.has_error(eerr), "%s → %s", sql_text, eerr.message)
		exec.free_error(eerr)
		exec.free_result(r)
	}

	entry, gerr := engine.catalog_get_table_entry(&e, "t_text")
	testing.expect(t, engine.ok(gerr))
	testing.expect(t, .Primary_Key in entry.columns[0].flags)
	testing.expect(t, .Not_Null in entry.columns[0].flags)
	engine.free_catalog_entry(entry)

	idx, ierr := engine.catalog_get_index_entry(&e, "strix_autoindex_t_text_1")
	testing.expect(t, engine.ok(ierr))
	testing.expect(t, engine.catalog_index_is_unique(idx))
	engine.free_catalog_entry(idx)
}

@(test)
test_column_from_def_pk_not_null :: proc(t: ^testing.T) {
	col := sql.Column_Def{
		name      = "id",
		type_name = "INTEGER",
		constraints = []sql.Column_Constraint{
			{kind = .Primary_Key},
			{kind = .Not_Null},
		},
	}
	got, err := exec.column_from_def(col)
	testing.expect(t, !exec.has_error(err))
	testing.expect_value(t, got.name, "id")
	testing.expect_value(t, got.type_name, "INTEGER")
	testing.expect(t, .Primary_Key in got.flags)
	testing.expect(t, .Not_Null in got.flags)
	exec.free_error(err)
}

@(test)
test_parse_error_surfaces_as_exec_parse :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r, eerr := exec.exec_script(&s, "CREATE TABLE ;;;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Parse)
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_multi_statement_create_drop_script :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r, eerr := exec.exec_script(&s, "CREATE TABLE a (x INT); CREATE TABLE b (y TEXT); DROP TABLE a;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.kind, exec.Result_Kind.Ok)
	exec.free_error(eerr)
	exec.free_result(r)

	_, gerr_a := engine.catalog_get_table_entry(&e, "a")
	testing.expect_value(t, gerr_a, engine.Engine_Error.Not_Found)
	entry_b, gerr_b := engine.catalog_get_table_entry(&e, "b")
	testing.expect(t, engine.ok(gerr_b))
	testing.expect_value(t, entry_b.columns[0].name, "y")
	engine.free_catalog_entry(entry_b)
}

@(test)
test_script_stops_on_first_error :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r, eerr := exec.exec_script(&s, "CREATE TABLE a (x INT); CREATE TABLE a (y INT); CREATE TABLE c (z INT);")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Table_Exists)
	exec.free_error(eerr)
	exec.free_result(r)

	_, gerr_c := engine.catalog_get_table_entry(&e, "c")
	testing.expect_value(t, gerr_c, engine.Engine_Error.Not_Found)
}
