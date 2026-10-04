package exec_tests

import "core:testing"
import engine "../../engine"
import exec "../../exec"

@(test)
test_table_and_index_names_are_case_sensitive :: proc(t: ^testing.T) {
	// Policy lock: table/index catalog keys are case-sensitive. Column bind still
	// folds (covered elsewhere). Docs must not claim fold "everywhere".
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE Users (Id INTEGER PRIMARY KEY, Name TEXT);" +
		"CREATE INDEX Idx_Name ON Users (Name);" +
		"INSERT INTO Users (Id, Name) VALUES (1, 'a');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	// Wrong table case → unknown table
	r1, e1 := exec.exec_statement(&s, "SELECT Id FROM users;")
	testing.expect(t, exec.has_error(e1))
	testing.expect_value(t, e1.code, exec.Exec_Error_Code.Unknown_Table)
	exec.free_error(e1)
	exec.free_result(r1)

	// Column fold still works with exact table name
	r2, e2 := exec.exec_statement(&s, "SELECT id, name FROM Users;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][1], "a")
	exec.free_error(e2)
	exec.free_result(r2)

	// Wrong index case → unknown index
	r3, e3 := exec.exec_statement(&s, "DROP INDEX idx_name;")
	testing.expect(t, exec.has_error(e3))
	testing.expect_value(t, e3.code, exec.Exec_Error_Code.Unknown_Index)
	exec.free_error(e3)
	exec.free_result(r3)

	r4, e4 := exec.exec_statement(&s, "DROP INDEX Idx_Name;")
	testing.expectf(t, !exec.has_error(e4), "%s", e4.message)
	exec.free_error(e4)
	exec.free_result(r4)
}
