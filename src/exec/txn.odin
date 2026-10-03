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
		_ = engine.txn_rollback(e)
		return from_engine_error(cerr, span)
	}
	return ok_error()
}

// stmt_write_abort undoes a failed write statement.
// Auto-commit (started): rollback that statement txn.
// Explicit txn (!started): rollback the whole open txn, clear explicit_txn, and set
// txn_aborted — v1 has no savepoints; exec_script stops even with continue_on_error.
stmt_write_abort :: proc(s: ^Exec_Session, e: ^engine.Engine, started: bool) {
	if started {
		_ = engine.txn_rollback(e)
		return
	}
	if s.explicit_txn {
		_ = engine.txn_rollback(e)
		s.explicit_txn = false
		s.txn_aborted = true
	}
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
		return {}, from_engine_error(cerr, span)
	}
	s.explicit_txn = false
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
		return {}, from_engine_error(rerr, span)
	}
	s.explicit_txn = false
	return ok_result(), ok_error()
}
