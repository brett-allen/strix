package exec_tests

import "core:fmt"
import "core:testing"
import engine "../../engine"
import exec "../../exec"
import paging "../../paging"

freelist_len :: proc(p: ^paging.Pager) -> int {
	n := 0
	cur := p.freelist_head
	limit := int(p.page_count) + 1
	for cur != 0 && n <= limit {
		n += 1
		next, nerr := paging.peek_freelist_next(p, cur)
		if nerr != .None {
			return n
		}
		if next == cur {
			break
		}
		cur = next
	}
	return n
}

@(test)
test_drop_table_reclaims_multipage_btree :: proc(t: ^testing.T) {
	// Force a multi-page heap, then DROP TABLE must return pages to the freelist
	// (not only the root).
	PAGE :: 512
	e, err := engine.engine_open_memory({db = {page_size = PAGE}, pager = {cache_frames = 128}})
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_statement(
		&s,
		"CREATE TABLE big (id INTEGER PRIMARY KEY, payload TEXT);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	// Large text payloads force leaf splits → interior + multiple leaves.
	chunk := strings_repeat("x", 200)
	defer delete(chunk)
	for i in 1 ..= 40 {
		sql := fmt.tprintf("INSERT INTO big (id, payload) VALUES (%d, '%s');", i, chunk)
		r, eerr := exec.exec_statement(&s, sql)
		testing.expectf(t, !exec.has_error(eerr), "insert %d: %s", i, eerr.message)
		exec.free_error(eerr)
		exec.free_result(r)
	}

	root, lerr := engine.catalog_lookup_table_root(&e, "big")
	testing.expect(t, engine.ok(lerr))
	kind, kerr := engine.btree_page_kind(&e, root)
	testing.expect(t, engine.ok(kerr))
	testing.expect_value(t, kind, engine.BTREE_PAGE_INTERIOR)

	pager := engine.engine_pager_unsafe_for_tests(&e)
	free_before := freelist_len(pager)

	rd, ed := exec.exec_statement(&s, "DROP TABLE big;")
	testing.expectf(t, !exec.has_error(ed), "%s", ed.message)
	exec.free_error(ed)
	exec.free_result(rd)

	free_after := freelist_len(pager)
	testing.expectf(
		t,
		free_after >= free_before + 3,
		"expected multipage reclaim: freelist %d → %d (need ≥3 new free pages)",
		free_before,
		free_after,
	)

	// Freed pages must be reusable without growing page_count as much as a fresh alloc.
	page_count_after_drop := pager.page_count
	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	for _ in 0 ..< 3 {
		_, aerr := engine.page_alloc(&e)
		testing.expect(t, engine.ok(aerr))
	}
	testing.expect(t, engine.ok(engine.txn_rollback(&e)))
	testing.expect_value(t, pager.page_count, page_count_after_drop)
}

@(test)
test_drop_index_reclaims_multipage_btree :: proc(t: ^testing.T) {
	PAGE :: 512
	e, err := engine.engine_open_memory({db = {page_size = PAGE}, pager = {cache_frames = 128}})
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);" +
		"CREATE INDEX idx_name ON t (name);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	chunk := strings_repeat("y", 180)
	defer delete(chunk)
	for i in 1 ..= 50 {
		sql := fmt.tprintf("INSERT INTO t (id, name) VALUES (%d, '%s%d');", i, chunk, i)
		r, eerr := exec.exec_statement(&s, sql)
		testing.expectf(t, !exec.has_error(eerr), "insert %d: %s", i, eerr.message)
		exec.free_error(eerr)
		exec.free_result(r)
	}

	idx_entry, gerr := engine.catalog_get_index_entry(&e, "idx_name")
	testing.expect(t, engine.ok(gerr))
	idx_root := idx_entry.root
	engine.free_catalog_entry(idx_entry)
	kind, kerr := engine.btree_page_kind(&e, idx_root)
	testing.expect(t, engine.ok(kerr))
	testing.expect_value(t, kind, engine.BTREE_PAGE_INTERIOR)

	pager := engine.engine_pager_unsafe_for_tests(&e)
	free_before := freelist_len(pager)

	rd, ed := exec.exec_statement(&s, "DROP INDEX idx_name;")
	testing.expectf(t, !exec.has_error(ed), "%s", ed.message)
	exec.free_error(ed)
	exec.free_result(rd)

	free_after := freelist_len(pager)
	testing.expectf(
		t,
		free_after >= free_before + 3,
		"expected index multipage reclaim: freelist %d → %d",
		free_before,
		free_after,
	)
}

strings_repeat :: proc(ch: string, n: int, allocator := context.allocator) -> string {
	out := make([]u8, n * len(ch), allocator)
	for i in 0 ..< n {
		copy(out[i * len(ch):], transmute([]u8)ch)
	}
	return string(out)
}
