package cli_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import cli "../../cli"
import exec "../../exec"

@(test)
test_shell_tables_and_schema_match_catalog :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c2-shell-schema-%d.strix", os.get_pid())
	defer os.remove(path)

	testing.expect_value(t, cli.init_database(path), 0)

	r, w, perr := os.pipe()
	testing.expect(t, perr == nil)
	old_stdout := os.stdout
	os.stdout = w
	code := cli.shell_run_lines(
		path,
		[]string{
			"CREATE TABLE zebra (id INTEGER PRIMARY KEY);",
			"CREATE TABLE apple (id INTEGER PRIMARY KEY, name TEXT);",
			"CREATE INDEX apple_by_name ON apple (name);",
			"CREATE TABLE mango (n TEXT NOT NULL DEFAULT 'x');",
			".tables",
			".schema",
			".schema apple",
			"DROP TABLE mango;",
			".tables",
			".quit",
		},
	)
	os.close(w)
	os.stdout = old_stdout
	data, rerr := os.read_entire_file_from_file(r, context.allocator)
	os.close(r)
	testing.expect(t, rerr == nil)
	out := string(data)
	defer delete(out)
	testing.expect_value(t, code, 0)

	// Shell-printed meta output (not just exit 0 + re-query via exec).
	testing.expect(t, strings.contains(out, "apple\n"))
	testing.expect(t, strings.contains(out, "mango\n"))
	testing.expect(t, strings.contains(out, "zebra\n"))
	testing.expect(t, strings.contains(out, "CREATE TABLE apple ("))
	testing.expect(t, strings.contains(out, "CREATE INDEX apple_by_name ON apple (name);"))
	testing.expect(t, strings.contains(out, "CREATE TABLE mango ("))
	testing.expect(t, strings.contains(out, "n TEXT NOT NULL DEFAULT 'x'"))
	testing.expect(t, strings.contains(out, "CREATE TABLE zebra ("))
	// Lexical .tables order in the first listing.
	apple_i := strings.index(out, "apple\n")
	mango_i := strings.index(out, "mango\n")
	zebra_i := strings.index(out, "zebra\n")
	testing.expect(t, apple_i >= 0 && mango_i > apple_i && zebra_i > mango_i)

	session, err := exec.session_open(path)
	testing.expect(t, !exec.has_error(err))
	defer exec.free_error(err)
	defer exec.session_close(&session)

	names, lerr := exec.list_tables(&session)
	testing.expectf(t, !exec.has_error(lerr), "%s", lerr.message)
	defer exec.free_error(lerr)
	defer exec.free_table_names(names)
	testing.expect_value(t, len(names), 2)
	testing.expect_value(t, names[0], "apple")
	testing.expect_value(t, names[1], "zebra")

	schema, serr := exec.schema_sql(&session, "")
	testing.expectf(t, !exec.has_error(serr), "%s", serr.message)
	defer exec.free_error(serr)
	defer delete(schema)
	testing.expect(t, strings.contains(schema, "CREATE TABLE apple ("))
	testing.expect(t, strings.contains(schema, "CREATE INDEX apple_by_name ON apple (name);"))
	testing.expect(t, strings.contains(schema, "CREATE TABLE zebra ("))
	testing.expect(t, !strings.contains(schema, "CREATE TABLE mango"))
}

@(test)
test_shell_schema_unknown_table_error :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c2-schema-missing-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	testing.expect_value(t, cli.shell_open_path(&s, path), 0)

	cmd := cli.meta_parse(".schema nosuch")
	testing.expect_value(t, cmd.kind, cli.Meta_Kind.Schema)
	testing.expect(t, !cli.meta_dispatch(&s, cmd))
	testing.expect(t, !s.quit)

	// Durable path: helper reports Unknown_Table
	text, eerr := exec.schema_sql(&s.session, "nosuch")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unknown_Table)
	testing.expect_value(t, text, "")
	exec.free_error(eerr)

	testing.expect(t, cli.shell_process_line(&s, ".quit"))
}

@(test)
test_shell_tables_usage_rejects_args :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c2-tables-usage-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	testing.expect_value(t, cli.shell_open_path(&s, path), 0)

	cmd := cli.meta_parse(".tables extra")
	testing.expect(t, !cli.meta_dispatch(&s, cmd))
	testing.expect(t, !s.quit)
}

@(test)
test_shell_schema_usage_rejects_extra_args :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-c2-schema-usage-%d.strix", os.get_pid())
	defer os.remove(path)
	testing.expect_value(t, cli.init_database(path), 0)

	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	testing.expect_value(t, cli.shell_open_path(&s, path), 0)

	cmd := cli.meta_parse(".schema a b")
	testing.expect(t, !cli.meta_dispatch(&s, cmd))
	testing.expect(t, !s.quit)
}
