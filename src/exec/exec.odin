package exec

import sql "../sql"

// Exec_Options controls script execution behavior.
Exec_Options :: struct {
	continue_on_error:            bool,
	source_path:                  string, // optional; used by callers with format_error
	flush_fail_after_data_writes: int, // test hook; 0 = off (injected before script runs)
}

// fence_allows_stmt reports statements permitted while a flush fence is live:
// recovery COMMIT, and read-only SELECT (inspection). All other kinds hard-stop.
fence_allows_stmt :: proc(kind: sql.Statement_Kind) -> bool {
	return kind == .Commit || kind == .Select
}

// exec_script parses and executes a semicolon-separated SQL script.
// Stops on the first error unless opts.continue_on_error is set.
// After an explicit-txn write abort (txn_aborted), the script always stops —
// continue_on_error must not auto-commit later statements outside the aborted txn.
// After a flush fence (including COMMIT Flush_Failed), only recovery COMMIT and
// SELECT may proceed; other statements hard-stop. With continue_on_error, intervening
// non-allowed statements are skipped until a recovery COMMIT (or script ends still
// fenced → error). Do not set txn_aborted for the fence path — that blocks COMMIT.
// Statements auto-commit unless an explicit BEGIN…COMMIT/ROLLBACK is open.
exec_script :: proc(
	s: ^Exec_Session,
	sql_text: string,
	opts := Exec_Options{},
) -> (Exec_Result, Exec_Error) {
	if s == nil || s.closed || s.eng == nil {
		return {}, error_at(.Closed, "session is closed")
	}

	// New script invocation: a prior abort is settled once explicit_txn is clear.
	// Do not rewrite unrelated errors in later scripts / .read as "transaction aborted".
	if s.txn_aborted && !s.explicit_txn {
		s.txn_aborted = false
	}

	script, perr := sql.parse_script(sql_text)
	defer sql.free_script(script)
	if sql.has_error(perr) {
		err := from_parse_error(perr)
		sql.free_error(perr)
		return {}, err
	}

	// Accumulate every statement result so callers (shell `.read`, `strix sql`)
	// can print each one. Primary return fields remain the last statement.
	parts := make([dynamic]Exec_Result, 0, len(script.statements))
	defer {
		for part in parts {
			free_result(part)
		}
		delete(parts)
	}
	first_err := ok_error()
	aborted_this_script := false
	skipped_for_fence := false
	for stmt in script.statements {
		// Flush fence: allow COMMIT + SELECT; hard-stop or skip others.
		if session_flush_fence(s) && !fence_allows_stmt(stmt.kind) {
			if opts.continue_on_error {
				skipped_for_fence = true
				continue
			}
			fence_err := make_error(
				.Engine,
				"flush recovery required — retry COMMIT; script stopped",
				span = stmt.span,
			)
			free_error(first_err)
			return {}, fence_err
		}
		result, err := exec_statement_ast(s, stmt) // activates session binds for Placeholder eval
		if has_error(err) {
			free_result(result)
			if s.txn_aborted {
				aborted_this_script = true
			}
			if aborted_this_script {
				// Annotate and stop — do not continue_on_error past an aborted txn.
				// Exception: flush-fence recovery keeps explicit_txn and must not
				// use txn_aborted in a way that blocks COMMIT (fence path above).
				annotated := make_error(
					err.code,
					"%s; transaction aborted — script stopped",
					err.message,
					span = err.span,
				)
				free_error(err)
				free_error(first_err)
				return {}, annotated
			}
			if !opts.continue_on_error {
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
		append(&parts, result)
	}
	if has_error(first_err) {
		return {}, first_err
	}
	// Skipped non-recovery stmts under continue_on_error but never cleared the fence.
	if skipped_for_fence && session_flush_fence(s) {
		return {}, make_error(
			.Engine,
			"flush recovery required — retry COMMIT; script stopped",
		)
	}
	if len(parts) == 0 {
		return ok_result(), ok_error()
	}
	// Transfer ownership out of `parts` into the returned aggregate.
	out := parts[len(parts) - 1]
	if len(parts) > 1 {
		preceding := make([]Exec_Result, len(parts) - 1)
		for i in 0 ..< len(parts) - 1 {
			preceding[i] = parts[i]
		}
		out.preceding = preceding
	}
	clear(&parts) // emptied; defer must not free transferred results
	return out, ok_error()
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
	// Gate ALL entry points (exec_statement, shell typed SQL, exec_script):
	// while fenced, only recovery COMMIT and read-only SELECT may run.
	if s != nil && session_flush_fence(s) && !fence_allows_stmt(stmt.kind) {
		return {}, make_error(
			.Engine,
			"flush recovery required — retry COMMIT",
			span = stmt.span,
		)
	}
	// Activate session bind table for Placeholder eval (F4). Nested calls restore.
	prev_binds: ^Bind_Table
	if s != nil {
		prev_binds = bind_table_activate(&s.binds)
	}
	defer if s != nil {
		bind_table_restore(prev_binds)
	}
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

// exec_statement_params binds `params` at 0..len-1 (cloned), checks arity against
// placeholders in the statement, executes once, then clears session binds.
// Caller retains ownership of `params` (and must free_value each if owned).
exec_statement_params :: proc(
	s: ^Exec_Session,
	sql_text: string,
	params: []Value,
) -> (Exec_Result, Exec_Error) {
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

	max_ph := collect_placeholder_max_statement(stmt)
	if aerr := validate_bind_arity(max_ph, len(params), stmt.span); has_error(aerr) {
		return {}, aerr
	}

	if berr := session_bind_all(s, params); has_error(berr) {
		return {}, berr
	}
	defer session_clear_binds(s)

	return exec_statement_ast(s, stmt)
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
