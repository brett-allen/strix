package sql_tests

import "core:os"
import "core:strings"
import "core:testing"
import sql "../../sql"

@(test)
test_insert_values :: proc(t: ^testing.T) {
	src := "INSERT INTO users (id, name) VALUES (1, 'a'), (2, 'b')"
	stmt, err := sql.parse_statement(src)
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	testing.expect_value(t, stmt.kind, sql.Statement_Kind.Insert)
	ins := stmt.data.(sql.Insert_Stmt)
	testing.expect_value(t, ins.table, "users")
	testing.expect_value(t, ins.conflict, sql.Insert_Conflict.None)
	testing.expect_value(t, ins.source, sql.Insert_Source.Values)
	testing.expect_value(t, len(ins.columns), 2)
	testing.expect_value(t, len(ins.rows), 2)
	testing.expect_value(t, len(ins.rows[0]), 2)
}

@(test)
test_insert_or_replace_ignore :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("INSERT OR REPLACE INTO t VALUES (1)")
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, stmt.data.(sql.Insert_Stmt).conflict, sql.Insert_Conflict.Replace)

	stmt2, err2 := sql.parse_statement("INSERT OR IGNORE INTO t (x) VALUES (0)")
	defer sql.free_error(err2)
	defer sql.free_statement(stmt2)
	testing.expect(t, !sql.has_error(err2))
	testing.expect_value(t, stmt2.data.(sql.Insert_Stmt).conflict, sql.Insert_Conflict.Ignore)
}

@(test)
test_insert_select :: proc(t: ^testing.T) {
	src := "INSERT INTO dest (id) SELECT id FROM src WHERE id > 0"
	stmt, err := sql.parse_statement(src)
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	ins := stmt.data.(sql.Insert_Stmt)
	testing.expect_value(t, ins.source, sql.Insert_Source.Select)
	testing.expect_value(t, ins.select.from.table, "src")
	testing.expect(t, ins.select.where_expr != nil)
}

@(test)
test_update_set_where :: proc(t: ^testing.T) {
	src := "UPDATE users SET name = 'x', score = score + 1 WHERE id = 1"
	stmt, err := sql.parse_statement(src)
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	upd := stmt.data.(sql.Update_Stmt)
	testing.expect_value(t, upd.table, "users")
	testing.expect_value(t, len(upd.sets), 2)
	testing.expect_value(t, upd.sets[0].column, "name")
	testing.expect(t, upd.where_expr != nil)
}

@(test)
test_delete_from :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("DELETE FROM t WHERE id < 10")
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))
	del := stmt.data.(sql.Delete_Stmt)
	testing.expect_value(t, del.table, "t")
	testing.expect(t, del.where_expr != nil)

	stmt2, err2 := sql.parse_statement("DELETE FROM t")
	defer sql.free_error(err2)
	defer sql.free_statement(stmt2)
	testing.expect(t, !sql.has_error(err2))
	testing.expect(t, stmt2.data.(sql.Delete_Stmt).where_expr == nil)
}

@(test)
test_dml_print_snapshots :: proc(t: ^testing.T) {
	cases := []struct {
		src:  string,
		want: string,
	}{
		{"INSERT INTO t (a) VALUES (1)", "INSERT INTO t (a) VALUES (1)"},
		{"INSERT OR IGNORE INTO t VALUES (2)", "INSERT OR IGNORE INTO t VALUES (2)"},
		{"UPDATE t SET a = 1 WHERE a = 0", "UPDATE t SET a = 1 WHERE (a = 0)"},
		{"DELETE FROM t WHERE id = 1", "DELETE FROM t WHERE (id = 1)"},
		{
			"INSERT INTO t SELECT * FROM s",
			"INSERT INTO t SELECT * FROM s",
		},
	}
	for c in cases {
		stmt, err := sql.parse_statement(c.src)
		if sql.has_error(err) {
			testing.expectf(t, false, "%q: %s", c.src, err.message)
			sql.free_error(err)
			continue
		}
		defer sql.free_statement(stmt)
		got := sql.print_statement(stmt)
		defer delete(got)
		testing.expectf(t, got == c.want, "\nsrc:  %s\ngot:  %s\nwant: %s", c.src, got, c.want)
	}
}

@(test)
test_crud_script_fixture :: proc(t: ^testing.T) {
	path := "src/test/sql/fixtures/crud.sql"
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	testing.expectf(t, read_err == os.ERROR_NONE, "read fixture %s: %v", path, read_err)
	defer delete(data)

	script, err := sql.parse_script(string(data))
	defer sql.free_error(err)
	defer sql.free_script(script)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	testing.expect_value(t, len(script.statements), 5)

	dump := sql.print_script(script)
	defer delete(dump)
	testing.expect(t, strings.contains(dump, "CREATE TABLE"))
	testing.expect(t, strings.contains(dump, "INSERT INTO items"))
	testing.expect(t, strings.contains(dump, "UPDATE items SET"))
	testing.expect(t, strings.contains(dump, "DELETE FROM items"))
	testing.expect(t, strings.contains(dump, "SELECT"))
}

@(test)
test_insert_rejects_on_conflict :: proc(t: ^testing.T) {
	_, err := sql.parse_statement("INSERT INTO t VALUES (1) ON CONFLICT DO NOTHING")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect(t, strings.contains(err.message, "ON CONFLICT"))
}

@(test)
test_update_rejects_or_clause :: proc(t: ^testing.T) {
	_, err := sql.parse_statement("UPDATE OR IGNORE t SET a = 1")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
}
