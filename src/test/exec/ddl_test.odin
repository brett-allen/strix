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
	cols, err := exec.bind_create_table_columns(sql.Create_Table_Stmt{name = "t", elements = nil})
	testing.expect(t, exec.has_error(err))
	testing.expect_value(t, err.code, exec.Exec_Error_Code.Invalid_Schema)
	testing.expect(t, cols == nil)
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
}

@(test)
test_bind_rejects_unsupported_column_constraints :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	cases := []string{
		"CREATE TABLE t (a INT UNIQUE);",
		"CREATE TABLE t (a INT DEFAULT 1);",
		"CREATE TABLE t (a INT CHECK (a > 0));",
		"CREATE TABLE t (a INT REFERENCES other(a));",
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
test_bind_rejects_unsupported_table_constraints :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	cases := []string{
		"CREATE TABLE t (a INT, UNIQUE (a));",
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
