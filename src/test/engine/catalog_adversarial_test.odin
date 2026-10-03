package engine_tests

import "core:fmt"
import "core:os"
import "core:testing"
import dbfile "../../dbfile"
import engine "../../engine"

@(test)
test_user_table_root_split_persists_catalog_reopen :: proc(t: ^testing.T) {
	// C1: after user-table root split, catalog root must update; reopen sees high keys.
	PAGE :: 512
	PAY :: 180
	N :: 20
	path := fmt.tprintf("/tmp/strix-c1-root-split-%d.strix", os.get_pid())
	defer os.remove(path)

	live_root_after: dbfile.Page_No
	root_before: dbfile.Page_No
	n_inserted := 0

	{
		e, err := engine.engine_create(path, {db = {page_size = PAGE}, pager = {cache_frames = 64}})
		testing.expectf(t, engine.ok(err), "create: %v", err)
		testing.expect(t, engine.ok(engine.txn_begin(&e)))
		reg_root, rerr := engine.catalog_register_table(&e, "big")
		testing.expect(t, engine.ok(rerr))
		tbl, oerr := engine.catalog_open_table(&e, "big")
		testing.expect(t, engine.ok(oerr))
		root_before = engine.btree_root(&tbl)
		testing.expect_value(t, root_before, reg_root)

		payload := make([]u8, PAY)
		defer delete(payload)
		for i in 0 ..< PAY {
			payload[i] = u8('P')
		}

		for i in 0 ..< N {
			testing.expectf(t, engine.ok(engine.table_insert_row(&tbl, u64(i + 1), payload)), "insert %d", i+1)
			n_inserted = i + 1
			if engine.btree_root(&tbl) != root_before {
				break
			}
		}
		live_root_after = engine.btree_root(&tbl)
		testing.expectf(t, live_root_after != root_before, "root must split after inserts (still %v)", root_before)

		cat_root, lerr := engine.catalog_lookup_table_root(&e, "big")
		testing.expect(t, engine.ok(lerr))
		testing.expect_value(t, cat_root, live_root_after)

		kind, kerr := engine.btree_page_kind(&e, live_root_after)
		testing.expect(t, engine.ok(kerr))
		testing.expect_value(t, kind, engine.BTREE_PAGE_INTERIOR)

		testing.expect(t, engine.ok(engine.txn_commit(&e)))
		engine.engine_close(&e)
	}

	{
		e, err := engine.engine_open(path)
		testing.expectf(t, engine.ok(err), "reopen: %v", err)
		defer engine.engine_close(&e)

		cat_root, lerr := engine.catalog_lookup_table_root(&e, "big")
		testing.expect(t, engine.ok(lerr))
		testing.expect_value(t, cat_root, live_root_after)

		tbl, oerr := engine.catalog_open_table(&e, "big")
		testing.expect(t, engine.ok(oerr))
		testing.expect_value(t, engine.btree_root(&tbl), live_root_after)

		// Point-get every inserted rowid, including the highest.
		for i in 1 ..= n_inserted {
			got, gerr := engine.table_get_row(&tbl, u64(i))
			testing.expectf(t, engine.ok(gerr), "get rowid %d: %v", i, gerr)
			testing.expect_value(t, len(got), PAY)
			delete(got)
		}

		cur := engine.btree_cursor_init(&tbl)
		defer engine.btree_cursor_close(&cur)
		testing.expect(t, engine.ok(engine.btree_seek_ge(&cur, transmute([]u8)string(""))))
		count := 0
		for engine.btree_cursor_valid(&cur) {
			count += 1
			testing.expect(t, engine.ok(engine.btree_next(&cur)))
		}
		testing.expect_value(t, count, n_inserted)
	}
}

@(test)
test_root_publish_rolls_back_on_catalog_update_fail :: proc(t: ^testing.T) {
	// If catalog_update_root fails after allocating a new interior root, handle/catalog
	// must stay on the old root and the orphan interior must be freed (no poison).
	PAGE :: 512
	PAY :: 180
	e, err := engine.engine_open_memory({db = {page_size = PAGE}, pager = {cache_frames = 64}})
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	reg_root, rerr := engine.catalog_register_table(&e, "big")
	testing.expect(t, engine.ok(rerr))
	tbl, oerr := engine.catalog_open_table(&e, "big")
	testing.expect(t, engine.ok(oerr))
	root_before := engine.btree_root(&tbl)
	testing.expect_value(t, root_before, reg_root)

	// Poison bind *before* any root-changing split so write-through fails.
	testing.expect(t, engine.ok(engine.btree_bind_catalog_key(&tbl, transmute([]u8)string("table:missing"))))

	payload := make([]u8, PAY)
	defer delete(payload)
	for i in 0 ..< PAY {
		payload[i] = u8('R')
	}

	n_ok := 0
	saw_fail := false
	fail_rowid: u64
	for i in 0 ..< 30 {
		rowid := u64(i + 1)
		ierr := engine.table_insert_row(&tbl, rowid, payload)
		if ierr == .Not_Found {
			saw_fail = true
			fail_rowid = rowid
			break
		}
		testing.expectf(t, engine.ok(ierr), "pre-split insert %d: %v", i + 1, ierr)
		testing.expect_value(t, engine.btree_root(&tbl), root_before)
		n_ok = i + 1
	}
	testing.expect(t, saw_fail)
	testing.expect(t, n_ok >= 1)

	// Handle must not have advanced; catalog still names the old leaf root.
	testing.expect_value(t, engine.btree_root(&tbl), root_before)
	cat_root, lerr := engine.catalog_lookup_table_root(&e, "big")
	testing.expect(t, engine.ok(lerr))
	testing.expect_value(t, cat_root, root_before)

	kind, kerr := engine.btree_page_kind(&e, root_before)
	testing.expect(t, engine.ok(kerr))
	testing.expect_value(t, kind, engine.BTREE_PAGE_LEAF)

	// Restored single leaf must not link a sibling (freed during rollback).
	next, nerr := engine.btree_leaf_next(&e, root_before)
	testing.expect(t, engine.ok(nerr))
	testing.expect_value(t, next, dbfile.Page_No(0))

	// Prior rows intact via a correctly bound open; failed row absent.
	tbl2, o2 := engine.catalog_open_table(&e, "big")
	testing.expect(t, engine.ok(o2))
	testing.expect_value(t, engine.btree_root(&tbl2), root_before)
	for i in 1 ..= n_ok {
		got, gerr := engine.table_get_row(&tbl2, u64(i))
		testing.expectf(t, engine.ok(gerr), "row %d", i)
		testing.expect_value(t, len(got), PAY)
		delete(got)
	}
	_, missing := engine.table_get_row(&tbl2, fail_rowid)
	testing.expect_value(t, missing, engine.Engine_Error.Not_Found)

	testing.expect(t, engine.ok(engine.txn_rollback(&e)))
}

@(test)
test_table_prime_root_split_persists_all_tables :: proc(t: ^testing.T) {
	// C2: many registrations force table_prime root split; reopen finds every name.
	PAGE :: 512
	path := fmt.tprintf("/tmp/strix-c2-prime-split-%d.strix", os.get_pid())
	defer os.remove(path)

	N :: 40
	names := make([]string, N)
	defer {
		for n in names {
			delete(n)
		}
		delete(names)
	}

	prime_before: dbfile.Page_No
	prime_after: dbfile.Page_No

	{
		e, err := engine.engine_create(path, {db = {page_size = PAGE}, pager = {cache_frames = 128}})
		testing.expectf(t, engine.ok(err), "create: %v", err)
		prime_before = engine.table_prime_root(&e)
		testing.expect(t, prime_before != 0)

		testing.expect(t, engine.ok(engine.txn_begin(&e)))
		for i in 0 ..< N {
			names[i] = fmt.aprintf("t%03d", i)
			_, rerr := engine.catalog_register_table(&e, names[i])
			testing.expectf(t, engine.ok(rerr), "register %s: %v", names[i], rerr)
		}
		prime_after = engine.table_prime_root(&e)
		testing.expectf(t, prime_after != prime_before, "table_prime root must split (was %v)", prime_before)
		testing.expect(t, engine.ok(engine.txn_commit(&e)))

		boot, berr := dbfile.read_bootstrap(&e.pager.file)
		testing.expect(t, dbfile.ok(berr))
		testing.expect_value(t, boot.table_prime_root, prime_after)
		engine.engine_close(&e)
	}

	{
		e, err := engine.engine_open(path)
		testing.expectf(t, engine.ok(err), "reopen: %v", err)
		defer engine.engine_close(&e)
		testing.expect_value(t, engine.table_prime_root(&e), prime_after)

		for i in 0 ..< N {
			tbl, oerr := engine.catalog_open_table(&e, names[i])
			testing.expectf(t, engine.ok(oerr), "open %s: %v", names[i], oerr)
			root, lerr := engine.catalog_lookup_table_root(&e, names[i])
			testing.expect(t, engine.ok(lerr))
			testing.expect_value(t, root, engine.btree_root(&tbl))
		}
	}
}

@(test)
test_index_root_split_persists_catalog_reopen :: proc(t: ^testing.T) {
	// W1: secondary index root split must write through catalog; reopen finds early+late keys.
	PAGE :: 512
	KLEN :: 100
	N :: 20
	path := fmt.tprintf("/tmp/strix-w1-index-root-split-%d.strix", os.get_pid())
	defer os.remove(path)

	live_root_after: dbfile.Page_No
	root_before: dbfile.Page_No
	n_inserted := 0

	{
		e, err := engine.engine_create(path, {db = {page_size = PAGE}, pager = {cache_frames = 64}})
		testing.expectf(t, engine.ok(err), "create: %v", err)
		testing.expect(t, engine.ok(engine.txn_begin(&e)))
		_, rerr := engine.catalog_register_table(&e, "users")
		testing.expect(t, engine.ok(rerr))
		reg_root, ierr := engine.catalog_register_index(&e, "users_by_name", "users")
		testing.expect(t, engine.ok(ierr))

		idx, oerr := engine.catalog_open_index(&e, "users_by_name")
		testing.expect(t, engine.ok(oerr))
		root_before = engine.btree_root(&idx)
		testing.expect_value(t, root_before, reg_root)

		ikey := make([]u8, KLEN)
		defer delete(ikey)
		for i in 0 ..< KLEN {
			ikey[i] = u8('A')
		}

		for i in 0 ..< N {
			ikey[KLEN - 1] = u8('0' + (i % 10))
			ikey[KLEN - 2] = u8('0' + (i / 10))
			testing.expectf(t, engine.ok(engine.index_insert_entry(&idx, ikey, u64(i + 1))), "insert %d", i)
			n_inserted = i + 1
			if engine.btree_root(&idx) != root_before {
				break
			}
		}
		live_root_after = engine.btree_root(&idx)
		testing.expectf(t, live_root_after != root_before, "index root must split (still %v)", root_before)

		// Catalog write-through: fresh open in same txn sees new root.
		idx2, o2 := engine.catalog_open_index(&e, "users_by_name")
		testing.expect(t, engine.ok(o2))
		testing.expect_value(t, engine.btree_root(&idx2), live_root_after)

		kind, kerr := engine.btree_page_kind(&e, live_root_after)
		testing.expect(t, engine.ok(kerr))
		testing.expect_value(t, kind, engine.BTREE_PAGE_INTERIOR)

		testing.expect(t, engine.ok(engine.txn_commit(&e)))
		engine.engine_close(&e)
	}

	{
		e, err := engine.engine_open(path)
		testing.expectf(t, engine.ok(err), "reopen: %v", err)
		defer engine.engine_close(&e)

		idx, oerr := engine.catalog_open_index(&e, "users_by_name")
		testing.expect(t, engine.ok(oerr))
		testing.expect_value(t, engine.btree_root(&idx), live_root_after)

		ikey := make([]u8, KLEN)
		defer delete(ikey)
		for i in 0 ..< KLEN {
			ikey[i] = u8('A')
		}
		// Early and late entries.
		for i in ([]int{0, n_inserted - 1}) {
			ikey[KLEN - 1] = u8('0' + (i % 10))
			ikey[KLEN - 2] = u8('0' + (i / 10))
			testing.expectf(t, engine.ok(engine.index_lookup_rowid(&idx, ikey, u64(i + 1))), "lookup %d", i)
		}
		for i in 0 ..< n_inserted {
			ikey[KLEN - 1] = u8('0' + (i % 10))
			ikey[KLEN - 2] = u8('0' + (i / 10))
			testing.expectf(t, engine.ok(engine.index_lookup_rowid(&idx, ikey, u64(i + 1))), "lookup all %d", i)
		}
	}
}

@(test)
test_schema_cookie_survives_commit_reopen :: proc(t: ^testing.T) {
	// W3: schema_cookie bumped in-txn is durable after commit + reopen.
	path := fmt.tprintf("/tmp/strix-w3-schema-cookie-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		testing.expect_value(t, engine.schema_cookie(&e), u32(0))
		testing.expect(t, engine.ok(engine.txn_begin(&e)))
		_, r1 := engine.catalog_register_table(&e, "a")
		testing.expect(t, engine.ok(r1))
		_, r2 := engine.catalog_register_table(&e, "b")
		testing.expect(t, engine.ok(r2))
		testing.expect_value(t, engine.schema_cookie(&e), u32(2))
		testing.expect(t, engine.ok(engine.txn_commit(&e)))

		boot, berr := dbfile.read_bootstrap(&e.pager.file)
		testing.expect(t, dbfile.ok(berr))
		testing.expect_value(t, boot.schema_cookie, u32(2))
		engine.engine_close(&e)
	}

	{
		e, err := engine.engine_open(path)
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)
		testing.expect_value(t, engine.schema_cookie(&e), u32(2))
		boot, berr := dbfile.read_bootstrap(&e.pager.file)
		testing.expect(t, dbfile.ok(berr))
		testing.expect_value(t, boot.schema_cookie, u32(2))
	}
}

@(test)
test_engine_rollback_refused_after_flush_failed :: proc(t: ^testing.T) {
	// Engine-level H2: txn_rollback maps pager flush fence to .Flush_Failed.
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	pn, _ := engine.page_alloc(&e)
	testing.expect(t, engine.ok(engine.page_write_prefix(&e, pn, {0xAB})))
	pn2, _ := engine.page_alloc(&e)
	testing.expect(t, engine.ok(engine.page_write_prefix(&e, pn2, {0xCD})))

	pager := engine.engine_pager_unsafe_for_tests(&e)
	testing.expect(t, pager != nil)
	pager.flush_fail_after_data_writes = 1
	cerr := engine.txn_commit(&e)
	testing.expect_value(t, cerr, engine.Engine_Error.Flush_Failed)

	rerr := engine.txn_rollback(&e)
	testing.expect_value(t, rerr, engine.Engine_Error.Flush_Failed)

	// Clear fence via successful flush/commit path.
	pager.flush_fail_after_data_writes = 0
	testing.expect(t, engine.ok(engine.txn_commit(&e)))
}

@(test)
test_schema_cookie_and_prime_root_restore_on_rollback :: proc(t: ^testing.T) {
	// H1: schema_cookie and table_prime_root snapshotted at begin, restored on rollback.
	PAGE :: 512
	e, err := engine.engine_open_memory({db = {page_size = PAGE}, pager = {cache_frames = 128}})
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	testing.expect_value(t, engine.schema_cookie(&e), u32(0))
	prime0 := engine.table_prime_root(&e)

	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	_, rerr := engine.catalog_register_table(&e, "users")
	testing.expect(t, engine.ok(rerr))
	testing.expect_value(t, engine.schema_cookie(&e), u32(1))
	testing.expect(t, engine.ok(engine.txn_rollback(&e)))
	testing.expect_value(t, engine.schema_cookie(&e), u32(0))
	testing.expect_value(t, engine.table_prime_root(&e), prime0)

	// Prime root change rolled back.
	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	for i in 0 ..< 40 {
		name := fmt.tprintf("r%03d", i)
		_, rr := engine.catalog_register_table(&e, name)
		testing.expectf(t, engine.ok(rr), "register %s", name)
	}
	testing.expect(t, engine.table_prime_root(&e) != prime0)
	testing.expect(t, engine.schema_cookie(&e) > 0)
	testing.expect(t, engine.ok(engine.txn_rollback(&e)))
	testing.expect_value(t, engine.table_prime_root(&e), prime0)
	testing.expect_value(t, engine.schema_cookie(&e), u32(0))

	_, missing := engine.catalog_open_table(&e, "r000")
	testing.expect_value(t, missing, engine.Engine_Error.Not_Found)
}
