package sql

import "core:mem"

free_statement :: proc(stmt: Statement, allocator := context.allocator) {
	#partial switch stmt.kind {
	case .Create_Table:
		data := stmt.data.(Create_Table_Stmt)
		delete(data.name, allocator)
		free_table_elements(data.elements, allocator)
		delete(data.elements, allocator)
	case .Drop_Table:
		data := stmt.data.(Drop_Table_Stmt)
		delete(data.name, allocator)
	case .Create_Index:
		data := stmt.data.(Create_Index_Stmt)
		delete(data.name, allocator)
		delete(data.table_name, allocator)
		free_index_columns(data.columns, allocator)
		delete(data.columns, allocator)
	case .Drop_Index:
		data := stmt.data.(Drop_Index_Stmt)
		delete(data.name, allocator)
	case .Alter_Table:
		free_alter_table_stmt(stmt.data.(Alter_Table_Stmt), allocator)
	case .Select:
		free_select_stmt(stmt.data.(Select_Stmt), allocator)
	case .Insert:
		free_insert_stmt(stmt.data.(Insert_Stmt), allocator)
	case .Update:
		free_update_stmt(stmt.data.(Update_Stmt), allocator)
	case .Delete:
		free_delete_stmt(stmt.data.(Delete_Stmt), allocator)
	case .Begin, .Commit, .Rollback:
		// no owned fields
	}
}

free_script :: proc(script: Script, allocator := context.allocator) {
	for stmt in script.statements {
		free_statement(stmt, allocator)
	}
	delete(script.statements, allocator)
}
