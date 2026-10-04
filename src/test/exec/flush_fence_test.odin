package exec_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import engine "../../engine"
import exec "../../exec"

@(test)
test_exec_auto_commit_flush_failed_refuses_close_then_recovers :: proc(t: ^testing.T) {
	// After auto-commit fence: close must refuse (session stays open), retry COMMIT
	// after clearing the fail hook must succeed, then close succeeds.
	path := fmt.tprintf("/tmp/strix-fence-auto-%d.strix", os.get_pid())
	defer os.remove(path)
	{
		e, cerr := engine.engine_create(path)
		testing.expect(t, engine.ok(cerr))
		testing.expect(t, engine.ok(engine.engine_close(&e)))
	}

	s, oerr := exec.session_open(path)
	testing.expectf(t, !exec.has_error(oerr), "%s", oerr.message)
	exec.free_error(oerr)

	r0, e0 := exec.exec_script(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);")
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	eng := exec.session_engine(&s)
	testing.expect(t, eng != nil)
	pager := engine.engine_pager_unsafe_for_tests(eng)
	pager.flush_fail_after_data_writes = 1

	r, eerr := exec.exec_statement(&s, "INSERT INTO t (id, n) VALUES (1, 'a');")
	testing.expect(t, exec.has_error(eerr))
	testing.expect(t, strings.contains(eerr.message, "recovery") || strings.contains(eerr.message, "flush"))
	testing.expect(t, !s.txn_aborted) // must not block recovery COMMIT under continue_on_error
	testing.expect(t, s.explicit_txn)
	testing.expect(t, eng.in_txn)
	testing.expect(t, exec.session_flush_fence(&s))
	exec.free_error(eerr)
	exec.free_result(r)

	// Refuse close — do not destroy recovery state.
	cerr := exec.session_close(&s)
	testing.expect(t, exec.has_error(cerr))
	testing.expect(t, strings.contains(cerr.message, "flush") || strings.contains(cerr.message, "recovery"))
	exec.free_error(cerr)
	testing.expect(t, !s.closed)
	testing.expect(t, exec.session_engine(&s) != nil)
	testing.expect(t, eng.in_txn)
	testing.expect(t, exec.session_flush_fence(&s))

	// engine_close must also refuse (not pager_close over the fence).
	testing.expect_value(t, engine.engine_close(eng), engine.Engine_Error.Flush_Failed)
	testing.expect(t, !eng.closed)

	// Clear fail hook; retry COMMIT recovers; then close succeeds.
	pager.flush_fail_after_data_writes = 0
	r2, e2 := exec.exec_statement(&s, "COMMIT;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect(t, !s.explicit_txn)
	testing.expect(t, !s.txn_aborted)
	testing.expect(t, !eng.in_txn)
	testing.expect(t, !exec.session_flush_fence(&s))
	exec.free_error(e2)
	exec.free_result(r2)

	testing.expectf(t, !exec.has_error(exec.session_close(&s)), "close after recovery")

	// Reopen integrity: recovered row is durable.
	s2, o2 := exec.session_open(path)
	testing.expectf(t, !exec.has_error(o2), "%s", o2.message)
	exec.free_error(o2)
	defer exec.session_close(&s2)
	r3, e3 := exec.exec_statement(&s2, "SELECT id, n FROM t;")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, r3.kind, exec.Result_Kind.Result_Set)
	testing.expect_value(t, len(r3.rows), 1)
	exec.free_error(e3)
	exec.free_result(r3)
}

@(test)
test_exec_auto_commit_flush_failed_recovers_via_commit :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer {
		pager := engine.engine_pager_unsafe_for_tests(&e)
		if pager != nil {
			pager.flush_fail_after_data_writes = 0
			if e.in_txn {
				_ = engine.txn_commit(&e)
			}
		}
		_ = engine.engine_close(&e)
	}
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);")
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	pager := engine.engine_pager_unsafe_for_tests(&e)
	pager.flush_fail_after_data_writes = 1

	r, eerr := exec.exec_statement(&s, "INSERT INTO t (id, n) VALUES (1, 'a');")
	testing.expect(t, exec.has_error(eerr))
	testing.expect(t, s.explicit_txn)
	testing.expect(t, e.in_txn)
	exec.free_error(eerr)
	exec.free_result(r)

	// Adopted close must refuse while fenced (engine stays open for recovery).
	cerr := exec.session_close(&s)
	testing.expect(t, exec.has_error(cerr))
	exec.free_error(cerr)
	testing.expect(t, !s.closed)
	testing.expect(t, e.in_txn)

	pager.flush_fail_after_data_writes = 0
	r2, e2 := exec.exec_statement(&s, "COMMIT;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect(t, !s.explicit_txn)
	testing.expect(t, !s.txn_aborted)
	testing.expect(t, !e.in_txn)
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_statement(&s, "SELECT id, n FROM t;")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, r3.kind, exec.Result_Kind.Result_Set)
	testing.expect_value(t, len(r3.rows), 1)
	exec.free_error(e3)
	exec.free_result(r3)

	testing.expectf(t, !exec.has_error(exec.session_close(&s)), "adopted close after recovery")
}

@(test)
test_exec_explicit_commit_flush_failed_keeps_txn :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer {
		pager := engine.engine_pager_unsafe_for_tests(&e)
		if pager != nil {
			pager.flush_fail_after_data_writes = 0
			if e.in_txn {
				_ = engine.txn_commit(&e)
			}
		}
		_ = engine.engine_close(&e)
	}
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT); BEGIN; INSERT INTO t VALUES (1, 'a');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)
	testing.expect(t, s.explicit_txn)

	pager := engine.engine_pager_unsafe_for_tests(&e)
	pager.flush_fail_after_data_writes = 1

	r, eerr := exec.exec_statement(&s, "COMMIT;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect(t, strings.contains(eerr.message, "flush") || strings.contains(eerr.message, "recovery"))
	testing.expect(t, s.explicit_txn)
	testing.expect(t, e.in_txn)
	testing.expect(t, !s.txn_aborted) // must not block recovery COMMIT
	exec.free_error(eerr)
	exec.free_result(r)

	// Close refused while fenced.
	cerr := exec.session_close(&s)
	testing.expect(t, exec.has_error(cerr))
	exec.free_error(cerr)
	testing.expect(t, !s.closed)

	r2, e2 := exec.exec_statement(&s, "ROLLBACK;")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Engine)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_exec_explicit_commit_flush_failed_retries_after_clearing_hook :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer {
		pager := engine.engine_pager_unsafe_for_tests(&e)
		if pager != nil {
			pager.flush_fail_after_data_writes = 0
			if e.in_txn {
				_ = engine.txn_commit(&e)
			}
		}
		_ = engine.engine_close(&e)
	}
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT); BEGIN; INSERT INTO t VALUES (1, 'a');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	pager := engine.engine_pager_unsafe_for_tests(&e)
	pager.flush_fail_after_data_writes = 1

	r, eerr := exec.exec_statement(&s, "COMMIT;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect(t, s.explicit_txn)
	testing.expect(t, e.in_txn)
	exec.free_error(eerr)
	exec.free_result(r)

	cerr := exec.session_close(&s)
	testing.expect(t, exec.has_error(cerr))
	exec.free_error(cerr)
	testing.expect(t, !s.closed)

	pager.flush_fail_after_data_writes = 0
	r2, e2 := exec.exec_statement(&s, "COMMIT;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect(t, !s.explicit_txn)
	testing.expect(t, !e.in_txn)
	exec.free_error(e2)
	exec.free_result(r2)

	testing.expectf(t, !exec.has_error(exec.session_close(&s)), "close after explicit recovery")
}

@(test)
test_exec_commit_fence_continue_on_error_allows_recovery_commit_only :: proc(t: ^testing.T) {
	// Explicit COMMIT fence under continue_on_error must hard-stop non-recovery
	// writes but still allow a later COMMIT in the same script.
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer {
		pager := engine.engine_pager_unsafe_for_tests(&e)
		if pager != nil {
			pager.flush_fail_after_data_writes = 0
			if e.in_txn {
				_ = engine.txn_commit(&e)
			}
		}
		_ = engine.engine_close(&e)
	}
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT); BEGIN; INSERT INTO t VALUES (1, 'a');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	pager := engine.engine_pager_unsafe_for_tests(&e)
	pager.flush_fail_after_data_writes = 1

	// COMMIT fences; continue_on_error must not run the INSERT.
	r1, e1 := exec.exec_script(
		&s,
		"COMMIT; INSERT INTO t VALUES (2, 'b');",
		exec.Exec_Options{continue_on_error = true},
	)
	testing.expect(t, exec.has_error(e1))
	testing.expect(t, strings.contains(e1.message, "flush recovery") || strings.contains(e1.message, "retry COMMIT"))
	testing.expect(t, s.explicit_txn)
	testing.expect(t, e.in_txn)
	exec.free_error(e1)
	exec.free_result(r1)

	pager.flush_fail_after_data_writes = 0
	// Same-script recovery COMMIT must be allowed under continue_on_error.
	r2, e2 := exec.exec_script(
		&s,
		"COMMIT; INSERT INTO t VALUES (2, 'b');",
		exec.Exec_Options{continue_on_error = true},
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect(t, !s.explicit_txn)
	testing.expect(t, !e.in_txn)
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_statement(&s, "SELECT id FROM t ORDER BY id;")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, len(r3.rows), 2)
	exec.free_error(e3)
	exec.free_result(r3)
}

@(test)
test_exec_auto_commit_fence_continue_on_error_allows_recovery_commit_only :: proc(t: ^testing.T) {
	// Auto-commit fence under continue_on_error must hard-stop non-recovery
	// writes but still allow a later COMMIT (same as explicit COMMIT fence).
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer {
		pager := engine.engine_pager_unsafe_for_tests(&e)
		if pager != nil {
			pager.flush_fail_after_data_writes = 0
			if e.in_txn {
				_ = engine.txn_commit(&e)
			}
		}
		_ = engine.engine_close(&e)
	}
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);")
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	pager := engine.engine_pager_unsafe_for_tests(&e)
	pager.flush_fail_after_data_writes = 1

	// Auto-commit INSERT fences; continue_on_error must not run the second INSERT.
	r1, e1 := exec.exec_script(
		&s,
		"INSERT INTO t VALUES (1, 'a'); INSERT INTO t VALUES (2, 'b');",
		exec.Exec_Options{continue_on_error = true},
	)
	testing.expect(t, exec.has_error(e1))
	testing.expect(t, strings.contains(e1.message, "flush recovery") || strings.contains(e1.message, "retry COMMIT"))
	testing.expect(t, !strings.contains(e1.message, "transaction aborted"))
	testing.expect(t, s.explicit_txn)
	testing.expect(t, !s.txn_aborted)
	testing.expect(t, e.in_txn)
	testing.expect(t, exec.session_flush_fence(&s))
	exec.free_error(e1)
	exec.free_result(r1)

	pager.flush_fail_after_data_writes = 0
	// Same-script recovery COMMIT must be allowed under continue_on_error.
	r2, e2 := exec.exec_script(
		&s,
		"COMMIT; INSERT INTO t VALUES (2, 'b');",
		exec.Exec_Options{continue_on_error = true},
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect(t, !s.explicit_txn)
	testing.expect(t, !s.txn_aborted)
	testing.expect(t, !e.in_txn)
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_statement(&s, "SELECT id FROM t ORDER BY id;")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, len(r3.rows), 2)
	exec.free_error(e3)
	exec.free_result(r3)
}

@(test)
test_exec_statement_fence_hard_stops_writes_allows_commit_and_select :: proc(t: ^testing.T) {
	// Fence gate must apply to exec_statement / exec_statement_ast (not only exec_script).
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer {
		pager := engine.engine_pager_unsafe_for_tests(&e)
		if pager != nil {
			pager.flush_fail_after_data_writes = 0
			if e.in_txn {
				_ = engine.txn_commit(&e)
			}
		}
		_ = engine.engine_close(&e)
	}
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);")
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	pager := engine.engine_pager_unsafe_for_tests(&e)
	pager.flush_fail_after_data_writes = 1

	r1, e1 := exec.exec_statement(&s, "INSERT INTO t VALUES (1, 'a');")
	testing.expect(t, exec.has_error(e1))
	testing.expect(t, exec.session_flush_fence(&s))
	exec.free_error(e1)
	exec.free_result(r1)

	// Non-recovery write via exec_statement must hard-stop (no unreollable mutation).
	r2, e2 := exec.exec_statement(&s, "INSERT INTO t VALUES (2, 'b');")
	testing.expect(t, exec.has_error(e2))
	testing.expect(t, strings.contains(e2.message, "flush recovery") || strings.contains(e2.message, "retry COMMIT"))
	testing.expect(t, exec.session_flush_fence(&s))
	exec.free_error(e2)
	exec.free_result(r2)

	// Reads allowed under fence.
	r3, e3 := exec.exec_statement(&s, "SELECT id FROM t ORDER BY id;")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, r3.kind, exec.Result_Kind.Result_Set)
	exec.free_error(e3)
	exec.free_result(r3)

	pager.flush_fail_after_data_writes = 0
	r4, e4 := exec.exec_statement(&s, "COMMIT;")
	testing.expectf(t, !exec.has_error(e4), "%s", e4.message)
	testing.expect(t, !exec.session_flush_fence(&s))
	exec.free_error(e4)
	exec.free_result(r4)

	r5, e5 := exec.exec_statement(&s, "SELECT id FROM t ORDER BY id;")
	testing.expectf(t, !exec.has_error(e5), "%s", e5.message)
	testing.expect_value(t, len(r5.rows), 1)
	exec.free_error(e5)
	exec.free_result(r5)
}

@(test)
test_exec_continue_on_error_skips_until_recovery_commit :: proc(t: ^testing.T) {
	// Under continue_on_error while fenced: intervening writes are skipped; COMMIT recovers.
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer {
		pager := engine.engine_pager_unsafe_for_tests(&e)
		if pager != nil {
			pager.flush_fail_after_data_writes = 0
			if e.in_txn {
				_ = engine.txn_commit(&e)
			}
		}
		_ = engine.engine_close(&e)
	}
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT);")
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	pager := engine.engine_pager_unsafe_for_tests(&e)
	pager.flush_fail_after_data_writes = 1
	r1, e1 := exec.exec_statement(&s, "INSERT INTO t VALUES (1, 'a');")
	testing.expect(t, exec.has_error(e1))
	exec.free_error(e1)
	exec.free_result(r1)
	testing.expect(t, exec.session_flush_fence(&s))

	pager.flush_fail_after_data_writes = 0
	r2, e2 := exec.exec_script(
		&s,
		"INSERT INTO t VALUES (2, 'b'); COMMIT; INSERT INTO t VALUES (3, 'c');",
		exec.Exec_Options{continue_on_error = true},
	)
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect(t, !exec.session_flush_fence(&s))
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_statement(&s, "SELECT id FROM t ORDER BY id;")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, len(r3.rows), 2) // id 1 recovered + id 3; id 2 skipped
	if len(r3.rows) == 2 {
		testing.expect_value(t, r3.rows[0][0], "1")
		testing.expect_value(t, r3.rows[1][0], "3")
	}
	exec.free_error(e3)
	exec.free_result(r3)
}
