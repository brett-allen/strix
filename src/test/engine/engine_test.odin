package engine_tests

import "core:fmt"
import "core:os"
import "core:testing"
import dbfile "../../dbfile"
import engine "../../engine"

// After S4, engine_create / open_memory commit an empty table_prime (page 1, commit_counter=1).
// First page_alloc in a user txn is page 2.

@(test)
test_commit_persists_across_reopen :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-engine-commit-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expectf(t, engine.ok(err), "create: %v", err)

		testing.expect(t, engine.ok(engine.txn_begin(&e)))
		page_no, aerr := engine.page_alloc(&e)
		testing.expect(t, engine.ok(aerr))
		testing.expect_value(t, page_no, dbfile.Page_No(2))

		testing.expect(t, engine.ok(engine.page_write_prefix(&e, page_no, {'C', 'M', 'T', 99})))
		testing.expect(t, engine.ok(engine.txn_commit(&e)))
		testing.expect_value(t, engine.commit_counter(&e), u32(2))
		testing.expect(t, engine.ok(engine.engine_close(&e)))
	}

	{
		e, err := engine.engine_open(path)
		testing.expectf(t, engine.ok(err), "reopen: %v", err)
		defer engine.engine_close(&e)

		testing.expect_value(t, engine.commit_counter(&e), u32(2))

		buf := make([]u8, engine.page_size(&e))
		defer delete(buf)
		testing.expect(t, engine.ok(engine.page_read(&e, 2, buf)))
		testing.expect_value(t, buf[0], u8('C'))
		testing.expect_value(t, buf[1], u8('M'))
		testing.expect_value(t, buf[2], u8('T'))
		testing.expect_value(t, buf[3], u8(99))

		boot, berr := dbfile.read_bootstrap(&e.pager.file)
		testing.expect(t, dbfile.ok(berr))
		testing.expect_value(t, boot.commit_counter, u32(2))
		testing.expect_value(t, boot.page_count, u32(3))
	}
}

@(test)
test_rollback_does_not_persist :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-engine-rollback-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))

		testing.expect(t, engine.ok(engine.txn_begin(&e)))
		page_no, _ := engine.page_alloc(&e)
		testing.expect(t, engine.ok(engine.page_write_prefix(&e, page_no, {'O', 'K'})))
		testing.expect(t, engine.ok(engine.txn_commit(&e)))
		testing.expect_value(t, engine.commit_counter(&e), u32(2))

		testing.expect(t, engine.ok(engine.txn_begin(&e)))
		testing.expect(t, engine.ok(engine.page_write_prefix(&e, page_no, {'N', 'O'})))
		new_page, _ := engine.page_alloc(&e)
		testing.expect(t, new_page != page_no)
		testing.expect(t, engine.ok(engine.txn_rollback(&e)))
		testing.expect_value(t, engine.commit_counter(&e), u32(2))

		buf := make([]u8, engine.page_size(&e))
		defer delete(buf)
		testing.expect(t, engine.ok(engine.page_read(&e, page_no, buf)))
		testing.expect_value(t, buf[0], u8('O'))
		testing.expect_value(t, buf[1], u8('K'))

		rerr := engine.page_read(&e, new_page, buf)
		testing.expect_value(t, rerr, engine.Engine_Error.Page_Out_Of_Range)

		engine.engine_close(&e)
	}

	{
		e, err := engine.engine_open(path)
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)
		testing.expect_value(t, engine.commit_counter(&e), u32(2))

		buf := make([]u8, engine.page_size(&e))
		defer delete(buf)
		testing.expect(t, engine.ok(engine.page_read(&e, 2, buf)))
		testing.expect_value(t, buf[0], u8('O'))
		testing.expect_value(t, buf[1], u8('K'))

		boot, berr := dbfile.read_bootstrap(&e.pager.file)
		testing.expect(t, dbfile.ok(berr))
		testing.expect_value(t, boot.page_count, u32(3))
		testing.expect_value(t, boot.commit_counter, u32(2))
	}
}

@(test)
test_txn_state_guards :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	testing.expect_value(t, engine.txn_commit(&e), engine.Engine_Error.No_Txn)
	testing.expect_value(t, engine.txn_rollback(&e), engine.Engine_Error.No_Txn)
	_, aerr := engine.page_alloc(&e)
	testing.expect_value(t, aerr, engine.Engine_Error.No_Txn)

	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	testing.expect_value(t, engine.txn_begin(&e), engine.Engine_Error.In_Txn)
	testing.expect(t, engine.ok(engine.txn_rollback(&e)))
}

@(test)
test_commit_bumps_counter_twice :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	testing.expect_value(t, engine.commit_counter(&e), u32(1)) // catalog init commit

	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	pn, _ := engine.page_alloc(&e)
	testing.expect(t, engine.ok(engine.page_write_prefix(&e, pn, {1})))
	testing.expect(t, engine.ok(engine.txn_commit(&e)))
	testing.expect_value(t, engine.commit_counter(&e), u32(2))

	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	testing.expect(t, engine.ok(engine.page_write_prefix(&e, pn, {2})))
	testing.expect(t, engine.ok(engine.txn_commit(&e)))
	testing.expect_value(t, engine.commit_counter(&e), u32(3))

	boot, berr := dbfile.read_bootstrap(&e.pager.file)
	testing.expect(t, dbfile.ok(berr))
	testing.expect_value(t, boot.commit_counter, u32(3))
}
