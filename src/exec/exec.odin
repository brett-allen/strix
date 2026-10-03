package exec

import sql "../sql"

// exec_script parses and executes a semicolon-separated SQL script.
// Stops on the first error. Each statement auto-commits.
exec_script :: proc(s: ^Exec_Session, sql_text: string) -> (Exec_Result, Exec_Error) {
	if s == nil || s.closed || s.eng == nil {
		return {}, error_at(.Closed, "session is closed")
	}

	script, perr := sql.parse_script(sql_text)
	defer sql.free_script(script)
	if sql.has_error(perr) {
		err := from_parse_error(perr)
		sql.free_error(perr)
		return {}, err
	}

	last := ok_result()
	for stmt in script.statements {
		result, err := exec_statement_ast(s, stmt)
		if has_error(err) {
			free_result(result)
			return {}, err
		}
		free_result(last)
		last = result
	}
	return last, ok_error()
}

// exec_statement parses and executes a single SQL statement (auto-commit).
exec_statement :: proc(s: ^Exec_Session, sql_text: string) -> (Exec_Result, Exec_Error) {
	if s == nil || s.closed || s.eng == nil {
		return {}, error_at(.Closed, "session is closed")
	}

	stmt, perr := sql.parse_statement(sql_text)
	if sql.has_error(perr) {
		err := from_parse_error(perr)
		sql.free_error(perr)
		return {}, err
	}
	defer sql.free_statement(stmt)
	return exec_statement_ast(s, stmt)
}

exec_statement_ast :: proc(s: ^Exec_Session, stmt: sql.Statement) -> (Exec_Result, Exec_Error) {
	switch stmt.kind {
	case .Create_Table:
		return exec_create_table(s, stmt.data.(sql.Create_Table_Stmt), stmt.span)
	case .Drop_Table:
		return exec_drop_table(s, stmt.data.(sql.Drop_Table_Stmt), stmt.span)
	case .Create_Index, .Drop_Index, .Alter_Table, .Select, .Insert, .Update, .Delete:
		return {}, make_error(
			.Unsupported_Ast,
			"%s is not supported yet",
			statement_kind_label(stmt.kind),
			span = stmt.span,
		)
	}
	return {}, make_error(.Unsupported_Ast, "unsupported statement", span = stmt.span)
}

statement_kind_label :: proc(kind: sql.Statement_Kind) -> string {
	switch kind {
	case .Create_Table: return "CREATE TABLE"
	case .Drop_Table:   return "DROP TABLE"
	case .Create_Index: return "CREATE INDEX"
	case .Drop_Index:   return "DROP INDEX"
	case .Alter_Table:  return "ALTER TABLE"
	case .Select:       return "SELECT"
	case .Insert:       return "INSERT"
	case .Update:       return "UPDATE"
	case .Delete:       return "DELETE"
	}
	return "statement"
}
