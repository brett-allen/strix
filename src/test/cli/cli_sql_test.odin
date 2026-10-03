package cli_tests

import "core:fmt"
import "core:os"
import "core:testing"
import cli "../../cli"
import engine "../../engine"

@(test)
test_parse_sql_command_args_variants :: proc(t: ^testing.T) {
	a := cli.parse_sql_command_args([]string{"-c", "CREATE TABLE t (a INT);"})
	testing.expect(t, a.ok)
	testing.expect_value(t, a.db_path, cli.DEFAULT_DB_PATH)
	testing.expect_value(t, a.input, cli.Sql_Input_Kind.Command)
	testing.expect_value(t, a.sql_or_file, "CREATE TABLE t (a INT);")

	b := cli.parse_sql_command_args([]string{"demo", "-c", "SELECT 1;"})
	testing.expect(t, b.ok)
	testing.expect_value(t, b.db_path, "demo")
	testing.expect_value(t, b.input, cli.Sql_Input_Kind.Command)
	testing.expect_value(t, b.sql_or_file, "SELECT 1;")

	c := cli.parse_sql_command_args([]string{"-c", "SELECT 1;", "demo"})
	testing.expect(t, c.ok)
	testing.expect_value(t, c.db_path, "demo")
	testing.expect_value(t, c.input, cli.Sql_Input_Kind.Command)

	d := cli.parse_sql_command_args([]string{"demo", "script.sql"})
	testing.expect(t, d.ok)
	testing.expect_value(t, d.db_path, "demo")
	testing.expect_value(t, d.input, cli.Sql_Input_Kind.File)
	testing.expect_value(t, d.sql_or_file, "script.sql")

	e := cli.parse_sql_command_args([]string{"script.sql"})
	testing.expect(t, e.ok)
	testing.expect_value(t, e.db_path, cli.DEFAULT_DB_PATH)
	testing.expect_value(t, e.input, cli.Sql_Input_Kind.File)

	f := cli.parse_sql_command_args([]string{"demo"})
	testing.expect(t, f.ok)
	testing.expect_value(t, f.db_path, "demo")
	testing.expect_value(t, f.input, cli.Sql_Input_Kind.Stdin)

	g := cli.parse_sql_command_args([]string{})
	testing.expect(t, g.ok)
	testing.expect_value(t, g.input, cli.Sql_Input_Kind.Stdin)

	h := cli.parse_sql_command_args([]string{"-c"})
	testing.expect(t, !h.ok)
	testing.expect(t, len(h.err_msg) > 0)

	i := cli.parse_sql_command_args([]string{"--command", "DROP TABLE t;"})
	testing.expect(t, i.ok)
	testing.expect_value(t, i.input, cli.Sql_Input_Kind.Command)
	testing.expect_value(t, i.sql_or_file, "DROP TABLE t;")
}

@(test)
test_run_sql_create_drop_via_session_path :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-e1-cli-sql-%d.strix", os.get_pid())
	defer os.remove(path)

	testing.expect_value(t, cli.init_database(path), 0)
	code := cli.run_sql(path, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);")
	testing.expect_value(t, code, 0)

	e, err := engine.engine_open(path)
	testing.expect(t, engine.ok(err))
	entry, gerr := engine.catalog_get_table_entry(&e, "users")
	testing.expect(t, engine.ok(gerr))
	testing.expect_value(t, len(entry.columns), 2)
	testing.expect_value(t, entry.columns[0].name, "id")
	engine.free_catalog_entry(entry)
	engine.engine_close(&e)

	code2 := cli.run_sql(path, "DROP TABLE users;")
	testing.expect_value(t, code2, 0)

	e2, err2 := engine.engine_open(path)
	testing.expect(t, engine.ok(err2))
	defer engine.engine_close(&e2)
	_, gerr2 := engine.catalog_get_table_entry(&e2, "users")
	testing.expect_value(t, gerr2, engine.Engine_Error.Not_Found)
}

@(test)
test_run_sql_open_failure_and_exec_failure :: proc(t: ^testing.T) {
	missing := fmt.tprintf("/tmp/strix-e1-cli-missing-%d.strix", os.get_pid())
	os.remove(missing)
	testing.expect(t, cli.run_sql(missing, "CREATE TABLE t (a INT);") != 0)

	path := fmt.tprintf("/tmp/strix-e1-cli-bad-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)
	testing.expect(t, cli.run_sql(path, "INSERT INTO t VALUES (1);") != 0)
}

@(test)
test_run_dispatches_sql_subcommand :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-e1-cli-run-%d", os.get_pid())
	strix_path := fmt.tprintf("%s.strix", path)
	defer os.remove(strix_path)

	testing.expect_value(t, cli.run([]string{"init", path}), 0)
	code := cli.run([]string{"sql", path, "-c", "CREATE TABLE t (a INT);"})
	testing.expect_value(t, code, 0)

	e, err := engine.engine_open(strix_path)
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	entry, gerr := engine.catalog_get_table_entry(&e, "t")
	testing.expect(t, engine.ok(gerr))
	testing.expect_value(t, entry.columns[0].name, "a")
	engine.free_catalog_entry(entry)
}

@(test)
test_run_sql_command_missing_c_arg :: proc(t: ^testing.T) {
	testing.expect_value(t, cli.run_sql_command([]string{"-c"}), 1)
}

@(test)
test_read_file_or_stdin_file :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-e1-sqlfile-%d.sql", os.get_pid())
	defer os.remove(path)
	werr := os.write_entire_file(path, transmute([]byte)string("CREATE TABLE t (a INT);\n"))
	testing.expect(t, werr == nil)

	data, ok := cli.read_file_or_stdin(path)
	testing.expect(t, ok)
	defer delete(data)
	testing.expect(t, len(data) > 0)

	_, bad := cli.read_file_or_stdin(fmt.tprintf("/tmp/strix-e1-no-such-%d.sql", os.get_pid()))
	testing.expect(t, !bad)
}
