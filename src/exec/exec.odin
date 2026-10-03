package exec

import sql "../sql"

// Exec_Options controls script execution behavior.
Exec_Options :: struct {
	continue_on_error: bool,
	source_path:       string, // optional; used by callers with format_error
}

// exec_script parses and executes a semicolon-separated SQL script.
// Stops on the first error unless opts.continue_on_error is set.
// After an explicit-txn write abort (txn_aborted), the script always stops —
// continue_on_error must not auto-commit later statements outside the aborted txn.
// Statements auto-commit unless an explicit BEGIN…COMMIT/ROLLBACK is open.
exec_script :: proc(
	s: ^Exec_Session,
	sql_text: string,
	opts := Exec_Options{},
) -> (Exec_Result, Exec_Error) {
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
	first_err := ok_error()
	for stmt in script.statements {
		result, err := exec_statement_ast(s, stmt)
		if has_error(err) {
			free_result(result)
			if s.txn_aborted {
				// Annotate and stop — do not continue_on_error past an aborted txn.
				annotated := make_error(
					err.code,
					"%s; transaction aborted — script stopped",
					err.message,
					span = err.span,
				)
				free_error(err)
				free_result(last)
				free_error(first_err)
				return {}, annotated
			}
			if !opts.continue_on_error {
				free_result(last)
				free_error(first_err)
				return {}, err
			}
			if !has_error(first_err) {
				first_err = err
			} else {
				free_error(err)
			}
			continue
		}
		free_result(last)
		last = result
	}
	if has_error(first_err) {
		free_result(last)
		return {}, first_err
	}
	return last, ok_error()
}

// exec_statement parses and executes a single SQL statement (auto-commit unless in explicit txn).
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
	case .Insert:
		return exec_insert(s, stmt.data.(sql.Insert_Stmt), stmt.span)
	case .Select:
		return exec_select(s, stmt.data.(sql.Select_Stmt), stmt.span)
	case .Update:
		return exec_update(s, stmt.data.(sql.Update_Stmt), stmt.span)
	case .Delete:
		return exec_delete(s, stmt.data.(sql.Delete_Stmt), stmt.span)
	case .Create_Index:
		return exec_create_index(s, stmt.data.(sql.Create_Index_Stmt), stmt.span)
	case .Drop_Index:
		return exec_drop_index(s, stmt.data.(sql.Drop_Index_Stmt), stmt.span)
	case .Begin:
		return exec_begin(s, stmt.span)
	case .Commit:
		return exec_commit(s, stmt.span)
	case .Rollback:
		return exec_rollback(s, stmt.span)
	case .Alter_Table:
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
	case .Begin:        return "BEGIN"
	case .Commit:       return "COMMIT"
	case .Rollback:     return "ROLLBACK"
	}
	return "statement"
}
