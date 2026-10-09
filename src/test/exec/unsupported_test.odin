package exec_tests

import "core:testing"
import engine "../../engine"
import exec "../../exec"
import sql "../../sql"

@(test)
test_unsupported_statement_kinds :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	// Need a table for some DML parses
	r0, e0 := exec.exec_statement(&s, "CREATE TABLE t (a INT);")
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)
	exec.free_result(r0)

	cases := []string{
		"SELECT DISTINCT a FROM t;",
		"SELECT * FROM t LEFT JOIN t AS u ON t.a = u.a;", // LEFT OUTER deferred (S6)
		"SELECT * FROM t GROUP BY a;", // SELECT * with GROUP BY rejected (strict)
		"ALTER TABLE t ADD COLUMN b INT;",
	}
	for sql_text in cases {
		r, eerr := exec.exec_statement(&s, sql_text)
		testing.expectf(t, exec.has_error(eerr), "expected unsupported for %s", sql_text)
		testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
		testing.expect(t, len(eerr.message) > 0)
		exec.free_error(eerr)
		exec.free_result(r)
	}
}

@(test)
test_statement_kind_labels :: proc(t: ^testing.T) {
	testing.expect_value(t, exec.statement_kind_label(.Create_Table), "CREATE TABLE")
	testing.expect_value(t, exec.statement_kind_label(.Drop_Table), "DROP TABLE")
	testing.expect_value(t, exec.statement_kind_label(.Create_Index), "CREATE INDEX")
	testing.expect_value(t, exec.statement_kind_label(.Drop_Index), "DROP INDEX")
	testing.expect_value(t, exec.statement_kind_label(.Alter_Table), "ALTER TABLE")
	testing.expect_value(t, exec.statement_kind_label(.Select), "SELECT")
	testing.expect_value(t, exec.statement_kind_label(.Insert), "INSERT")
	testing.expect_value(t, exec.statement_kind_label(.Update), "UPDATE")
	testing.expect_value(t, exec.statement_kind_label(.Delete), "DELETE")
	testing.expect_value(t, exec.statement_kind_label(.Begin), "BEGIN")
	testing.expect_value(t, exec.statement_kind_label(.Commit), "COMMIT")
	testing.expect_value(t, exec.statement_kind_label(.Rollback), "ROLLBACK")
}

@(test)
test_exec_statement_ast_create_drop_direct :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	stmt, perr := sql.parse_statement("CREATE TABLE z (n TEXT NOT NULL);")
	testing.expect(t, !sql.has_error(perr))
	sql.free_error(perr)
	defer sql.free_statement(stmt)

	r, eerr := exec.exec_statement_ast(&s, stmt)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.kind, exec.Result_Kind.Ok)
	exec.free_error(eerr)
	exec.free_result(r)

	drop, dperr := sql.parse_statement("DROP TABLE z;")
	testing.expect(t, !sql.has_error(dperr))
	sql.free_error(dperr)
	defer sql.free_statement(drop)

	r2, eerr2 := exec.exec_statement_ast(&s, drop)
	testing.expect(t, !exec.has_error(eerr2))
	exec.free_error(eerr2)
	exec.free_result(r2)

	_, gerr := engine.catalog_get_table_entry(&e, "z")
	testing.expect_value(t, gerr, engine.Engine_Error.Not_Found)
}
