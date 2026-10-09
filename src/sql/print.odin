package sql

import "core:fmt"
import "core:strings"

// Debug printer for AST snapshots in tests.

print_script :: proc(script: Script, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	for stmt, i in script.statements {
		if i > 0 {
			strings.write_string(&b, "\n")
		}
		// Nested printers allocate into the temp allocator so intermediates
		// are freed with the arena / temp reset rather than leaking.
		strings.write_string(&b, print_statement(stmt, context.temp_allocator))
	}
	out := strings.clone(strings.to_string(b), allocator)
	strings.builder_destroy(&b)
	return out
}

print_statement :: proc(stmt: Statement, allocator := context.allocator) -> string {
	#partial switch stmt.kind {
	case .Create_Table:
		return print_create_table(stmt.data.(Create_Table_Stmt), allocator)
	case .Drop_Table:
		return print_drop_table(stmt.data.(Drop_Table_Stmt), allocator)
	case .Create_Index:
		return print_create_index(stmt.data.(Create_Index_Stmt), allocator)
	case .Drop_Index:
		return print_drop_index(stmt.data.(Drop_Index_Stmt), allocator)
	case .Alter_Table:
		return print_alter_table(stmt.data.(Alter_Table_Stmt), allocator)
	case .Select:
		return print_select(stmt.data.(Select_Stmt), allocator)
	case .Insert:
		return print_insert(stmt.data.(Insert_Stmt), allocator)
	case .Update:
		return print_update(stmt.data.(Update_Stmt), allocator)
	case .Delete:
		return print_delete(stmt.data.(Delete_Stmt), allocator)
	case .Begin:
		return strings.clone("BEGIN", allocator)
	case .Commit:
		return strings.clone("COMMIT", allocator)
	case .Rollback:
		return strings.clone("ROLLBACK", allocator)
	}
	return "(unknown statement)"
}

print_insert :: proc(stmt: Insert_Stmt, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "INSERT")
	#partial switch stmt.conflict {
	case .Replace:
		strings.write_string(&b, " OR REPLACE")
	case .Ignore:
		strings.write_string(&b, " OR IGNORE")
	case .None:
	}
	fmt.sbprintf(&b, " INTO %s", stmt.table)
	if len(stmt.columns) > 0 {
		strings.write_string(&b, " (")
		for col, i in stmt.columns {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, col)
		}
		strings.write_byte(&b, ')')
	}
	#partial switch stmt.source {
	case .Values:
		strings.write_string(&b, " VALUES ")
		for row, ri in stmt.rows {
			if ri > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_byte(&b, '(')
			for v, vi in row {
				if vi > 0 {
					strings.write_string(&b, ", ")
				}
				strings.write_string(&b, print_expr(v, context.temp_allocator))
			}
			strings.write_byte(&b, ')')
		}
	case .Select:
		strings.write_byte(&b, ' ')
		strings.write_string(&b, print_select(stmt.select, context.temp_allocator))
	}
	out := strings.clone(strings.to_string(b), allocator)
	strings.builder_destroy(&b)
	return out
}

print_update :: proc(stmt: Update_Stmt, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "UPDATE %s SET ", stmt.table)
	for a, i in stmt.sets {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		fmt.sbprintf(&b, "%s = %s", a.column, print_expr(a.value, context.temp_allocator))
	}
	if stmt.where_expr != nil {
		fmt.sbprintf(&b, " WHERE %s", print_expr(stmt.where_expr, context.temp_allocator))
	}
	out := strings.clone(strings.to_string(b), allocator)
	strings.builder_destroy(&b)
	return out
}

print_delete :: proc(stmt: Delete_Stmt, allocator := context.allocator) -> string {
	if stmt.where_expr != nil {
		return fmt.aprintf(
			"DELETE FROM %s WHERE %s",
			stmt.table,
			print_expr(stmt.where_expr, context.temp_allocator),
			allocator = allocator,
		)
	}
	return fmt.aprintf("DELETE FROM %s", stmt.table, allocator = allocator)
}

print_select :: proc(stmt: Select_Stmt, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "SELECT")
	if stmt.is_distinct {
		strings.write_string(&b, " DISTINCT")
	}
	strings.write_byte(&b, ' ')
	for item, i in stmt.projection {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		#partial switch item.kind {
		case .Star:
			strings.write_byte(&b, '*')
		case .Table_Star:
			fmt.sbprintf(&b, "%s.*", item.table)
		case .Expr:
			strings.write_string(&b, print_expr(item.expr, context.temp_allocator))
			if item.alias != "" {
				fmt.sbprintf(&b, " AS %s", item.alias)
			}
		}
	}
	fmt.sbprintf(&b, " FROM %s", stmt.from.table)
	if stmt.from.alias != "" {
		fmt.sbprintf(&b, " AS %s", stmt.from.alias)
	}
	for j in stmt.joins {
		#partial switch j.kind {
		case .Inner:
			strings.write_string(&b, " JOIN ")
		case .Left:
			strings.write_string(&b, " LEFT JOIN ")
		case .Cross:
			strings.write_string(&b, " CROSS JOIN ")
		}
		strings.write_string(&b, j.table.table)
		if j.table.alias != "" {
			fmt.sbprintf(&b, " AS %s", j.table.alias)
		}
		if j.on != nil {
			fmt.sbprintf(&b, " ON %s", print_expr(j.on, context.temp_allocator))
		} else if len(j.using_cols) > 0 {
			strings.write_string(&b, " USING (")
			for col, i in j.using_cols {
				if i > 0 {
					strings.write_string(&b, ", ")
				}
				strings.write_string(&b, col)
			}
			strings.write_byte(&b, ')')
		}
	}
	if stmt.where_expr != nil {
		fmt.sbprintf(&b, " WHERE %s", print_expr(stmt.where_expr, context.temp_allocator))
	}
	if len(stmt.group_by) > 0 {
		strings.write_string(&b, " GROUP BY ")
		for e, i in stmt.group_by {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, print_expr(e, context.temp_allocator))
		}
	}
	if stmt.having != nil {
		fmt.sbprintf(&b, " HAVING %s", print_expr(stmt.having, context.temp_allocator))
	}
	if len(stmt.order_by) > 0 {
		strings.write_string(&b, " ORDER BY ")
		for item, i in stmt.order_by {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, print_expr(item.expr, context.temp_allocator))
			if item.desc {
				strings.write_string(&b, " DESC")
			}
		}
	}
	if stmt.limit != nil {
		fmt.sbprintf(&b, " LIMIT %s", print_expr(stmt.limit, context.temp_allocator))
	}
	if stmt.offset != nil {
		fmt.sbprintf(&b, " OFFSET %s", print_expr(stmt.offset, context.temp_allocator))
	}
	out := strings.clone(strings.to_string(b), allocator)
	strings.builder_destroy(&b)
	return out
}

print_create_table :: proc(stmt: Create_Table_Stmt, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "CREATE TABLE")
	if stmt.if_not_exists {
		strings.write_string(&b, " IF NOT EXISTS")
	}
	fmt.sbprintf(&b, " %s (\n", stmt.name)
	for elem, i in stmt.elements {
		if i > 0 {
			strings.write_string(&b, ",\n")
		}
		strings.write_string(&b, "  ")
		#partial switch elem.kind {
		case .Column:
			col := elem.column
			strings.write_string(&b, col.name)
			if col.type_name != "" {
				fmt.sbprintf(&b, " %s", col.type_name)
			}
			for c in col.constraints {
				strings.write_string(&b, " ")
				strings.write_string(&b, print_column_constraint(c, context.temp_allocator))
			}
		case .Table_Constraint:
			strings.write_string(&b, print_table_constraint(elem.table_constraint, context.temp_allocator))
		}
	}
	strings.write_string(&b, "\n)")
	out := strings.clone(strings.to_string(b), allocator)
	strings.builder_destroy(&b)
	return out
}

print_drop_table :: proc(stmt: Drop_Table_Stmt, allocator := context.allocator) -> string {
	if stmt.if_exists {
		return fmt.aprintf("DROP TABLE IF EXISTS %s", stmt.name, allocator = allocator)
	}
	return fmt.aprintf("DROP TABLE %s", stmt.name, allocator = allocator)
}

print_create_index :: proc(stmt: Create_Index_Stmt, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	if stmt.unique {
		strings.write_string(&b, "CREATE UNIQUE INDEX")
	} else {
		strings.write_string(&b, "CREATE INDEX")
	}
	if stmt.if_not_exists {
		strings.write_string(&b, " IF NOT EXISTS")
	}
	fmt.sbprintf(&b, " %s ON %s (", stmt.name, stmt.table_name)
	for col, i in stmt.columns {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, col.name)
		if col.desc {
			strings.write_string(&b, " DESC")
		}
	}
	strings.write_byte(&b, ')')
	out := strings.clone(strings.to_string(b), allocator)
	strings.builder_destroy(&b)
	return out
}

print_drop_index :: proc(stmt: Drop_Index_Stmt, allocator := context.allocator) -> string {
	if stmt.if_exists {
		return fmt.aprintf("DROP INDEX IF EXISTS %s", stmt.name, allocator = allocator)
	}
	return fmt.aprintf("DROP INDEX %s", stmt.name, allocator = allocator)
}

print_column_constraint :: proc(c: Column_Constraint, allocator := context.allocator) -> string {
	#partial switch c.kind {
	case .Primary_Key:
		return "PRIMARY KEY"
	case .Not_Null:
		return "NOT NULL"
	case .Unique:
		return "UNIQUE"
	case .Default:
		return fmt.aprintf("DEFAULT %s", print_expr(c.default_expr, context.temp_allocator), allocator = allocator)
	case .Check:
		return fmt.aprintf("CHECK (%s)", print_expr(c.check_expr, context.temp_allocator), allocator = allocator)
	case .References:
		return fmt.aprintf("REFERENCES %s", print_fk_ref(c.references, context.temp_allocator), allocator = allocator)
	}
	return "?"
}

print_fk_ref :: proc(fk: Foreign_Key_Ref, allocator := context.allocator) -> string {
	if len(fk.columns) == 0 {
		return strings.clone(fk.table, allocator)
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s (", fk.table)
	for col, i in fk.columns {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, col)
	}
	strings.write_byte(&b, ')')
	out := strings.clone(strings.to_string(b), allocator)
	strings.builder_destroy(&b)
	return out
}

print_table_constraint :: proc(tc: Table_Constraint, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	#partial switch tc.kind {
	case .Primary_Key:
		strings.write_string(&b, "PRIMARY KEY (")
		for col, i in tc.columns {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, col)
		}
		strings.write_byte(&b, ')')
	case .Unique:
		strings.write_string(&b, "UNIQUE (")
		for col, i in tc.columns {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, col)
		}
		strings.write_byte(&b, ')')
	case .Check:
		fmt.sbprintf(&b, "CHECK (%s)", print_expr(tc.check_expr, context.temp_allocator))
	case .Foreign_Key:
		strings.write_string(&b, "FOREIGN KEY (")
		for col, i in tc.columns {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, col)
		}
		fmt.sbprintf(&b, ") REFERENCES %s", print_fk_ref(tc.references, context.temp_allocator))
	}
	out := strings.clone(strings.to_string(b), allocator)
	strings.builder_destroy(&b)
	return out
}

print_alter_table :: proc(stmt: Alter_Table_Stmt, allocator := context.allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "ALTER TABLE %s ADD COLUMN %s", stmt.table, stmt.column.name)
	if stmt.column.type_name != "" {
		fmt.sbprintf(&b, " %s", stmt.column.type_name)
	}
	for c in stmt.column.constraints {
		strings.write_string(&b, " ")
		strings.write_string(&b, print_column_constraint(c, context.temp_allocator))
	}
	out := strings.clone(strings.to_string(b), allocator)
	strings.builder_destroy(&b)
	return out
}

print_expr :: proc(expr: ^Expr, allocator := context.allocator) -> string {
	if expr == nil {
		return "<nil>"
	}
	#partial switch expr.kind {
	case .Literal:
		return strings.clone(expr.data.(Literal_Data).text, allocator)
	case .Column_Ref:
		data := expr.data.(Column_Ref_Data)
		return join_segments(data.segments, allocator)
	case .Placeholder:
		// Always print ?N (including ?0) so print/reparse preserves indices.
		idx := expr.data.(Placeholder_Data).index
		return fmt.aprintf("?%d", idx, allocator = allocator)
	case .Star:
		return strings.clone("*", allocator)
	case .Unary:
		data := expr.data.(Unary_Data)
		op := "+"
		#partial switch data.op {
		case .Minus:
			op = "-"
		case .Not:
			op = "NOT "
		}
		return fmt.aprintf(
			"%s(%s)",
			op,
			print_expr(data.expr, context.temp_allocator),
			allocator = allocator,
		)
	case .Binary:
		data := expr.data.(Binary_Data)
		op := binary_op_string(data.op)
		return fmt.aprintf(
			"(%s %s %s)",
			print_expr(data.left, context.temp_allocator),
			op,
			print_expr(data.right, context.temp_allocator),
			allocator = allocator,
		)
	case .Call:
		data := expr.data.(Call_Data)
		b := strings.builder_make(allocator)
		fmt.sbprintf(&b, "%s(", data.name)
		for arg, i in data.args {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, print_expr(arg, context.temp_allocator))
		}
		strings.write_byte(&b, ')')
		out := strings.clone(strings.to_string(b), allocator)
		strings.builder_destroy(&b)
		return out
	case .Is_Null:
		data := expr.data.(Is_Null_Data)
		if data.negated {
			return fmt.aprintf(
				"(%s IS NOT NULL)",
				print_expr(data.expr, context.temp_allocator),
				allocator = allocator,
			)
		}
		return fmt.aprintf(
			"(%s IS NULL)",
			print_expr(data.expr, context.temp_allocator),
			allocator = allocator,
		)
	case .In_List:
		data := expr.data.(In_List_Data)
		b := strings.builder_make(allocator)
		if data.negated {
			fmt.sbprintf(&b, "(%s NOT IN (", print_expr(data.expr, context.temp_allocator))
		} else {
			fmt.sbprintf(&b, "(%s IN (", print_expr(data.expr, context.temp_allocator))
		}
		for v, i in data.values {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, print_expr(v, context.temp_allocator))
		}
		strings.write_string(&b, "))")
		out := strings.clone(strings.to_string(b), allocator)
		strings.builder_destroy(&b)
		return out
	case .Between:
		data := expr.data.(Between_Data)
		if data.negated {
			return fmt.aprintf(
				"(%s NOT BETWEEN %s AND %s)",
				print_expr(data.expr, context.temp_allocator),
				print_expr(data.low, context.temp_allocator),
				print_expr(data.high, context.temp_allocator),
				allocator = allocator,
			)
		}
		return fmt.aprintf(
			"(%s BETWEEN %s AND %s)",
			print_expr(data.expr, context.temp_allocator),
			print_expr(data.low, context.temp_allocator),
			print_expr(data.high, context.temp_allocator),
			allocator = allocator,
		)
	case .Cast:
		data := expr.data.(Cast_Data)
		return fmt.aprintf(
			"CAST(%s AS %s)",
			print_expr(data.expr, context.temp_allocator),
			data.type_name,
			allocator = allocator,
		)
	}
	return "(expr)"
}

binary_op_string :: proc(op: Binary_Op) -> string {
	#partial switch op {
	case .Or:
		return "OR"
	case .And:
		return "AND"
	case .Concat:
		return "||"
	case .Add:
		return "+"
	case .Sub:
		return "-"
	case .Mul:
		return "*"
	case .Div:
		return "/"
	case .Mod:
		return "%"
	case .Eq:
		return "="
	case .EqEq:
		return "=="
	case .NotEq:
		return "!="
	case .Lt:
		return "<"
	case .LtEq:
		return "<="
	case .Gt:
		return ">"
	case .GtEq:
		return ">="
	}
	return "?"
}
