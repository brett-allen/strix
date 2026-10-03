package engine_tests

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import dbfile "../../dbfile"
import engine "../../engine"

@(test)
test_btree_basic_insert_get_delete :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	root: dbfile.Page_No
	tree, cerr := engine.btree_create(&e, &root)
	testing.expect(t, engine.ok(cerr))

	testing.expect(t, engine.ok(engine.btree_insert(&tree, transmute([]u8)string("b"), transmute([]u8)string("2"))))
	testing.expect(t, engine.ok(engine.btree_insert(&tree, transmute([]u8)string("a"), transmute([]u8)string("1"))))
	testing.expect(t, engine.ok(engine.btree_insert(&tree, transmute([]u8)string("c"), transmute([]u8)string("3"))))
	testing.expect_value(t, engine.btree_insert(&tree, transmute([]u8)string("a"), transmute([]u8)string("x")), engine.Engine_Error.Exists)

	payload, gerr := engine.btree_get(&tree, transmute([]u8)string("b"))
	testing.expect(t, engine.ok(gerr))
	testing.expect_value(t, string(payload), "2")
	delete(payload)

	testing.expect(t, engine.ok(engine.btree_delete(&tree, transmute([]u8)string("b"))))
	_, g2 := engine.btree_get(&tree, transmute([]u8)string("b"))
	testing.expect_value(t, g2, engine.Engine_Error.Not_Found)

	testing.expect(t, engine.ok(engine.txn_commit(&e)))
}

@(test)
test_btree_oracle_vs_map :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	root: dbfile.Page_No
	tree, cerr := engine.btree_create(&e, &root)
	testing.expect(t, engine.ok(cerr))

	ref := make(map[string]string)
	defer {
		for k, v in ref {
			delete(k)
			delete(v)
		}
		delete(ref)
	}

	keys := []string{
		"m", "b", "t", "c", "a", "z", "k", "e", "r", "d",
		"aa", "ab", "ba", "zz", "mq", "nn", "oo", "pp", "qq", "ss",
		"01", "02", "03", "04", "05", "06", "07", "08", "09", "10",
		"11", "12", "13", "14", "15", "16", "17", "18", "19", "20",
		"21", "22", "23", "24", "25", "26", "27", "28", "29", "30",
		"31", "32", "33", "34", "35", "36", "37", "38", "39", "40",
		"41", "42", "43", "44", "45", "46", "47", "48", "49", "50",
	}

	for k, i in keys {
		val := fmt.tprintf("v%d", i)
		testing.expectf(t, engine.ok(engine.btree_insert(&tree, transmute([]u8)string(k), transmute([]u8)string(val))), "insert %s", k)
		ref[strings.clone(k)] = strings.clone(val)
	}

	// Point lookups
	for k, want in ref {
		got, gerr := engine.btree_get(&tree, transmute([]u8)string(k))
		testing.expectf(t, engine.ok(gerr), "get %s: %v", k, gerr)
		testing.expect_value(t, string(got), want)
		delete(got)
	}

	// Cursor full scan vs sorted keys
	sorted := make([dynamic]string, 0, len(ref))
	defer delete(sorted)
	for k in ref {
		append(&sorted, k)
	}
	slice.sort(sorted[:])

	cur := engine.btree_cursor_init(&tree)
	defer engine.btree_cursor_close(&cur)
	testing.expect(t, engine.ok(engine.btree_seek_ge(&cur, transmute([]u8)string(""))))
	for expect_key in sorted {
		testing.expectf(t, engine.btree_cursor_valid(&cur), "expected key %s", expect_key)
		testing.expect_value(t, string(engine.btree_cursor_key(&cur)), expect_key)
		testing.expect_value(t, string(engine.btree_cursor_payload(&cur)), ref[expect_key])
		testing.expect(t, engine.ok(engine.btree_next(&cur)))
	}
	testing.expect(t, !engine.btree_cursor_valid(&cur))

	// Delete every other key
	removed := make([dynamic]string, 0, len(sorted) / 2 + 1)
	defer {
		for k in removed {
			delete(k)
		}
		delete(removed)
	}
	for i := 0; i < len(sorted); i += 2 {
		k := sorted[i]
		testing.expect(t, engine.ok(engine.btree_delete(&tree, transmute([]u8)string(k))))
		delete(ref[k])
		delete_key(&ref, k)
		append(&removed, k) // ownership of map key moves here
	}

	for k, want in ref {
		got, gerr := engine.btree_get(&tree, transmute([]u8)string(k))
		testing.expect(t, engine.ok(gerr))
		testing.expect_value(t, string(got), want)
		delete(got)
	}
	for k in removed {
		_, gerr := engine.btree_get(&tree, transmute([]u8)string(k))
		testing.expect_value(t, gerr, engine.Engine_Error.Not_Found)
	}

	testing.expect(t, engine.ok(engine.txn_commit(&e)))
}

@(test)
test_btree_reopen_durability :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-btree-durability-%d.strix", os.get_pid())
	defer os.remove(path)

	root: dbfile.Page_No
	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		testing.expect(t, engine.ok(engine.txn_begin(&e)))
		tree, cerr := engine.btree_create(&e, &root)
		testing.expect(t, engine.ok(cerr))

		for i in 0 ..< 80 {
			k := fmt.tprintf("k%03d", i)
			v := fmt.tprintf("p%03d", i)
			testing.expect(t, engine.ok(engine.btree_insert(&tree, transmute([]u8)string(k), transmute([]u8)string(v))))
		}
		testing.expect_value(t, root, engine.btree_root(&tree))
		testing.expect(t, engine.ok(engine.txn_commit(&e)))
		engine.engine_close(&e)
	}

	{
		e, err := engine.engine_open(path)
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)
		tree, cerr := engine.btree_open(&e, &root)
		testing.expect(t, engine.ok(cerr))

		payload, gerr := engine.btree_get(&tree, transmute([]u8)string("k000"))
		testing.expect(t, engine.ok(gerr))
		testing.expect_value(t, string(payload), "p000")
		delete(payload)

		payload, gerr = engine.btree_get(&tree, transmute([]u8)string("k079"))
		testing.expect(t, engine.ok(gerr))
		testing.expect_value(t, string(payload), "p079")
		delete(payload)

		cur := engine.btree_cursor_init(&tree)
		defer engine.btree_cursor_close(&cur)
		testing.expect(t, engine.ok(engine.btree_seek_ge(&cur, transmute([]u8)string("k050"))))
		testing.expect_value(t, string(engine.btree_cursor_key(&cur)), "k050")
		count := 0
		for engine.btree_cursor_valid(&cur) {
			count += 1
			testing.expect(t, engine.ok(engine.btree_next(&cur)))
		}
		testing.expect_value(t, count, 30) // k050..k079
	}
}

@(test)
test_btree_seek_ge_and_range :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	root: dbfile.Page_No
	tree, _ := engine.btree_create(&e, &root)

	for k in ([]string{"a", "c", "e", "g", "i"}) {
		testing.expect(t, engine.ok(engine.btree_insert(&tree, transmute([]u8)string(k), transmute([]u8)string(k))))
	}

	cur := engine.btree_cursor_init(&tree)
	defer engine.btree_cursor_close(&cur)
	testing.expect(t, engine.ok(engine.btree_seek_ge(&cur, transmute([]u8)string("d"))))
	testing.expect_value(t, string(engine.btree_cursor_key(&cur)), "e")
	testing.expect(t, engine.ok(engine.btree_next(&cur)))
	testing.expect_value(t, string(engine.btree_cursor_key(&cur)), "g")

	testing.expect(t, engine.ok(engine.txn_commit(&e)))
}

@(test)
test_btree_insert_requires_txn :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	root: dbfile.Page_No
	tree, _ := engine.btree_create(&e, &root)
	testing.expect(t, engine.ok(engine.txn_commit(&e)))
	testing.expect_value(t,
		engine.btree_insert(&tree, transmute([]u8)string("a"), transmute([]u8)string("1")),
		engine.Engine_Error.No_Txn,
	)
}

@(test)
test_btree_split_size_aware_avoids_bad_count_mid :: proc(t: ^testing.T) {
	// page_size=1024, hpay≈480, 12 tinies: 14th cell forces split; count-mid=7 overflows.
	PAGE :: 1024
	HPAY :: 480
	NT :: 12

	e, err := engine.engine_open_memory({db = {page_size = PAGE}})
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	root: dbfile.Page_No
	tree, cerr := engine.btree_create(&e, &root)
	testing.expect(t, engine.ok(cerr))

	root_before := engine.btree_root(&tree)
	kind0, k0err := engine.btree_page_kind(&e, root_before)
	testing.expect(t, engine.ok(k0err))
	testing.expect_value(t, kind0, engine.BTREE_PAGE_LEAF)

	huge := make([]u8, HPAY)
	defer delete(huge)
	for i in 0 ..< HPAY {
		huge[i] = u8('H')
	}
	tiny := transmute([]u8)string("x")

	testing.expect(t, engine.ok(engine.btree_insert(&tree, transmute([]u8)string("a"), huge)))
	for i in 0 ..< NT {
		k := fmt.tprintf("b%02d", i) // b00..b11 (12 keys, all > "a2" lexicographically)
		testing.expectf(t, engine.ok(engine.btree_insert(&tree, transmute([]u8)string(k), tiny)), "tiny %s", k)
	}
	// 13 cells still on one leaf (nosplit).
	testing.expect_value(t, engine.btree_root(&tree), root_before)
	kind1, _ := engine.btree_page_kind(&e, root_before)
	testing.expect_value(t, kind1, engine.BTREE_PAGE_LEAF)

	// 14th cell forces split; count-mid=7 would overflow left side.
	testing.expect(t, engine.ok(engine.btree_insert(&tree, transmute([]u8)string("a2"), huge)))

	root_after := engine.btree_root(&tree)
	testing.expectf(t, root_after != root_before, "root must change after root-leaf split (was %v now %v)", root_before, root_after)
	testing.expect_value(t, root, root_after) // Caller_Root write-through

	kind_root, kerr := engine.btree_page_kind(&e, root_after)
	testing.expect(t, engine.ok(kerr))
	testing.expect_value(t, kind_root, engine.BTREE_PAGE_INTERIOR)

	left_leaf, lerr := engine.btree_leftmost_leaf(&e, root_after)
	testing.expect(t, engine.ok(lerr))
	next, nerr := engine.btree_leaf_next(&e, left_leaf)
	testing.expect(t, engine.ok(nerr))
	testing.expectf(t, next != 0, "split must link leaf sibling (left=%v next=%v)", left_leaf, next)

	// All 14 keys present via cursor (proves split did not lose records).
	cur := engine.btree_cursor_init(&tree)
	defer engine.btree_cursor_close(&cur)
	testing.expect(t, engine.ok(engine.btree_seek_ge(&cur, transmute([]u8)string(""))))
	count := 0
	for engine.btree_cursor_valid(&cur) {
		count += 1
		testing.expect(t, engine.ok(engine.btree_next(&cur)))
	}
	testing.expect_value(t, count, 14)

	testing.expect(t, engine.ok(engine.txn_commit(&e)))
}

@(test)
test_btree_split_mixed_tiny_huge_oracle :: proc(t: ^testing.T) {
	// Mixed sizes that must split by bytes, not cell counts; tree stays consistent.
	e, err := engine.engine_open_memory({db = {page_size = 1024}})
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	root: dbfile.Page_No
	tree, cerr := engine.btree_create(&e, &root)
	testing.expect(t, engine.ok(cerr))

	ref := make(map[string]string)
	defer {
		for k, v in ref {
			delete(k)
			delete(v)
		}
		delete(ref)
	}

	for i in 0 ..< 40 {
		k := fmt.tprintf("%02d", i)
		payload_len := 8 if i % 3 != 0 else 180
		payload := make([]u8, payload_len)
		for j in 0 ..< payload_len {
			payload[j] = u8('0' + (i % 10))
		}
		testing.expectf(t, engine.ok(engine.btree_insert(&tree, transmute([]u8)string(k), payload)), "insert %s", k)
		ref[strings.clone(k)] = strings.clone(string(payload))
		delete(payload)
	}

	for k, want in ref {
		got, gerr := engine.btree_get(&tree, transmute([]u8)string(k))
		testing.expectf(t, engine.ok(gerr), "get %s", k)
		testing.expect_value(t, string(got), want)
		delete(got)
	}

	cur := engine.btree_cursor_init(&tree)
	defer engine.btree_cursor_close(&cur)
	sorted := make([dynamic]string, 0, len(ref))
	defer delete(sorted)
	for k in ref {
		append(&sorted, k)
	}
	slice.sort(sorted[:])
	testing.expect(t, engine.ok(engine.btree_seek_ge(&cur, transmute([]u8)string(""))))
	for expect_key in sorted {
		testing.expect(t, engine.btree_cursor_valid(&cur))
		testing.expect_value(t, string(engine.btree_cursor_key(&cur)), expect_key)
		testing.expect(t, engine.ok(engine.btree_next(&cur)))
	}
	testing.expect(t, !engine.btree_cursor_valid(&cur))
	testing.expect(t, engine.ok(engine.txn_commit(&e)))
}

@(test)
test_btree_unbound_root_split_errors :: proc(t: ^testing.T) {
	// W2: stripping root ownership must fail at root split (no silent orphan root).
	PAGE :: 512
	PAY :: 180
	e, err := engine.engine_open_memory({db = {page_size = PAGE}})
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	testing.expect(t, engine.ok(engine.txn_begin(&e)))

	root: dbfile.Page_No
	tree, cerr := engine.btree_create(&e, &root)
	testing.expect(t, engine.ok(cerr))
	root_before := root

	// Simulate wrong API: drop bind / slot (catalog_open always rebinds; this must not).
	tree.bind = .None
	tree.root_slot = nil

	payload := make([]u8, PAY)
	defer delete(payload)
	for i in 0 ..< PAY {
		payload[i] = u8('U')
	}

	saw_unbound := false
	for i in 0 ..< 20 {
		ierr := engine.btree_insert(&tree, transmute([]u8)string(fmt.tprintf("k%02d", i)), payload)
		if ierr == .Unbound_Root {
			saw_unbound = true
			break
		}
		testing.expectf(t, engine.ok(ierr), "insert before split: %v", ierr)
	}
	testing.expect(t, saw_unbound)
	// Caller-owned slot must remain the pre-split root (no silent advance).
	testing.expect_value(t, root, root_before)
	testing.expect(t, engine.ok(engine.txn_rollback(&e)))
}

@(test)
test_btree_caller_root_slot_survives_reopen :: proc(t: ^testing.T) {
	// W2: Caller_Root updates ^Page_No; reopen via that slot finds high keys.
	PAGE :: 512
	PAY :: 180
	path := fmt.tprintf("/tmp/strix-w2-caller-root-%d.strix", os.get_pid())
	defer os.remove(path)

	root: dbfile.Page_No
	n_inserted := 0
	{
		e, err := engine.engine_create(path, {db = {page_size = PAGE}})
		testing.expect(t, engine.ok(err))
		testing.expect(t, engine.ok(engine.txn_begin(&e)))
		tree, cerr := engine.btree_create(&e, &root)
		testing.expect(t, engine.ok(cerr))
		root_before := root

		payload := make([]u8, PAY)
		defer delete(payload)
		for i in 0 ..< PAY {
			payload[i] = u8('C')
		}
		for i in 0 ..< 20 {
			k := fmt.tprintf("k%02d", i)
			testing.expect(t, engine.ok(engine.btree_insert(&tree, transmute([]u8)string(k), payload)))
			n_inserted = i + 1
			if root != root_before {
				break
			}
		}
		testing.expect(t, root != root_before)
		testing.expect_value(t, root, engine.btree_root(&tree))
		testing.expect(t, engine.ok(engine.txn_commit(&e)))
		engine.engine_close(&e)
	}

	{
		e, err := engine.engine_open(path)
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)
		tree, oerr := engine.btree_open(&e, &root)
		testing.expect(t, engine.ok(oerr))
		for i in 0 ..< n_inserted {
			k := fmt.tprintf("k%02d", i)
			got, gerr := engine.btree_get(&tree, transmute([]u8)string(k))
			testing.expectf(t, engine.ok(gerr), "get %s", k)
			testing.expect_value(t, len(got), PAY)
			delete(got)
		}
	}
}
