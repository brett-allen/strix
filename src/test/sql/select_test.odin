package sql_tests

import "core:strings"
import "core:testing"
import sql "../../sql"

@(test)
test_select_basic_star :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("SELECT * FROM users")
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	testing.expect_value(t, stmt.kind, sql.Statement_Kind.Select)
	sel := stmt.data.(sql.Select_Stmt)
	testing.expect_value(t, sel.is_distinct, false)
	testing.expect_value(t, len(sel.projection), 1)
	testing.expect_value(t, sel.projection[0].kind, sql.Select_Item_Kind.Star)
	testing.expect_value(t, sel.from.table, "users")
	testing.expect_value(t, sel.from.alias, "")
	testing.expect(t, sel.where_expr == nil)
}

@(test)
test_select_distinct_and_aliases :: proc(t: ^testing.T) {
	src := "SELECT DISTINCT u.name AS n, score s FROM users u"
	stmt, err := sql.parse_statement(src)
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	sel := stmt.data.(sql.Select_Stmt)
	testing.expect_value(t, sel.is_distinct, true)
	testing.expect_value(t, len(sel.projection), 2)
	testing.expect_value(t, sel.projection[0].kind, sql.Select_Item_Kind.Expr)
	testing.expect_value(t, sel.projection[0].alias, "n")
	testing.expect_value(t, sel.projection[1].alias, "s")
	testing.expect_value(t, sel.from.table, "users")
	testing.expect_value(t, sel.from.alias, "u")
}

@(test)
test_select_table_star :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("SELECT u.*, id FROM users AS u")
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))
	sel := stmt.data.(sql.Select_Stmt)
	testing.expect_value(t, sel.projection[0].kind, sql.Select_Item_Kind.Table_Star)
	testing.expect_value(t, sel.projection[0].table, "u")
	testing.expect_value(t, sel.from.alias, "u")
}

@(test)
test_select_where_order_limit :: proc(t: ^testing.T) {
	src := "SELECT id, name FROM t WHERE id > 1 ORDER BY name DESC, id ASC LIMIT 10 OFFSET 5"
	stmt, err := sql.parse_statement(src)
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	sel := stmt.data.(sql.Select_Stmt)
	testing.expect(t, sel.where_expr != nil)
	testing.expect_value(t, sel.where_expr.kind, sql.Expr_Kind.Binary)
	testing.expect_value(t, len(sel.order_by), 2)
	testing.expect_value(t, sel.order_by[0].desc, true)
	testing.expect_value(t, sel.order_by[1].desc, false)
	testing.expect(t, sel.limit != nil)
	testing.expect(t, sel.offset != nil)
	testing.expect_value(t, sel.limit.data.(sql.Literal_Data).text, "10")
	testing.expect_value(t, sel.offset.data.(sql.Literal_Data).text, "5")
}

@(test)
test_select_print :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("SELECT * FROM t WHERE x = 1 ORDER BY x LIMIT 2")
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))
	got := sql.print_statement(stmt)
	defer delete(got)
	testing.expect(t, strings.contains(got, "SELECT * FROM t"))
	testing.expect(t, strings.contains(got, "WHERE"))
	testing.expect(t, strings.contains(got, "ORDER BY"))
	testing.expect(t, strings.contains(got, "LIMIT 2"))
}

@(test)
test_select_script_with_ddl :: proc(t: ^testing.T) {
	src := "CREATE TABLE t (id INT); SELECT * FROM t WHERE id = 1;"
	script, err := sql.parse_script(src)
	defer sql.free_error(err)
	defer sql.free_script(script)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	testing.expect_value(t, len(script.statements), 2)
	testing.expect_value(t, script.statements[0].kind, sql.Statement_Kind.Create_Table)
	testing.expect_value(t, script.statements[1].kind, sql.Statement_Kind.Select)
}

@(test)
test_select_join_on :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("SELECT * FROM a JOIN b ON a.id = b.id")
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	sel := stmt.data.(sql.Select_Stmt)
	testing.expect_value(t, len(sel.joins), 1)
	testing.expect_value(t, sel.joins[0].kind, sql.Join_Kind.Inner)
	testing.expect(t, sel.joins[0].on != nil)
}

@(test)
test_select_left_join_using :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("SELECT * FROM a LEFT JOIN b USING (id)")
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))
	sel := stmt.data.(sql.Select_Stmt)
	testing.expect_value(t, sel.joins[0].kind, sql.Join_Kind.Left)
	testing.expect_value(t, len(sel.joins[0].using_cols), 1)
}

@(test)
test_select_cross_and_comma_join :: proc(t: ^testing.T) {
	stmt, err := sql.parse_statement("SELECT * FROM a CROSS JOIN b")
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expect(t, !sql.has_error(err))
	testing.expect_value(t, stmt.data.(sql.Select_Stmt).joins[0].kind, sql.Join_Kind.Cross)

	stmt2, err2 := sql.parse_statement("SELECT * FROM a, b")
	defer sql.free_error(err2)
	defer sql.free_statement(stmt2)
	testing.expect(t, !sql.has_error(err2))
	testing.expect_value(t, stmt2.data.(sql.Select_Stmt).joins[0].kind, sql.Join_Kind.Cross)
}

@(test)
test_select_group_by_having :: proc(t: ^testing.T) {
	src := "SELECT a, count(*) FROM t GROUP BY a HAVING count(*) > 1"
	stmt, err := sql.parse_statement(src)
	defer sql.free_error(err)
	defer sql.free_statement(stmt)
	testing.expectf(t, !sql.has_error(err), "%s", err.message)
	sel := stmt.data.(sql.Select_Stmt)
	testing.expect_value(t, len(sel.group_by), 1)
	testing.expect(t, sel.having != nil)
}

@(test)
test_select_rejects_right_join :: proc(t: ^testing.T) {
	_, err := sql.parse_statement("SELECT * FROM a RIGHT JOIN b ON a.id = b.id")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
}

@(test)
test_select_rejects_limit_comma_form :: proc(t: ^testing.T) {
	_, err := sql.parse_statement("SELECT * FROM t LIMIT 5, 10")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
}

@(test)
test_select_requires_from :: proc(t: ^testing.T) {
	_, err := sql.parse_statement("SELECT 1")
	defer sql.free_error(err)
	testing.expect(t, sql.has_error(err))
}
