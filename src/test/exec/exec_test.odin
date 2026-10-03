package exec_tests

import "core:fmt"
import "core:os"
import "core:testing"
import engine "../../engine"
import exec "../../exec"

@(test)
test_create_table_reopen_shows_columns :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-e1-create-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)

		s := exec.session_adopt(&e)
		result, eerr := exec.exec_script(
			&s,
			"CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);",
		)
		testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
		testing.expect_value(t, result.kind, exec.Result_Kind.Ok)
		exec.free_error(eerr)
		exec.free_result(result)
	}

	{
		e, err := engine.engine_open(path)
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)

		entry, gerr := engine.catalog_get_table_entry(&e, "users")
		testing.expect(t, engine.ok(gerr))
		defer engine.free_catalog_entry(entry)

		testing.expect_value(t, entry.version, engine.CATALOG_ROW_VERSION_V2)
		testing.expect_value(t, entry.kind, engine.Catalog_Kind.Table)
		testing.expect_value(t, entry.next_rowid, u64(1))
		testing.expect_value(t, len(entry.columns), 2)
		testing.expect_value(t, entry.columns[0].name, "id")
		testing.expect_value(t, entry.columns[0].type_name, "INTEGER")
		testing.expect(t, .Primary_Key in entry.columns[0].flags)
		testing.expect_value(t, entry.columns[1].name, "name")
		testing.expect_value(t, entry.columns[1].type_name, "TEXT")
		testing.expect(t, .Not_Null in entry.columns[1].flags)
	}
}

@(test)
test_create_table_if_not_exists :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	s := exec.session_adopt(&e)
	r1, e1 := exec.exec_script(&s, "CREATE TABLE t (a INT);")
	testing.expect(t, !exec.has_error(e1))
	exec.free_error(e1)
	exec.free_result(r1)

	r2, e2 := exec.exec_script(&s, "CREATE TABLE t (a INT);")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Table_Exists)
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_script(&s, "CREATE TABLE IF NOT EXISTS t (a INT);")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, r3.kind, exec.Result_Kind.Ok)
	exec.free_error(e3)
	exec.free_result(r3)

	entry, gerr := engine.catalog_get_table_entry(&e, "t")
	testing.expect(t, engine.ok(gerr))
	defer engine.free_catalog_entry(entry)
	testing.expect_value(t, len(entry.columns), 1)
	testing.expect_value(t, entry.columns[0].name, "a")
}

@(test)
test_drop_table_removes_catalog_entry :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-e1-drop-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		s := exec.session_adopt(&e)
		r, eerr := exec.exec_script(&s, "CREATE TABLE t (x TEXT); DROP TABLE t;")
		testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
		exec.free_error(eerr)
		exec.free_result(r)
		engine.engine_close(&e)
	}

	{
		e, err := engine.engine_open(path)
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)
		_, gerr := engine.catalog_get_table_entry(&e, "t")
		testing.expect_value(t, gerr, engine.Engine_Error.Not_Found)
	}
}

@(test)
test_drop_table_if_exists :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	s := exec.session_adopt(&e)
	r0, e0 := exec.exec_script(&s, "DROP TABLE IF EXISTS missing;")
	testing.expect(t, !exec.has_error(e0))
	testing.expect_value(t, r0.kind, exec.Result_Kind.Ok)
	exec.free_error(e0)
	exec.free_result(r0)

	r1, e1 := exec.exec_script(&s, "DROP TABLE missing;")
	testing.expect(t, exec.has_error(e1))
	testing.expect_value(t, e1.code, exec.Exec_Error_Code.Unknown_Table)
	exec.free_error(e1)
	exec.free_result(r1)
}

@(test)
test_drop_table_rejects_when_indexes_exist :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	s := exec.session_adopt(&e)
	r1, e1 := exec.exec_script(&s, "CREATE TABLE t (a INT);")
	testing.expect(t, !exec.has_error(e1))
	exec.free_error(e1)
	exec.free_result(r1)

	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	_, ierr := engine.catalog_register_index(&e, "t_a", "t")
	testing.expect(t, engine.ok(ierr))
	testing.expect(t, engine.ok(engine.txn_commit(&e)))

	has, herr := engine.catalog_table_has_indexes(&e, "t")
	testing.expect(t, engine.ok(herr))
	testing.expect(t, has)

	r2, e2 := exec.exec_script(&s, "DROP TABLE t;")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Has_Indexes)
	exec.free_error(e2)
	exec.free_result(r2)

	// Table must still be present after rejected drop.
	entry, gerr := engine.catalog_get_table_entry(&e, "t")
	testing.expect(t, engine.ok(gerr))
	engine.free_catalog_entry(entry)
}
