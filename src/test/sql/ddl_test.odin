package sql_tests

import "core:os"
import "core:strings"
import "core:testing"
import sql "../../sql"

@(test)
test_create_table_basic :: proc(t: ^testing.T) {
	src := "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY NOT NULL, name TEXT UNIQUE)"
	stmt, err := sql.parse_statement(src)
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	testing.expect_value(t, stmt.kind, sql.Statement_Kind.Create_Table)
	ct := stmt.data.(sql.Create_Table_Stmt)
	testing.expect_value(t, ct.name, "t")
	testing.expect_value(t, ct.if_not_exists, true)
	testing.expect_value(t, len(ct.elements), 2)
	testing.expect_value(t, ct.elements[0].kind, sql.Table_Element_Kind.Column)
	testing.expect_value(t, ct.elements[0].column.name, "id")
	testing.expect_value(t, ct.elements[0].column.type_name, "INTEGER")
	testing.expect_value(t, len(ct.elements[0].column.constraints), 2)
}

@(test)
test_create_table_table_constraints :: proc(t: ^testing.T) {
	src := "CREATE TABLE t (a INT, b INT, PRIMARY KEY (a, b), UNIQUE (b))"
	stmt, err := sql.parse_statement(src)
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))
	ct := stmt.data.(sql.Create_Table_Stmt)
	testing.expect_value(t, len(ct.elements), 4)
	testing.expect_value(t, ct.elements[2].kind, sql.Table_Element_Kind.Table_Constraint)
	testing.expect_value(t, ct.elements[2].table_constraint.kind, sql.Table_Constraint_Kind.Primary_Key)
	testing.expect_value(t, len(ct.elements[2].table_constraint.columns), 2)
	testing.expect_value(t, ct.elements[3].table_constraint.kind, sql.Table_Constraint_Kind.Unique)
}

@(test)
test_create_table_preserves_element_order :: proc(t: ^testing.T) {
	src := "CREATE TABLE t (PRIMARY KEY (a), a INT)"
	stmt, err := sql.parse_statement(src)
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	ct := stmt.data.(sql.Create_Table_Stmt)
	testing.expect_value(t, len(ct.elements), 2)
	testing.expect_value(t, ct.elements[0].kind, sql.Table_Element_Kind.Table_Constraint)
	testing.expect_value(t, ct.elements[0].table_constraint.kind, sql.Table_Constraint_Kind.Primary_Key)
	testing.expect_value(t, ct.elements[1].kind, sql.Table_Element_Kind.Column)
	testing.expect_value(t, ct.elements[1].column.name, "a")

	dump := sql.print_statement(stmt)
	defer delete(dump)
	pk := strings.index(dump, "PRIMARY KEY")
	col := strings.index(dump, "a INT")
	testing.expect(t, pk >= 0 && col >= 0 && pk < col)
}

@(test)
test_create_table_default_expr :: proc(t: ^testing.T) {
	src := "CREATE TABLE t (x INT DEFAULT 1 + 2)"
	stmt, err := sql.parse_statement(src)
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))
	col := stmt.data.(sql.Create_Table_Stmt).elements[0].column
	testing.expect_value(t, col.constraints[0].kind, sql.Column_Constraint_Kind.Default)
	testing.expect_value(t, col.constraints[0].default_expr.kind, sql.Expr_Kind.Binary)
}

@(test)
test_drop_table_and_index :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("DROP TABLE IF EXISTS foo")
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))
	dt := stmt.data.(sql.Drop_Table_Stmt)
	testing.expect_value(t, dt.if_exists, true)
	testing.expect_value(t, dt.name, "foo")

	stmt2, err2 := sql.parse_statement("DROP INDEX IF EXISTS idx")
	defer sql.free_error(err2)
	defer sql.free_statement(stmt2)
	testing.expect(t, !sql.has_error(err2))
	di := stmt2.data.(sql.Drop_Index_Stmt)
	testing.expect_value(t, di.if_exists, true)
	testing.expect_value(t, di.name, "idx")
}

@(test)
test_create_index :: proc(t: ^testing.T) {
	src := "CREATE INDEX IF NOT EXISTS idx ON users (name DESC, id ASC)"
	stmt, err := sql.parse_statement(src)
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))
	ci := stmt.data.(sql.Create_Index_Stmt)
	testing.expect_value(t, ci.if_not_exists, true)
	testing.expect_value(t, ci.table_name, "users")
	testing.expect_value(t, len(ci.columns), 2)
	testing.expect_value(t, ci.columns[0].desc, true)
	testing.expect_value(t, ci.columns[1].desc, false)
}

@(test)
test_parse_script_bootstrap :: proc(t: ^testing.T) {
	path := "src/test/sql/fixtures/bootstrap.sql"
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	testing.expectf(t, read_err == os.ERROR_NONE, "read fixture %s: %v", path, read_err)
	defer delete(data)

	script, err := sql.parse_script(string(data))
	defer sql.free_error(err)
	defer sql.free_script(script)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	testing.expect_value(t, len(script.statements), 4)

	dump := sql.print_script(script)
	defer delete(dump)
	testing.expect(t, strings.contains(dump, "CREATE TABLE IF NOT EXISTS users"))
	testing.expect(t, strings.contains(dump, "PRIMARY KEY"))
	testing.expect(t, strings.contains(dump, "CREATE INDEX IF NOT EXISTS idx_users_name"))
}

@(test)
test_parse_script_partial_on_error :: proc(t: ^testing.T) {
	// Parse error (not lexer): keep prefix statements, synchronize past bad stmt.
	script, err := sql.parse_script("CREATE TABLE t (id INT); SELECT FROM t; SELECT 1;")
	defer sql.free_error(err)
	defer sql.free_script(script)
	testing.expect(t, sql.has_error(err))
	testing.expect_value(t, len(script.statements), 1)
	testing.expect_value(t, script.statements[0].kind, sql.Statement_Kind.Create_Table)
}

@(test)
test_ddl_column_and_table_fk_check :: proc(t: ^testing.T) {
	src := "CREATE TABLE t (id INT REFERENCES o(id), x INT CHECK (x > 0), FOREIGN KEY (id) REFERENCES o(id), CHECK (id > 0))"
	stmt, err := sql.parse_statement(src)
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	ct := stmt.data.(sql.Create_Table_Stmt)
	testing.expect_value(t, ct.elements[0].column.constraints[0].kind, sql.Column_Constraint_Kind.References)
	testing.expect_value(t, ct.elements[1].column.constraints[0].kind, sql.Column_Constraint_Kind.Check)
	testing.expect_value(t, ct.elements[2].kind, sql.Table_Element_Kind.Table_Constraint)
	testing.expect_value(t, ct.elements[2].table_constraint.kind, sql.Table_Constraint_Kind.Foreign_Key)
	testing.expect_value(t, ct.elements[3].table_constraint.kind, sql.Table_Constraint_Kind.Check)
}

@(test)
test_alter_table_add_column :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("ALTER TABLE t ADD COLUMN note TEXT NOT NULL")
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	alt := stmt.data.(sql.Alter_Table_Stmt)
	testing.expect_value(t, alt.table, "t")
	testing.expect_value(t, alt.column.name, "note")
	testing.expect_value(t, alt.column.type_name, "TEXT")
}

@(test)
test_ddl_negative_alter_rename :: proc(t: ^testing.T) {
	_, err := sql.parse_statement("ALTER TABLE t RENAME TO u")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
	testing.expect_value(t, err.code, sql.Parse_Error_Code.Unexpected_Token)
}

@(test)
test_print_create_table_snapshot :: proc(t: ^testing.T) {
	src := "CREATE TABLE items (id INTEGER PRIMARY KEY, sku TEXT NOT NULL);"
	stmt, err := sql.parse_statement(src)
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))

	got := sql.print_statement(stmt)
	defer delete(got)
	testing.expect(t, strings.contains(got, "CREATE TABLE items"))
	testing.expect(t, strings.contains(got, "id INTEGER PRIMARY KEY"))
	testing.expect(t, strings.contains(got, "sku TEXT NOT NULL"))
}

@(test)
test_quoted_ident_normalized_in_ast :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement(`CREATE TABLE "Weird Name" (id INT)`)
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	ct := stmt.data.(sql.Create_Table_Stmt)
	testing.expect_value(t, ct.name, "Weird Name")
}
