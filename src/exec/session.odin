package exec

import engine "../engine"

Exec_Session :: struct {
	eng:         ^engine.Engine,
	owns_engine: bool,
	closed:      bool,
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
session_close :: proc(s: ^Exec_Session) -> Exec_Error {
	if s == nil || s.closed {
		return ok_error()
	}
	s.closed = true
	if s.owns_engine && s.eng != nil {
		eerr := engine.engine_close(s.eng)
		free(s.eng)
		s.eng = nil
		if eerr != .None {
			return from_engine_error(eerr)
		}
	} else {
		s.eng = nil
	}
	return ok_error()
}

session_engine :: proc(s: ^Exec_Session) -> ^engine.Engine {
	if s == nil || s.closed {
		return nil
	}
	return s.eng
}
