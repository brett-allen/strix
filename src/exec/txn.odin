package exec

import engine "../engine"
import sql "../sql"

// stmt_write_begin starts an auto-commit write txn, or joins an explicit txn.
// When started is true, the caller must commit or abort via stmt_write_*.
stmt_write_begin :: proc(
	s: ^Exec_Session,
	e: ^engine.Engine,
	span: sql.Span = {},
) -> (started: bool, err: Exec_Error) {
	if s.explicit_txn {
		return false, ok_error()
	}
	if eerr := engine.txn_begin(e); eerr != .None {
		return false, from_engine_error(eerr, span)
	}
	return true, ok_error()
}

stmt_write_commit :: proc(
	s: ^Exec_Session,
	e: ^engine.Engine,
	started: bool,
	span: sql.Span = {},
) -> Exec_Error {
	if !started {
		return ok_error()
	}
	if cerr := engine.txn_commit(e); cerr != .None {
		rerr := engine.txn_rollback(e)
		if rerr == .Flush_Failed {
			// Partial flush tore durable pages; discard refused. Leave engine.in_txn
			// and promote to explicit_txn so the user can retry COMMIT (recovery flush).
			// Clearing explicit_txn here would strand recovery: COMMIT/ROLLBACK → No_Txn
			// while BEGIN → In_Txn.
			// Do NOT set txn_aborted: same as exec_commit Flush_Failed — that flag
			// stops exec_script even for recovery COMMIT under continue_on_error.
			// Fence gating is via exec_statement_ast (allow COMMIT + SELECT).
			s.explicit_txn = true
			return make_error(
				.Engine,
				"commit flush failed; recovery flush required — retry COMMIT (rollback refused)",
				span = span,
			)
		}
		return from_engine_error(cerr, span)
	}
	return ok_error()
}

// stmt_write_abort undoes a failed write statement.
// Auto-commit (started): rollback that statement txn.
// Explicit txn (!started): rollback the whole open txn, clear explicit_txn, and set
// txn_aborted — v1 has no savepoints; exec_script stops even with continue_on_error.
// Returns a recovery error if rollback is refused after a partial flush (Flush_Failed);
// callers must not ignore that result.
stmt_write_abort :: proc(
	s: ^Exec_Session,
	e: ^engine.Engine,
	started: bool,
	span: sql.Span = {},
) -> Exec_Error {
	if started {
		rerr := engine.txn_rollback(e)
		if rerr == .Flush_Failed {
			// Promote auto-commit to explicit so COMMIT can retry recovery flush.
			// Do NOT set txn_aborted (blocks recovery COMMIT under continue_on_error).
			s.explicit_txn = true
			return make_error(
				.Engine,
				"rollback refused after partial flush; recovery flush required — retry COMMIT",
				span = span,
			)
		}
		return ok_error()
	}
	if s.explicit_txn {
		rerr := engine.txn_rollback(e)
		if rerr == .Flush_Failed {
			// Keep explicit_txn: engine is still in_txn with a flush fence.
			// Do NOT set txn_aborted (blocks recovery COMMIT under continue_on_error).
			return make_error(
				.Engine,
				"rollback refused after partial flush; recovery flush required — retry COMMIT",
				span = span,
			)
		}
		s.explicit_txn = false
		s.txn_aborted = true
	}
	return ok_error()
}

// finish_write_error aborts a failed write and returns primary, unless abort itself
// surfaces a flush-fence recovery error (which takes priority).
finish_write_error :: proc(
	s: ^Exec_Session,
	e: ^engine.Engine,
	started: bool,
	primary: Exec_Error,
	span: sql.Span = {},
) -> Exec_Error {
	aerr := stmt_write_abort(s, e, started, span)
	if has_error(aerr) {
		free_error(primary)
		return aerr
	}
	return primary
}

// soft_rollback_started unwinds an auto-commit txn for IF NOT EXISTS / IF EXISTS
// soft-success paths. Surfaces Flush_Failed instead of ignoring it.
soft_rollback_started :: proc(
	s: ^Exec_Session,
	e: ^engine.Engine,
	started: bool,
	span: sql.Span = {},
) -> Exec_Error {
	if !started {
		return ok_error()
	}
	rerr := engine.txn_rollback(e)
	if rerr == .Flush_Failed {
		// Do NOT set txn_aborted (blocks recovery COMMIT under continue_on_error).
		s.explicit_txn = true
		return make_error(
			.Engine,
			"rollback refused after partial flush; recovery flush required — retry COMMIT",
			span = span,
		)
	}
	return ok_error()
}

exec_begin :: proc(s: ^Exec_Session, span: sql.Span) -> (Exec_Result, Exec_Error) {
	e := session_engine(s)
	if e == nil {
		return {}, error_at(.Closed, "session is closed", span)
	}
	if s.explicit_txn {
		return {}, make_error(
			.In_Txn,
			"cannot BEGIN: transaction already active",
			span = span,
		)
	}
	if eerr := engine.txn_begin(e); eerr != .None {
		if eerr == .In_Txn {
			return {}, make_error(
				.In_Txn,
				"cannot BEGIN: transaction already active",
				span = span,
			)
		}
		return {}, from_engine_error(eerr, span)
	}
	s.explicit_txn = true
	s.txn_aborted = false
	return ok_result(), ok_error()
}

exec_commit :: proc(s: ^Exec_Session, span: sql.Span) -> (Exec_Result, Exec_Error) {
	e := session_engine(s)
	if e == nil {
		return {}, error_at(.Closed, "session is closed", span)
	}
	if !s.explicit_txn {
		return {}, make_error(
			.No_Txn,
			"cannot COMMIT: no active transaction",
			span = span,
		)
	}
	if cerr := engine.txn_commit(e); cerr != .None {
		// Keep explicit_txn on failure (including Flush_Failed) so COMMIT can retry.
		// Do NOT set txn_aborted on Flush_Failed: that flag stops exec_script even
		// for recovery COMMIT under continue_on_error. Fence gating is via
		// exec_statement_ast (allow COMMIT + SELECT).
		return {}, from_engine_error(cerr, span)
	}
	s.explicit_txn = false
	s.txn_aborted = false
	return ok_result(), ok_error()
}

exec_rollback :: proc(s: ^Exec_Session, span: sql.Span) -> (Exec_Result, Exec_Error) {
	e := session_engine(s)
	if e == nil {
		return {}, error_at(.Closed, "session is closed", span)
	}
	if !s.explicit_txn {
		return {}, make_error(
			.No_Txn,
			"cannot ROLLBACK: no active transaction",
			span = span,
		)
	}
	if rerr := engine.txn_rollback(e); rerr != .None {
		// Keep explicit_txn on Flush_Failed so COMMIT can still retry recovery flush.
		return {}, from_engine_error(rerr, span)
	}
	s.explicit_txn = false
	s.txn_aborted = false
	return ok_result(), ok_error()
}
