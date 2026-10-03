package exec_tests

import "core:fmt"
import "core:os"
import "core:testing"
import engine "../../engine"
import exec "../../exec"

@(test)
test_create_index_backfill_and_lookup :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, qty INT);" +
		"INSERT INTO items VALUES (1, 'apple', 10), (2, 'banana', 20), (3, 'cherry', 30);" +
		"CREATE INDEX items_by_name ON items (name);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	entry, gerr := engine.catalog_get_index_entry(&e, "items_by_name")
	testing.expect(t, engine.ok(gerr))
	testing.expect_value(t, entry.version, engine.CATALOG_ROW_VERSION_V2)
	testing.expect_value(t, entry.parent_table, "items")
	testing.expect_value(t, len(entry.columns), 1)
	testing.expect_value(t, entry.columns[0].name, "name")
	engine.free_catalog_entry(entry)

	// Point lookup via index
	r, eerr := exec.exec_statement(&s, "SELECT id, qty FROM items WHERE name = 'banana';")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "2")
	testing.expect_value(t, r.rows[0][1], "20")
	exec.free_error(eerr)
	exec.free_result(r)

	// Engine-level: backfill wrote index entries
	idx, oerr := engine.catalog_open_index(&e, "items_by_name")
	testing.expect(t, engine.ok(oerr))
	ikey_vals := []exec.Value{exec.value_text("apple")}
	ikey, kerr := exec.encode_index_key(ikey_vals)
	testing.expectf(t, !exec.has_error(kerr), "%s", kerr.message)
	exec.free_error(kerr)
	exec.free_value(ikey_vals[0])
	defer delete(ikey)
	rowids, rerr := engine.index_collect_rowids(&idx, ikey)
	testing.expect(t, engine.ok(rerr))
	testing.expect_value(t, len(rowids), 1)
	testing.expect_value(t, rowids[0], u64(1))
	delete(rowids)
}

// INT column + float literal must match via seq scan and with an index present
// (index keys are tag-exact; eval_compare coerces Int/Float — skip numeric point lookup).
@(test)
test_numeric_eq_index_matches_seq_scan :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE items (id INTEGER PRIMARY KEY, qty INT);" +
		"INSERT INTO items VALUES (1, 20);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r_seq, e_seq := exec.exec_statement(&s, "SELECT id FROM items WHERE qty = 20.0;")
	testing.expectf(t, !exec.has_error(e_seq), "%s", e_seq.message)
	testing.expect_value(t, len(r_seq.rows), 1)
	testing.expect_value(t, r_seq.rows[0][0], "1")
	exec.free_error(e_seq)
	exec.free_result(r_seq)

	r_idx, e_idx := exec.exec_script(
		&s,
		"CREATE INDEX items_by_qty ON items (qty);" +
		"SELECT id FROM items WHERE qty = 20.0;",
	)
	testing.expectf(t, !exec.has_error(e_idx), "%s", e_idx.message)
	testing.expect_value(t, len(r_idx.rows), 1)
	testing.expect_value(t, r_idx.rows[0][0], "1")
	exec.free_error(e_idx)
	exec.free_result(r_idx)
}

@(test)
test_insert_maintains_index :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);" +
		"CREATE INDEX t_name ON t (name);" +
		"INSERT INTO t VALUES (1, 'a'), (2, 'b');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(&s, "SELECT id FROM t WHERE name = 'b';")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "2")
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_update_delete_maintain_index :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);" +
		"INSERT INTO t VALUES (1, 'old'), (2, 'keep');" +
		"CREATE INDEX t_name ON t (name);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(&s, "UPDATE t SET name = 'new' WHERE id = 1;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, r.rows_affected, 1)
	exec.free_error(eerr)
	exec.free_result(r)

	r2, e2 := exec.exec_statement(&s, "SELECT id FROM t WHERE name = 'old';")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 0)
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_statement(&s, "SELECT id FROM t WHERE name = 'new';")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	testing.expect_value(t, len(r3.rows), 1)
	testing.expect_value(t, r3.rows[0][0], "1")
	exec.free_error(e3)
	exec.free_result(r3)

	r4, e4 := exec.exec_statement(&s, "DELETE FROM t WHERE name = 'keep';")
	testing.expectf(t, !exec.has_error(e4), "%s", e4.message)
	testing.expect_value(t, r4.rows_affected, 1)
	exec.free_error(e4)
	exec.free_result(r4)

	r5, e5 := exec.exec_statement(&s, "SELECT id FROM t WHERE name = 'keep';")
	testing.expectf(t, !exec.has_error(e5), "%s", e5.message)
	testing.expect_value(t, len(r5.rows), 0)
	exec.free_error(e5)
	exec.free_result(r5)
}

@(test)
test_drop_index_and_drop_table_policy :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (a INT);" +
		"CREATE INDEX t_a ON t (a);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	// DROP TABLE still rejects while indexes remain
	rd, ed := exec.exec_statement(&s, "DROP TABLE t;")
	testing.expect(t, exec.has_error(ed))
	testing.expect_value(t, ed.code, exec.Exec_Error_Code.Has_Indexes)
	exec.free_error(ed)
	exec.free_result(rd)

	r1, e1 := exec.exec_statement(&s, "DROP INDEX t_a;")
	testing.expectf(t, !exec.has_error(e1), "%s", e1.message)
	exec.free_error(e1)
	exec.free_result(r1)

	_, gerr := engine.catalog_get_index_entry(&e, "t_a")
	testing.expect_value(t, gerr, engine.Engine_Error.Not_Found)

	r2, e2 := exec.exec_statement(&s, "DROP TABLE t;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_create_drop_index_if_exists_flags :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_statement(&s, "CREATE TABLE t (a INT);")
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)
	exec.free_result(r0)

	r1, e1 := exec.exec_statement(&s, "CREATE INDEX t_a ON t (a);")
	testing.expect(t, !exec.has_error(e1))
	exec.free_error(e1)
	exec.free_result(r1)

	r2, e2 := exec.exec_statement(&s, "CREATE INDEX t_a ON t (a);")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Index_Exists)
	exec.free_error(e2)
	exec.free_result(r2)

	r3, e3 := exec.exec_statement(&s, "CREATE INDEX IF NOT EXISTS t_a ON t (a);")
	testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
	exec.free_error(e3)
	exec.free_result(r3)

	r4, e4 := exec.exec_statement(&s, "DROP INDEX missing;")
	testing.expect(t, exec.has_error(e4))
	testing.expect_value(t, e4.code, exec.Exec_Error_Code.Unknown_Index)
	exec.free_error(e4)
	exec.free_result(r4)

	r5, e5 := exec.exec_statement(&s, "DROP INDEX IF EXISTS missing;")
	testing.expectf(t, !exec.has_error(e5), "%s", e5.message)
	exec.free_error(e5)
	exec.free_result(r5)
}

@(test)
test_create_index_unknown_table_column :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r, eerr := exec.exec_statement(&s, "CREATE INDEX i ON nope (a);")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unknown_Table)
	exec.free_error(eerr)
	exec.free_result(r)

	r0, e0 := exec.exec_statement(&s, "CREATE TABLE t (a INT);")
	testing.expect(t, !exec.has_error(e0))
	exec.free_error(e0)
	exec.free_result(r0)

	r2, e2 := exec.exec_statement(&s, "CREATE INDEX i ON t (missing);")
	testing.expect(t, exec.has_error(e2))
	testing.expect_value(t, e2.code, exec.Exec_Error_Code.Unknown_Column)
	exec.free_error(e2)
	exec.free_result(r2)
}

@(test)
test_index_durable_reopen :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-e5-index-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		s := exec.session_adopt(&e)
		r, eerr := exec.exec_script(
			&s,
			"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);" +
			"INSERT INTO t VALUES (1, 'x'), (2, 'y');" +
			"CREATE INDEX t_name ON t (name);" +
			"INSERT INTO t VALUES (3, 'z');",
		)
		testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
		exec.free_error(eerr)
		exec.free_result(r)
		exec.session_close(&s)
		engine.engine_close(&e)
	}

	{
		e, err := engine.engine_open(path)
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)
		s := exec.session_adopt(&e)

		entry, gerr := engine.catalog_get_index_entry(&e, "t_name")
		testing.expect(t, engine.ok(gerr))
		testing.expect_value(t, len(entry.columns), 1)
		testing.expect_value(t, entry.columns[0].name, "name")
		engine.free_catalog_entry(entry)

		r, eerr := exec.exec_statement(&s, "SELECT id FROM t WHERE name = 'z';")
		testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
		testing.expect_value(t, len(r.rows), 1)
		testing.expect_value(t, r.rows[0][0], "3")
		exec.free_error(eerr)
		exec.free_result(r)

		r2, e2 := exec.exec_statement(&s, "UPDATE t SET name = 'zz' WHERE id = 3;")
		testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
		exec.free_error(e2)
		exec.free_result(r2)

		r3, e3 := exec.exec_statement(&s, "SELECT id FROM t WHERE name = 'zz';")
		testing.expectf(t, !exec.has_error(e3), "%s", e3.message)
		testing.expect_value(t, len(r3.rows), 1)
		exec.free_error(e3)
		exec.free_result(r3)
	}
}

@(test)
test_encode_decode_catalog_index_v2 :: proc(t: ^testing.T) {
	entry := engine.Catalog_Entry{
		version      = engine.CATALOG_ROW_VERSION_V2,
		kind         = .Index,
		root         = 11,
		parent_table = "users",
		columns      = []engine.Catalog_Column{
			{name = "name", flags = {.Desc}},
			{name = "id"},
		},
	}
	buf := engine.encode_catalog_row(entry)
	testing.expect(t, buf != nil)
	defer delete(buf)
	testing.expect_value(t, buf[0], engine.CATALOG_ROW_VERSION_V2)

	got, err := engine.decode_catalog_row(buf)
	testing.expect(t, engine.ok(err))
	defer engine.free_catalog_entry(got)
	testing.expect_value(t, got.version, engine.CATALOG_ROW_VERSION_V2)
	testing.expect_value(t, got.parent_table, "users")
	testing.expect_value(t, len(got.columns), 2)
	testing.expect_value(t, got.columns[0].name, "name")
	testing.expect(t, .Desc in got.columns[0].flags)
	testing.expect_value(t, got.columns[1].name, "id")
	testing.expect(t, .Desc not_in got.columns[1].flags)
}

@(test)
test_index_delete_entry_and_collect :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	_, _ = engine.catalog_register_table(&e, "t", []engine.Catalog_Column{{name = "n", type_name = "TEXT"}})
	cols := []engine.Catalog_Column{{name = "n"}}
	_, ierr := engine.catalog_register_index(&e, "t_n", "t", cols)
	testing.expect(t, engine.ok(ierr))

	idx, oerr := engine.catalog_open_index(&e, "t_n")
	testing.expect(t, engine.ok(oerr))
	v := exec.value_text("a")
	ikey, kerr := exec.encode_index_key([]exec.Value{v})
	exec.free_value(v)
	testing.expect(t, !exec.has_error(kerr))
	exec.free_error(kerr)
	defer delete(ikey)

	testing.expect(t, engine.ok(engine.index_insert_entry(&idx, ikey, 7)))
	testing.expect(t, engine.ok(engine.index_lookup_rowid(&idx, ikey, 7)))
	rowids, rerr := engine.index_collect_rowids(&idx, ikey)
	testing.expect(t, engine.ok(rerr))
	testing.expect_value(t, len(rowids), 1)
	testing.expect_value(t, rowids[0], u64(7))
	delete(rowids)

	testing.expect(t, engine.ok(engine.index_delete_entry(&idx, ikey, 7)))
	testing.expect_value(t, engine.index_lookup_rowid(&idx, ikey, 7), engine.Engine_Error.Not_Found)
	testing.expect(t, engine.ok(engine.txn_commit(&e)))
}

@(test)
test_create_index_closed_session :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	exec.session_close(&s)

	r, eerr := exec.exec_statement(&s, "CREATE INDEX i ON t (a);")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Closed)
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_multi_column_index_create_backfill_and_insert_maintain :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b TEXT);" +
		"INSERT INTO t VALUES (1, 'x', 'y'), (2, 'x', 'z');" +
		"CREATE INDEX t_ab ON t (a, b);" +
		"INSERT INTO t VALUES (3, 'p', 'q');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	entry, gerr := engine.catalog_get_index_entry(&e, "t_ab")
	testing.expect(t, engine.ok(gerr))
	testing.expect_value(t, len(entry.columns), 2)
	testing.expect_value(t, entry.columns[0].name, "a")
	testing.expect_value(t, entry.columns[1].name, "b")
	engine.free_catalog_entry(entry)

	idx, oerr := engine.catalog_open_index(&e, "t_ab")
	testing.expect(t, engine.ok(oerr))

	// Backfill wrote (x,y)→1; INSERT maintain wrote (p,q)→3
	v_xy := []exec.Value{exec.value_text("x"), exec.value_text("y")}
	ikey_xy, kxy := exec.encode_index_key(v_xy)
	testing.expectf(t, !exec.has_error(kxy), "%s", kxy.message)
	exec.free_error(kxy)
	exec.free_value(v_xy[0])
	exec.free_value(v_xy[1])
	defer delete(ikey_xy)
	rowids_xy, rxy := engine.index_collect_rowids(&idx, ikey_xy)
	testing.expect(t, engine.ok(rxy))
	testing.expect_value(t, len(rowids_xy), 1)
	testing.expect_value(t, rowids_xy[0], u64(1))
	delete(rowids_xy)

	v_pq := []exec.Value{exec.value_text("p"), exec.value_text("q")}
	ikey_pq, kpq := exec.encode_index_key(v_pq)
	testing.expectf(t, !exec.has_error(kpq), "%s", kpq.message)
	exec.free_error(kpq)
	exec.free_value(v_pq[0])
	exec.free_value(v_pq[1])
	defer delete(ikey_pq)
	rowids_pq, rpq := engine.index_collect_rowids(&idx, ikey_pq)
	testing.expect(t, engine.ok(rpq))
	testing.expect_value(t, len(rowids_pq), 1)
	testing.expect_value(t, rowids_pq[0], u64(3))
	delete(rowids_pq)

	// SELECT remains correct (seq scan; multi-col point lookup optional)
	r, eerr := exec.exec_statement(&s, "SELECT id FROM t WHERE a = 'x' AND b = 'z';")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "2")
	exec.free_error(eerr)
	exec.free_result(r)
}

// Index probe policy: fall back to seq scan only when cleanly no usable index
// (e.g. numeric eq skipped; no matching single-col index). Real Engine/Io errors
// from catalog_indexes_on_table / open / encode / collect must propagate (see exec_select).
@(test)
test_index_probe_falls_back_only_when_no_usable_index :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, qty INT);" +
		"INSERT INTO items VALUES (1, 'a', 10);" +
		"CREATE INDEX items_by_name ON items (name);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	// No usable index for qty (numeric eq skipped) → seq scan still correct
	r, eerr := exec.exec_statement(&s, "SELECT id FROM items WHERE qty = 10;")
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect_value(t, r.rows[0][0], "1")
	exec.free_error(eerr)
	exec.free_result(r)

	// Text eq on indexed col → index path (usable)
	r2, e2 := exec.exec_statement(&s, "SELECT id FROM items WHERE name = 'a';")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	testing.expect_value(t, r2.rows[0][0], "1")
	exec.free_error(e2)
	exec.free_result(r2)
}
