package engine_tests

import "core:fmt"
import "core:os"
import "core:testing"
import dbfile "../../dbfile"
import engine "../../engine"

@(test)
test_create_initializes_table_prime :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-catalog-init-%d.strix", os.get_pid())
	defer os.remove(path)

	e, err := engine.engine_create(path)
	testing.expectf(t, engine.ok(err), "create: %v", err)
	want_root := engine.table_prime_root(&e)
	testing.expect(t, want_root != 0)
	testing.expect(t, engine.ok(engine.engine_close(&e)))

	e2, err2 := engine.engine_open(path)
	testing.expect(t, engine.ok(err2))
	testing.expect_value(t, engine.table_prime_root(&e2), want_root)
	engine.engine_close(&e2)
}

@(test)
test_open_rejects_missing_catalog :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-catalog-missing-%d.strix", os.get_pid())
	defer os.remove(path)

	// Raw dbfile without table_prime (simulate pre-S4 file).
	{
		f, derr := dbfile.open_create(path)
		testing.expect(t, dbfile.ok(derr))
		dbfile.close(&f)
	}

	_, err := engine.engine_open(path)
	testing.expect_value(t, err, engine.Engine_Error.Catalog_Missing)
}

@(test)
test_register_table_insert_reopen :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-catalog-table-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		testing.expect(t, engine.ok(engine.txn_begin(&e)))
		_, rerr := engine.catalog_register_table(&e, "users")
		testing.expect(t, engine.ok(rerr))
		tbl, oerr := engine.catalog_open_table(&e, "users")
		testing.expect(t, engine.ok(oerr))
		testing.expect(t, engine.ok(engine.table_insert_row(&tbl, 42, transmute([]u8)string("alice"))))
		testing.expect(t, engine.ok(engine.txn_commit(&e)))
		engine.engine_close(&e)
	}

	{
		e, err := engine.engine_open(path)
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)

		tbl, oerr := engine.catalog_open_table(&e, "users")
		testing.expect(t, engine.ok(oerr))
		got, gerr := engine.table_get_row(&tbl, 42)
		testing.expect(t, engine.ok(gerr))
		testing.expect_value(t, string(got), "alice")
		delete(got)

		root, lerr := engine.catalog_lookup_table_root(&e, "users")
		testing.expect(t, engine.ok(lerr))
		testing.expect_value(t, root, engine.btree_root(&tbl))
	}
}

@(test)
test_register_index_open_and_lookup :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-catalog-index-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		testing.expect(t, engine.ok(engine.txn_begin(&e)))
		_, _ = engine.catalog_register_table(&e, "users")
		_, ierr := engine.catalog_register_index(&e, "users_by_name", "users")
		testing.expect(t, engine.ok(ierr))

		idx, oerr := engine.catalog_open_index(&e, "users_by_name")
		testing.expect(t, engine.ok(oerr))
		name_key := transmute([]u8)string("alice")
		testing.expect(t, engine.ok(engine.index_insert_entry(&idx, name_key, 42)))
		testing.expect(t, engine.ok(engine.txn_commit(&e)))
		engine.engine_close(&e)
	}

	{
		e, err := engine.engine_open(path)
		testing.expect(t, engine.ok(err))
		defer engine.engine_close(&e)

		idx, oerr := engine.catalog_open_index(&e, "users_by_name")
		testing.expect(t, engine.ok(oerr))
		name_key := transmute([]u8)string("alice")
		testing.expect(t, engine.ok(engine.index_lookup_rowid(&idx, name_key, 42)))
	}
}
