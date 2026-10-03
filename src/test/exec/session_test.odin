package exec_tests

import "core:fmt"
import "core:os"
import "core:testing"
import engine "../../engine"
import exec "../../exec"
import sql "../../sql"

@(test)
test_session_open_close_roundtrip :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-e1-session-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		engine.engine_close(&e)
	}

	s, err := exec.session_open(path)
	testing.expectf(t, !exec.has_error(err), "%s", err.message)
	exec.free_error(err)
	testing.expect(t, exec.session_engine(&s) != nil)

	r, eerr := exec.exec_statement(&s, "CREATE TABLE t (a INT);")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.kind, exec.Result_Kind.Ok)
	exec.free_error(eerr)
	exec.free_result(r)

	cerr := exec.session_close(&s)
	testing.expect(t, !exec.has_error(cerr))
	exec.free_error(cerr)
	testing.expect(t, exec.session_engine(&s) == nil)

	// Idempotent close
	cerr2 := exec.session_close(&s)
	testing.expect(t, !exec.has_error(cerr2))
	exec.free_error(cerr2)
}

@(test)
test_session_open_missing_file :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-e1-missing-%d.strix", os.get_pid())
	os.remove(path)
	s, err := exec.session_open(path)
	testing.expect(t, exec.has_error(err))
	testing.expect(t, err.code == .Engine || err.code == .Io || err.code == .Closed)
	exec.free_error(err)
	_ = exec.session_close(&s)
}

@(test)
test_session_adopt_nil_and_engine :: proc(t: ^testing.T) {
	nil_s := exec.session_adopt(nil)
	testing.expect(t, nil_s.closed)
	testing.expect(t, exec.session_engine(&nil_s) == nil)

	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	s := exec.session_adopt(&e)
	testing.expect(t, !s.closed)
	testing.expect(t, exec.session_engine(&s) == &e)
	// adopt must not close the engine
	_ = exec.session_close(&s)
	testing.expect(t, !e.closed)
}

@(test)
test_exec_on_closed_session :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	s := exec.session_adopt(&e)
	_ = exec.session_close(&s)

	r, eerr := exec.exec_script(&s, "CREATE TABLE t (a INT);")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Closed)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, eerr2 := exec.exec_statement(&s, "CREATE TABLE t (a INT);")
	testing.expect(t, exec.has_error(eerr2))
	testing.expect_value(t, eerr2.code, exec.Exec_Error_Code.Closed)
	exec.free_error(eerr2)
	exec.free_result(r2)
}

@(test)
test_create_drop_ast_on_closed_session :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	s := exec.session_adopt(&e)
	_ = exec.session_close(&s)

	create, perr := sql.parse_statement("CREATE TABLE t (a INT);")
	testing.expect(t, !sql.has_error(perr))
	sql.free_error(perr)
	defer sql.free_statement(create)
	r, eerr := exec.exec_statement_ast(&s, create)
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Closed)
	exec.free_error(eerr)
	exec.free_result(r)

	drop, dperr := sql.parse_statement("DROP TABLE t;")
	testing.expect(t, !sql.has_error(dperr))
	sql.free_error(dperr)
	defer sql.free_statement(drop)
	r2, eerr2 := exec.exec_statement_ast(&s, drop)
	testing.expect_value(t, eerr2.code, exec.Exec_Error_Code.Closed)
	exec.free_error(eerr2)
	exec.free_result(r2)
}
