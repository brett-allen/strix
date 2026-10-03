package exec_tests

import "core:testing"
import dbfile "../../dbfile"
import engine "../../engine"

@(test)
test_encode_decode_catalog_v2_roundtrip :: proc(t: ^testing.T) {
	entry := engine.Catalog_Entry{
		version    = engine.CATALOG_ROW_VERSION_V2,
		kind       = .Table,
		root       = dbfile.Page_No(7),
		next_rowid = 42,
		columns    = []engine.Catalog_Column{
			{name = "id", type_name = "INTEGER", flags = {.Primary_Key}},
			{name = "n", type_name = "TEXT", flags = {.Not_Null}},
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
	testing.expect_value(t, got.root, dbfile.Page_No(7))
	testing.expect_value(t, got.next_rowid, u64(42))
	testing.expect_value(t, len(got.columns), 2)
	testing.expect_value(t, got.columns[0].name, "id")
	testing.expect(t, .Primary_Key in got.columns[0].flags)
	testing.expect_value(t, got.columns[1].type_name, "TEXT")
	testing.expect(t, .Not_Null in got.columns[1].flags)
}

@(test)
test_encode_decode_catalog_v1_table_legacy :: proc(t: ^testing.T) {
	entry := engine.Catalog_Entry{
		version = engine.CATALOG_ROW_VERSION_V1,
		kind    = .Table,
		root    = dbfile.Page_No(3),
	}
	buf := engine.encode_catalog_row(entry)
	defer delete(buf)
	testing.expect_value(t, len(buf), 6)

	got, err := engine.decode_catalog_row(buf)
	testing.expect(t, engine.ok(err))
	defer engine.free_catalog_entry(got)
	testing.expect_value(t, got.version, engine.CATALOG_ROW_VERSION_V1)
	testing.expect_value(t, got.root, dbfile.Page_No(3))
	testing.expect_value(t, got.next_rowid, u64(1))
	testing.expect_value(t, len(got.columns), 0)
}

@(test)
test_encode_decode_catalog_index_v1 :: proc(t: ^testing.T) {
	entry := engine.Catalog_Entry{
		version      = engine.CATALOG_ROW_VERSION_V1,
		kind         = .Index,
		root         = dbfile.Page_No(9),
		parent_table = "users",
	}
	buf := engine.encode_catalog_row(entry)
	testing.expect(t, buf != nil)
	defer delete(buf)

	got, err := engine.decode_catalog_row(buf)
	testing.expect(t, engine.ok(err))
	defer engine.free_catalog_entry(got)
	testing.expect_value(t, got.kind, engine.Catalog_Kind.Index)
	testing.expect_value(t, got.parent_table, "users")
	testing.expect_value(t, got.root, dbfile.Page_No(9))
}

@(test)
test_encode_index_requires_parent :: proc(t: ^testing.T) {
	buf := engine.encode_catalog_row({kind = .Index, root = 1})
	testing.expect(t, buf == nil)
}

@(test)
test_decode_catalog_corrupt_payloads :: proc(t: ^testing.T) {
	_, err1 := engine.decode_catalog_row([]u8{1, 2})
	testing.expect_value(t, err1, engine.Engine_Error.Corrupt)

	_, err2 := engine.decode_catalog_row([]u8{9, 1, 0, 0, 0, 0})
	testing.expect_value(t, err2, engine.Engine_Error.Corrupt)

	// truncated v2
	_, err3 := engine.decode_catalog_row([]u8{2, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0})
	testing.expect_value(t, err3, engine.Engine_Error.Corrupt)
}

@(test)
test_catalog_register_get_unregister_schema :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	cols := []engine.Catalog_Column{
		{name = "id", type_name = "INTEGER", flags = {.Primary_Key}},
		{name = "n", type_name = "TEXT", flags = {.Not_Null}},
	}
	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	root, rerr := engine.catalog_register_table(&e, "items", cols, 10)
	testing.expect(t, engine.ok(rerr))
	testing.expect(t, root != 0)

	_, exists := engine.catalog_register_table(&e, "items", cols)
	testing.expect_value(t, exists, engine.Engine_Error.Exists)

	_, empty := engine.catalog_register_table(&e, "")
	testing.expect_value(t, empty, engine.Engine_Error.Invalid_Argument)
	testing.expect(t, engine.ok(engine.txn_commit(&e)))

	entry, gerr := engine.catalog_get_table_entry(&e, "items")
	testing.expect(t, engine.ok(gerr))
	testing.expect_value(t, entry.next_rowid, u64(10))
	testing.expect_value(t, len(entry.columns), 2)
	engine.free_catalog_entry(entry)

	_, missing := engine.catalog_get_table_entry(&e, "nope")
	testing.expect_value(t, missing, engine.Engine_Error.Not_Found)

	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	testing.expect(t, engine.ok(engine.catalog_unregister_table(&e, "items")))
	testing.expect(t, engine.ok(engine.txn_commit(&e)))

	_, gone := engine.catalog_get_table_entry(&e, "items")
	testing.expect_value(t, gone, engine.Engine_Error.Not_Found)
}

@(test)
test_catalog_unregister_requires_txn_and_rejects_indexes :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	testing.expect_value(t, engine.catalog_unregister_table(&e, "t"), engine.Engine_Error.No_Txn)

	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	_, _ = engine.catalog_register_table(&e, "t", []engine.Catalog_Column{{name = "a", type_name = "INT"}})
	_, _ = engine.catalog_register_index(&e, "t_i", "t")
	testing.expect(t, engine.ok(engine.txn_commit(&e)))

	has, herr := engine.catalog_table_has_indexes(&e, "t")
	testing.expect(t, engine.ok(herr))
	testing.expect(t, has)
	has2, herr2 := engine.catalog_table_has_indexes(&e, "other")
	testing.expect(t, engine.ok(herr2))
	testing.expect(t, !has2)

	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	testing.expect_value(t, engine.catalog_unregister_table(&e, "t"), engine.Engine_Error.Has_Indexes)
	testing.expect_value(t, engine.catalog_unregister_table(&e, "missing"), engine.Engine_Error.Not_Found)
	_ = engine.txn_rollback(&e)
}

@(test)
test_catalog_keys_and_free_entry :: proc(t: ^testing.T) {
	tk := engine.catalog_table_key("users")
	defer delete(tk)
	testing.expect_value(t, string(tk), "table:users")
	ik := engine.catalog_index_key("users_by_name")
	defer delete(ik)
	testing.expect_value(t, string(ik), "index:users_by_name")

	entry := engine.Catalog_Entry{
		version      = engine.CATALOG_ROW_VERSION_V2,
		kind         = .Table,
		parent_table = "",
		columns      = make([]engine.Catalog_Column, 1),
	}
	entry.columns[0] = engine.Catalog_Column{
		name      = "x",
		type_name = "INT",
	}
	// clone strings so free owns them
	entry.columns[0].name = clone_str("x")
	entry.columns[0].type_name = clone_str("INT")
	engine.free_catalog_entry(entry)
}

clone_str :: proc(s: string) -> string {
	out := make([]u8, len(s))
	copy(out, transmute([]u8)s)
	return string(out)
}

@(test)
test_catalog_register_empty_schema_v2 :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)

	testing.expect(t, engine.ok(engine.txn_begin(&e)))
	_, rerr := engine.catalog_register_table(&e, "empty")
	testing.expect(t, engine.ok(rerr))
	testing.expect(t, engine.ok(engine.txn_commit(&e)))

	entry, gerr := engine.catalog_get_table_entry(&e, "empty")
	testing.expect(t, engine.ok(gerr))
	defer engine.free_catalog_entry(entry)
	testing.expect_value(t, entry.version, engine.CATALOG_ROW_VERSION_V2)
	testing.expect_value(t, len(entry.columns), 0)
	testing.expect_value(t, entry.next_rowid, u64(1))
}
