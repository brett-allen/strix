package exec_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import engine "../../engine"
import exec "../../exec"

@(test)
test_list_tables_lexical_and_empty :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	names0, e0 := exec.list_tables(&s)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	testing.expect_value(t, len(names0), 0)
	exec.free_error(e0)
	exec.free_table_names(names0)

	r, eerr := exec.exec_script(
		&s,
		"CREATE TABLE zebra (id INTEGER PRIMARY KEY);" +
		"CREATE TABLE apple (id INTEGER PRIMARY KEY);" +
		"CREATE TABLE mango (n TEXT);",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	exec.free_error(eerr)
	exec.free_result(r)

	names, e1 := exec.list_tables(&s)
	testing.expectf(t, !exec.has_error(e1), "%s", e1.message)
	defer exec.free_error(e1)
	defer exec.free_table_names(names)
	testing.expect_value(t, len(names), 3)
	testing.expect_value(t, names[0], "apple")
	testing.expect_value(t, names[1], "mango")
	testing.expect_value(t, names[2], "zebra")
}

@(test)
test_schema_sql_one_and_all_with_index :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r, eerr := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT 'x', n INT DEFAULT 42, blobcol BLOB DEFAULT X'ABCD');" +
		"CREATE INDEX t_by_name ON t (name DESC);" +
		"CREATE TABLE u (x TEXT);",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	exec.free_error(eerr)
	exec.free_result(r)

	one, oerr := exec.schema_sql(&s, "t")
	testing.expectf(t, !exec.has_error(oerr), "%s", oerr.message)
	defer exec.free_error(oerr)
	defer delete(one)
	testing.expect(t, strings.contains(one, "CREATE TABLE t ("))
	testing.expect(t, strings.contains(one, "id INTEGER PRIMARY KEY"))
	testing.expect(t, strings.contains(one, "name TEXT NOT NULL DEFAULT 'x'"))
	testing.expect(t, strings.contains(one, "n INT DEFAULT 42"))
	testing.expect(t, strings.contains(one, "blobcol BLOB DEFAULT X'ABCD'"))
	testing.expect(t, strings.contains(one, "CREATE INDEX t_by_name ON t (name DESC);"))
	testing.expect(t, !strings.contains(one, "CREATE TABLE u"))

	all, aerr := exec.schema_sql(&s, "")
	testing.expectf(t, !exec.has_error(aerr), "%s", aerr.message)
	defer exec.free_error(aerr)
	defer delete(all)
	testing.expect(t, strings.contains(all, "CREATE TABLE t ("))
	testing.expect(t, strings.contains(all, "CREATE TABLE u ("))
	// lexical: t before u
	ti := strings.index(all, "CREATE TABLE t")
	ui := strings.index(all, "CREATE TABLE u")
	testing.expect(t, ti >= 0 && ui > ti)
}

@(test)
test_schema_sql_unknown_table :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	text, eerr := exec.schema_sql(&s, "missing")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unknown_Table)
	testing.expect(t, strings.contains(eerr.message, "missing"))
	testing.expect_value(t, text, "")
	exec.free_error(eerr)
}

@(test)
test_list_tables_after_drop :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c2-list-drop-%d.strix", os.get_pid())
	defer os.remove(path)
	e, err := engine.engine_create(path)
	testing.expect(t, engine.ok(err))
	engine.engine_close(&e)

	session, serr := exec.session_open(path)
	testing.expect(t, !exec.has_error(serr))
	defer exec.free_error(serr)
	defer exec.session_close(&session)

	r, eerr := exec.exec_script(
		&session,
		"CREATE TABLE a (id INTEGER PRIMARY KEY);" +
		"CREATE TABLE b (id INTEGER PRIMARY KEY);" +
		"DROP TABLE a;",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	exec.free_error(eerr)
	exec.free_result(r)

	names, lerr := exec.list_tables(&session)
	testing.expectf(t, !exec.has_error(lerr), "%s", lerr.message)
	defer exec.free_error(lerr)
	defer exec.free_table_names(names)
	testing.expect_value(t, len(names), 1)
	testing.expect_value(t, names[0], "b")
}
