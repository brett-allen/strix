package paging_tests

import "core:fmt"
import "core:os"
import "core:testing"
import dbfile "../../dbfile"
import paging "../../paging"

@(test)
test_cache_hit_miss :: proc(t: ^testing.T) {
	p, err := paging.pager_open_memory({cache_frames = 2})
	testing.expectf(t, paging.ok(err), "open: %v", err)
	defer paging.pager_close(&p)

	a, aerr := paging.alloc_page(&p)
	testing.expect(t, paging.ok(aerr))
	da, gerr := paging.get_readwrite(&p, a)
	testing.expect(t, paging.ok(gerr))
	da[0] = 0x11
	paging.unpin(&p, a)
	testing.expect(t, paging.ok(paging.flush(&p, {})))

	b, berr := paging.alloc_page(&p)
	testing.expect(t, paging.ok(berr))
	db, g2 := paging.get_readwrite(&p, b)
	testing.expect(t, paging.ok(g2))
	db[0] = 0x22
	paging.unpin(&p, b)
	testing.expect(t, paging.ok(paging.flush(&p, {})))

	// Third page forces eviction from the 2-frame cache once flushed/clean.
	c, cerr := paging.alloc_page(&p)
	testing.expect(t, paging.ok(cerr))
	dc, g3 := paging.get_readonly(&p, c)
	testing.expect(t, paging.ok(g3))
	paging.unpin(&p, c)
	testing.expect(t, paging.ok(paging.flush(&p, {})))

	// Make b+c MRU so `a` is the eviction victim if still cached.
	for pn in ([]dbfile.Page_No{b, c}) {
		d, ge := paging.get_readonly(&p, pn)
		testing.expect(t, paging.ok(ge))
		paging.unpin(&p, pn)
	}

	p.cache_hits = 0
	p.cache_misses = 0
	da2, g4 := paging.get_readonly(&p, a)
	testing.expect(t, paging.ok(g4))
	testing.expect_value(t, da2[0], u8(0x11))
	paging.unpin(&p, a)
	testing.expect_value(t, p.cache_misses, u64(1))
	testing.expect_value(t, p.cache_hits, u64(0))

	p.cache_hits = 0
	p.cache_misses = 0
	_, g5 := paging.get_readonly(&p, a)
	testing.expect(t, paging.ok(g5))
	paging.unpin(&p, a)
	testing.expect_value(t, p.cache_hits, u64(1))
	testing.expect_value(t, p.cache_misses, u64(0))
}

@(test)
test_flush_persists_across_reopen :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-paging-flush-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		p, err := paging.pager_open_create(path, {cache_frames = 16})
		testing.expectf(t, paging.ok(err), "create: %v", err)

		page_no, aerr := paging.alloc_page(&p)
		testing.expect(t, paging.ok(aerr))

		data, gerr := paging.get_readwrite(&p, page_no)
		testing.expect(t, paging.ok(gerr))
		data[0] = 'P'
		data[1] = 'G'
		data[100] = 7
		paging.unpin(&p, page_no)

		boot := dbfile.Bootstrap{
			commit_counter   = 1,
			schema_cookie    = 2,
			table_prime_root = 0,
		}
		ferr := paging.flush(&p, boot)
		testing.expectf(t, paging.ok(ferr), "flush: %v", ferr)
		testing.expect_value(t, p.page_count, u32(2))
		paging.pager_close(&p)
	}

	{
		p, err := paging.pager_open_existing(path)
		testing.expectf(t, paging.ok(err), "reopen: %v", err)
		defer paging.pager_close(&p)

		testing.expect_value(t, p.page_count, u32(2))
		testing.expect_value(t, p.freelist_head, dbfile.Page_No(0))

		data, gerr := paging.get_readonly(&p, 1)
		testing.expect(t, paging.ok(gerr))
		defer paging.unpin(&p, 1)
		testing.expect_value(t, data[0], u8('P'))
		testing.expect_value(t, data[1], u8('G'))
		testing.expect_value(t, data[100], u8(7))

		boot, berr := dbfile.read_bootstrap(&p.file)
		testing.expect(t, dbfile.ok(berr))
		testing.expect_value(t, boot.page_count, u32(2))
		testing.expect_value(t, boot.commit_counter, u32(1))
		testing.expect_value(t, boot.schema_cookie, u32(2))
	}
}

@(test)
test_discard_dirty_rollback :: proc(t: ^testing.T) {
	p, err := paging.pager_open_memory()
	testing.expect(t, paging.ok(err))
	defer paging.pager_close(&p)

	page_no, aerr := paging.alloc_page(&p)
	testing.expect(t, paging.ok(aerr))
	data, gerr := paging.get_readwrite(&p, page_no)
	testing.expect(t, paging.ok(gerr))
	data[0] = 0xAA
	paging.unpin(&p, page_no)
	testing.expect(t, paging.ok(paging.flush(&p, {})))

	// Mutate then discard — should not persist.
	data, gerr = paging.get_readwrite(&p, page_no)
	testing.expect(t, paging.ok(gerr))
	data[0] = 0xBB
	paging.unpin(&p, page_no)

	new_page, aerr2 := paging.alloc_page(&p)
	testing.expect(t, paging.ok(aerr2))
	testing.expect(t, new_page != page_no)

	derr := paging.discard_dirty(&p)
	testing.expectf(t, paging.ok(derr), "discard: %v", derr)
	testing.expect_value(t, p.page_count, u32(2))
	testing.expect_value(t, p.freelist_head, dbfile.Page_No(0))

	data, gerr = paging.get_readonly(&p, page_no)
	testing.expect(t, paging.ok(gerr))
	defer paging.unpin(&p, page_no)
	testing.expect_value(t, data[0], u8(0xAA))

	_, g3 := paging.get_readonly(&p, new_page)
	testing.expect_value(t, g3, paging.Page_Error.Page_Out_Of_Range)
}

@(test)
test_freelist_reuse :: proc(t: ^testing.T) {
	p, err := paging.pager_open_memory()
	testing.expect(t, paging.ok(err))
	defer paging.pager_close(&p)

	a, _ := paging.alloc_page(&p)
	b, _ := paging.alloc_page(&p)
	c, _ := paging.alloc_page(&p)
	testing.expect_value(t, a, dbfile.Page_No(1))
	testing.expect_value(t, b, dbfile.Page_No(2))
	testing.expect_value(t, c, dbfile.Page_No(3))
	testing.expect_value(t, p.page_count, u32(4))

	testing.expect(t, paging.ok(paging.free_page(&p, b)))
	testing.expect_value(t, p.freelist_head, b)

	reused, rerr := paging.alloc_page(&p)
	testing.expect(t, paging.ok(rerr))
	testing.expect_value(t, reused, b)
	testing.expect_value(t, p.freelist_head, dbfile.Page_No(0))
	testing.expect_value(t, p.page_count, u32(4))

	testing.expect(t, paging.ok(paging.flush(&p, {})))
}

@(test)
test_freelist_persists_on_flush :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-paging-freelist-%d.strix", os.get_pid())
	defer os.remove(path)

	freed: dbfile.Page_No
	{
		p, err := paging.pager_open_create(path)
		testing.expect(t, paging.ok(err))
		a, _ := paging.alloc_page(&p)
		b, _ := paging.alloc_page(&p)
		_ = a
		freed = b
		testing.expect(t, paging.ok(paging.free_page(&p, b)))
		testing.expect(t, paging.ok(paging.flush(&p, {})))
		paging.pager_close(&p)
	}

	{
		p, err := paging.pager_open_existing(path)
		testing.expect(t, paging.ok(err))
		defer paging.pager_close(&p)
		testing.expect_value(t, p.freelist_head, freed)
		testing.expect_value(t, p.page_count, u32(3))

		reused, rerr := paging.alloc_page(&p)
		testing.expect(t, paging.ok(rerr))
		testing.expect_value(t, reused, freed)
		testing.expect_value(t, p.freelist_head, dbfile.Page_No(0))
	}
}

@(test)
test_flush_updates_bootstrap_meta :: proc(t: ^testing.T) {
	p, err := paging.pager_open_memory()
	testing.expect(t, paging.ok(err))
	defer paging.pager_close(&p)

	p1, _ := paging.alloc_page(&p)
	_, _ = paging.alloc_page(&p)
	p2, _ := paging.alloc_page(&p)

	d1, _ := paging.get_readwrite(&p, p1)
	d1[0] = 1
	paging.unpin(&p, p1)
	d2, _ := paging.get_readwrite(&p, p2)
	d2[0] = 2
	paging.unpin(&p, p2)

	testing.expect(t, paging.ok(paging.flush(&p, {commit_counter = 9})))

	boot, berr := dbfile.read_bootstrap(&p.file)
	testing.expect(t, dbfile.ok(berr))
	testing.expect_value(t, boot.page_count, p.page_count)
	testing.expect_value(t, boot.commit_counter, u32(9))
	testing.expect_value(t, boot.freelist_head, p.freelist_head)
}

@(test)
test_free_page_rejects_double_free :: proc(t: ^testing.T) {
	p, err := paging.pager_open_memory()
	testing.expect(t, paging.ok(err))
	defer paging.pager_close(&p)

	a, _ := paging.alloc_page(&p)
	b, _ := paging.alloc_page(&p)
	c, _ := paging.alloc_page(&p)

	testing.expect(t, paging.ok(paging.free_page(&p, b)))
	testing.expect_value(t, paging.free_page(&p, b), paging.Page_Error.Already_Free)
	testing.expect_value(t, p.freelist_head, b)

	testing.expect(t, paging.ok(paging.free_page(&p, c)))
	// b is still on the list under c → still rejected
	testing.expect_value(t, paging.free_page(&p, b), paging.Page_Error.Already_Free)
	testing.expect_value(t, paging.free_page(&p, c), paging.Page_Error.Already_Free)

	// Head double-free after flush/reopen path in-memory
	testing.expect(t, paging.ok(paging.flush(&p, {})))
	testing.expect_value(t, paging.free_page(&p, b), paging.Page_Error.Already_Free)
	_ = a
}

@(test)
test_discard_refused_after_partial_flush_failure :: proc(t: ^testing.T) {
	// H2: after a mid-flush failure, discard_dirty is fenced until flush succeeds.
	p, err := paging.pager_open_memory()
	testing.expect(t, paging.ok(err))
	defer paging.pager_close(&p)

	a, _ := paging.alloc_page(&p)
	b, _ := paging.alloc_page(&p)
	da, _ := paging.get_readwrite(&p, a)
	da[0] = 0x11
	paging.unpin(&p, a)
	db, _ := paging.get_readwrite(&p, b)
	db[0] = 0x22
	paging.unpin(&p, b)

	p.flush_fail_after_data_writes = 1
	ferr := paging.flush(&p, {commit_counter = 1})
	testing.expect_value(t, ferr, paging.Page_Error.Flush_Failed)
	testing.expect(t, p.flush_failed)

	derr := paging.discard_dirty(&p)
	testing.expect_value(t, derr, paging.Page_Error.Flush_Failed)

	// pager_close must refuse over a live fence (keep dirty frames for retry flush).
	testing.expect_value(t, paging.pager_close(&p), paging.Page_Error.Flush_Failed)
	testing.expect(t, !p.closed)
	testing.expect(t, p.flush_failed)

	// Retry flush without the hook; fence clears; discard then allowed (no dirty left).
	p.flush_fail_after_data_writes = 0
	testing.expect(t, paging.ok(paging.flush(&p, {commit_counter = 1})))
	testing.expect(t, !p.flush_failed)
	testing.expect(t, paging.ok(paging.discard_dirty(&p)))
}

@(test)
test_flush_rejects_while_pinned :: proc(t: ^testing.T) {
	p, err := paging.pager_open_memory()
	testing.expect(t, paging.ok(err))
	defer paging.pager_close(&p)

	page_no, aerr := paging.alloc_page(&p)
	testing.expect(t, paging.ok(aerr))
	data, gerr := paging.get_readwrite(&p, page_no)
	testing.expect(t, paging.ok(gerr))
	data[0] = 1

	ferr := paging.flush(&p, {})
	testing.expect_value(t, ferr, paging.Page_Error.Pinned)

	// Still dirty / uncommitted until unpin + flush.
	testing.expect_value(t, p.committed_page_count, u32(1))

	paging.unpin(&p, page_no)
	testing.expect(t, paging.ok(paging.flush(&p, {})))
	testing.expect_value(t, p.committed_page_count, u32(2))
}
