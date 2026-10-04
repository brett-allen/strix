package exec

import engine "../engine"

Exec_Session :: struct {
	eng:          ^engine.Engine,
	owns_engine:  bool,
	closed:       bool,
	explicit_txn: bool, // true after BEGIN until COMMIT/ROLLBACK
	txn_aborted:  bool, // set when a write fails inside an explicit txn (whole txn rolled back)
}

// session_open opens an existing .strix database at path.
session_open :: proc(path: string) -> (s: Exec_Session, err: Exec_Error) {
	e, eerr := engine.engine_open(path)
	if eerr != .None {
		return {}, from_engine_error(eerr)
	}
	heap := new(engine.Engine)
	heap^ = e
	return Exec_Session{eng = heap, owns_engine = true, closed = false}, ok_error()
}

// session_adopt uses an existing engine pointer (tests). Does not close it.
session_adopt :: proc(e: ^engine.Engine) -> Exec_Session {
	if e == nil {
		return Exec_Session{closed = true}
	}
	return Exec_Session{eng = e, owns_engine = false, closed = false}
}

// session_close rolls back any open txn and closes the engine when owned.
// While a flush fence is live, close is REFUSED: session stays open/usable so
// the caller can retry COMMIT. Never frees the engine or marks closed over a fence.
session_close :: proc(s: ^Exec_Session) -> Exec_Error {
	if s == nil || s.closed {
		return ok_error()
	}
	if s.eng != nil && engine.engine_flush_fence(s.eng) {
		return from_engine_error(.Flush_Failed)
	}
	if s.owns_engine && s.eng != nil {
		eerr := engine.engine_close(s.eng)
		if eerr == .Flush_Failed {
			// Engine refused close; keep session usable for recovery COMMIT.
			return from_engine_error(eerr)
		}
		close_err := ok_error()
		if eerr != .None {
			close_err = from_engine_error(eerr)
		}
		free(s.eng)
		s.eng = nil
		s.closed = true
		s.explicit_txn = false
		s.txn_aborted = false
		return close_err
	}
	if s.eng != nil && s.eng.in_txn {
		rerr := engine.txn_rollback(s.eng)
		if rerr == .Flush_Failed {
			return from_engine_error(rerr)
		}
		if rerr != .None && rerr != .No_Txn {
			return from_engine_error(rerr)
		}
		s.eng = nil
	} else {
		s.eng = nil
	}
	s.closed = true
	s.explicit_txn = false
	s.txn_aborted = false
	return ok_error()
}

session_engine :: proc(s: ^Exec_Session) -> ^engine.Engine {
	if s == nil || s.closed {
		return nil
	}
	return s.eng
}

// session_flush_fence reports whether recovery COMMIT is required before close/quit.
session_flush_fence :: proc(s: ^Exec_Session) -> bool {
	if s == nil || s.closed || s.eng == nil {
		return false
	}
	return engine.engine_flush_fence(s.eng)
}
