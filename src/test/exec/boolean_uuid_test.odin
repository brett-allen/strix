package exec_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import engine "../../engine"
import exec "../../exec"

@(test)
test_boolean_true_false_literals_and_column :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, ok BOOLEAN NOT NULL);" +
		"INSERT INTO t VALUES (1, TRUE), (2, FALSE);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	sel, esel := exec.exec_statement(&s, "SELECT id, ok FROM t ORDER BY id;")
	testing.expectf(t, !exec.has_error(esel), "%s", esel.message)
	testing.expect_value(t, len(sel.rows), 2)
	testing.expect_value(t, sel.rows[0][1], "TRUE")
	testing.expect_value(t, sel.rows[1][1], "FALSE")
	exec.free_error(esel)
	exec.free_result(sel)

	w, ew := exec.exec_statement(&s, "SELECT id FROM t WHERE ok;")
	testing.expectf(t, !exec.has_error(ew), "%s", ew.message)
	testing.expect_value(t, len(w.rows), 1)
	testing.expect_value(t, w.rows[0][0], "1")
	exec.free_error(ew)
	exec.free_result(w)

	wn, ewn := exec.exec_statement(&s, "SELECT id FROM t WHERE NOT ok;")
	testing.expectf(t, !exec.has_error(ewn), "%s", ewn.message)
	testing.expect_value(t, len(wn.rows), 1)
	testing.expect_value(t, wn.rows[0][0], "2")
	exec.free_error(ewn)
	exec.free_result(wn)

	lit, elit := exec.exec_statement(&s, "SELECT TRUE, FALSE FROM t WHERE id = 1;")
	testing.expectf(t, !exec.has_error(elit), "%s", elit.message)
	testing.expect_value(t, lit.rows[0][0], "TRUE")
	testing.expect_value(t, lit.rows[0][1], "FALSE")
	exec.free_error(elit)
	exec.free_result(lit)
}

@(test)
test_boolean_kind_mismatch_and_cast :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(&s, "CREATE TABLE t (id INTEGER PRIMARY KEY, ok BOOLEAN);")
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	// Integer into BOOLEAN → Constraint (no affinity)
	ri, ei := exec.exec_statement(&s, "INSERT INTO t VALUES (1, 1);")
	testing.expect(t, exec.has_error(ei))
	testing.expect_value(t, ei.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(ei)
	exec.free_result(ri)

	r1, e1 := exec.exec_script(
		&s,
		"INSERT INTO t VALUES (1, FALSE);" +
		"UPDATE t SET ok = CAST(1 AS BOOLEAN) WHERE id = 1;",
	)
	testing.expectf(t, !exec.has_error(e1), "%s", e1.message)
	exec.free_error(e1)
	exec.free_result(r1)

	sel, esel := exec.exec_statement(&s, "SELECT ok, CAST(ok AS INTEGER), CAST(ok AS TEXT) FROM t;")
	testing.expectf(t, !exec.has_error(esel), "%s", esel.message)
	testing.expect_value(t, sel.rows[0][0], "TRUE")
	testing.expect_value(t, sel.rows[0][1], "1")
	testing.expect_value(t, sel.rows[0][2], "TRUE")
	exec.free_error(esel)
	exec.free_result(sel)

	r2, e2 := exec.exec_statement(&s, "SELECT id FROM t WHERE ok = TRUE;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, len(r2.rows), 1)
	exec.free_error(e2)
	exec.free_result(r2)

	// Boolean vs Integer without CAST → Unsupported_Ast
	r3, e3 := exec.exec_statement(&s, "SELECT id FROM t WHERE ok = 1;")
	testing.expect(t, exec.has_error(e3))
	testing.expect_value(t, e3.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(e3)
	exec.free_result(r3)
}

@(test)
test_uuid_typed_roundtrip_and_pk :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (ok BOOLEAN, id UUID PRIMARY KEY, label TEXT);" +
		"INSERT INTO t VALUES (TRUE, '550e8400-e29b-41d4-a716-446655440000', 'a');" +
		"INSERT INTO t VALUES (FALSE, '550E8400-E29B-41D4-A716-446655440001', 'b');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	sel, esel := exec.exec_statement(&s, "SELECT ok, id, label FROM t ORDER BY label;")
	testing.expectf(t, !exec.has_error(esel), "%s", esel.message)
	testing.expect_value(t, len(sel.rows), 2)
	testing.expect_value(t, sel.rows[0][0], "TRUE")
	testing.expect_value(t, sel.rows[0][1], "550e8400-e29b-41d4-a716-446655440000")
	testing.expect_value(t, sel.rows[1][0], "FALSE")
	testing.expect_value(t, sel.rows[1][1], "550e8400-e29b-41d4-a716-446655440001")
	exec.free_error(esel)
	exec.free_result(sel)

	// Heap tag is Uuid / Boolean (not Text)
	tree, oerr := engine.catalog_open_table(&e, "t")
	testing.expect(t, engine.ok(oerr))
	payload, gerr := engine.table_get_row(&tree, 1)
	testing.expect(t, engine.ok(gerr))
	defer delete(payload)
	vals, derr := exec.decode_heap_row(payload)
	testing.expectf(t, !exec.has_error(derr), "%s", derr.message)
	testing.expect_value(t, vals[0].kind, exec.Value_Kind.Boolean)
	testing.expect_value(t, vals[1].kind, exec.Value_Kind.Uuid)
	testing.expect_value(t, len(vals[1].bytes), 16)
	exec.free_error(derr)
	exec.free_values(vals)

	rdup, edup := exec.exec_statement(
		&s,
		"INSERT INTO t VALUES (TRUE, '550e8400-e29b-41d4-a716-446655440000', 'dup');",
	)
	testing.expect(t, exec.has_error(edup))
	testing.expect_value(t, edup.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(edup)
	exec.free_result(rdup)
}

@(test)
test_uuid_malformed_and_wrong_kind :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(&s, "CREATE TABLE t (id UUID PRIMARY KEY, n INT);")
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	rm, em := exec.exec_statement(&s, "INSERT INTO t VALUES ('not-a-uuid', 1);")
	testing.expect(t, exec.has_error(em))
	testing.expect_value(t, em.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(em)
	exec.free_result(rm)

	ri, ei := exec.exec_statement(&s, "INSERT INTO t VALUES (1, 1);")
	testing.expect(t, exec.has_error(ei))
	testing.expect_value(t, ei.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(ei)
	exec.free_result(ri)

	r1, e1 := exec.exec_script(
		&s,
		"INSERT INTO t VALUES ('550e8400-e29b-41d4-a716-446655440000', 1);",
	)
	testing.expectf(t, !exec.has_error(e1), "%s", e1.message)
	exec.free_error(e1)
	exec.free_result(r1)

	rc, ec := exec.exec_statement(&s, "SELECT CAST('nope' AS UUID) FROM t;")
	testing.expect(t, exec.has_error(ec))
	testing.expect_value(t, ec.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(ec)
	exec.free_result(rc)
}

@(test)
test_boolean_uuid_durable_reopen :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/strix-f3-bool-uuid-%d.strix", os.get_pid())
	defer os.remove(path)

	{
		e, err := engine.engine_create(path)
		testing.expect(t, engine.ok(err))
		s := exec.session_adopt(&e)
		r, eerr := exec.exec_script(
			&s,
			"CREATE TABLE t (ok BOOLEAN NOT NULL DEFAULT TRUE, id UUID PRIMARY KEY);" +
			"INSERT INTO t (id) VALUES ('11111111-1111-1111-1111-111111111111');" +
			"INSERT INTO t VALUES (FALSE, '22222222-2222-2222-2222-222222222222');",
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
		r, eerr := exec.exec_statement(&s, "SELECT ok, id FROM t ORDER BY id;")
		testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
		testing.expect_value(t, len(r.rows), 2)
		testing.expect_value(t, r.rows[0][0], "TRUE")
		testing.expect_value(t, r.rows[0][1], "11111111-1111-1111-1111-111111111111")
		testing.expect_value(t, r.rows[1][0], "FALSE")
		testing.expect_value(t, r.rows[1][1], "22222222-2222-2222-2222-222222222222")
		exec.free_error(eerr)
		exec.free_result(r)

		rdup, edup := exec.exec_statement(
			&s,
			"INSERT INTO t VALUES (TRUE, '11111111-1111-1111-1111-111111111111');",
		)
		testing.expect(t, exec.has_error(edup))
		testing.expect_value(t, edup.code, exec.Exec_Error_Code.Constraint)
		exec.free_error(edup)
		exec.free_result(rdup)
	}
}

@(test)
test_uuid_index_key_encode :: proc(t: ^testing.T) {
	raw: [16]u8
	testing.expect(t, exec.parse_uuid_text("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", raw[:]))
	v, ok := exec.value_uuid(raw[:])
	testing.expect(t, ok)
	defer exec.free_value(v)
	ikey, kerr := exec.encode_index_key([]exec.Value{v, exec.value_boolean(true)})
	testing.expectf(t, !exec.has_error(kerr), "%s", kerr.message)
	exec.free_error(kerr)
	defer delete(ikey)
	testing.expect_value(t, ikey[0], exec.IDX_TAG_UUID)
	testing.expect_value(t, len(ikey), 1 + 16 + 1 + 1) // uuid + boolean
	testing.expect_value(t, ikey[17], exec.IDX_TAG_BOOLEAN)
	testing.expect_value(t, ikey[18], u8(1))
}

@(test)
test_sum_i64_overflow_fail_closed :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (n INTEGER);" +
		"INSERT INTO t VALUES (9223372036854775807), (1);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r, eerr := exec.exec_statement(&s, "SELECT SUM(n) FROM t;")
	testing.expect(t, exec.has_error(eerr))
	testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(eerr)
	exec.free_result(r)
}

@(test)
test_scalar_i64_arith_overflow_fail_closed :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_statement(&s, "CREATE TABLE t (n INTEGER);")
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	// Bind extreme i64 values (SQL literals cannot always spell min(i64)).
	extremes := []i64{max(i64), min(i64), i64(4611686018427387904)}
	for v in extremes {
		ri, ei := exec.exec_statement_params(&s, "INSERT INTO t VALUES (?)", []exec.Value{exec.value_integer(v)})
		testing.expectf(t, !exec.has_error(ei), "%s", ei.message)
		exec.free_error(ei)
		exec.free_result(ri)
	}

	// `/` always promotes to float in eval_arith; cover + - * and unary -.
	overflow_cases := []struct {
		sql: string,
		arg: i64,
	}{
		{"SELECT n + 1 FROM t WHERE n = ?", max(i64)},
		{"SELECT n - 1 FROM t WHERE n = ?", min(i64)},
		{"SELECT n * 2 FROM t WHERE n = ?", i64(4611686018427387904)},
		{"SELECT -n FROM t WHERE n = ?", min(i64)},
	}
	for c in overflow_cases {
		r, eerr := exec.exec_statement_params(&s, c.sql, []exec.Value{exec.value_integer(c.arg)})
		testing.expectf(t, exec.has_error(eerr), "expected overflow for %s", c.sql)
		testing.expect_value(t, eerr.code, exec.Exec_Error_Code.Unsupported_Ast)
		exec.free_error(eerr)
		exec.free_result(r)
	}

	rins, eins := exec.exec_statement_params(
		&s,
		"INSERT INTO t VALUES (?)",
		[]exec.Value{exec.value_integer(max(i64) - 1)},
	)
	testing.expectf(t, !exec.has_error(eins), "%s", eins.message)
	exec.free_error(eins)
	exec.free_result(rins)
	rok, eok := exec.exec_statement_params(
		&s,
		"SELECT n + 1 FROM t WHERE n = ?",
		[]exec.Value{exec.value_integer(max(i64) - 1)},
	)
	testing.expectf(t, !exec.has_error(eok), "%s", eok.message)
	testing.expect_value(t, rok.rows[0][0], "9223372036854775807")
	exec.free_error(eok)
	exec.free_result(rok)
}

@(test)
test_heap_row_boolean_uuid_codec :: proc(t: ^testing.T) {
	raw: [16]u8
	testing.expect(t, exec.parse_uuid_text("01234567-89ab-cdef-0123-456789abcdef", raw[:]))
	u, uok := exec.value_uuid(raw[:])
	testing.expect(t, uok)

	vals := make([]exec.Value, 3)
	vals[0] = exec.value_boolean(true)
	vals[1] = u
	vals[2] = exec.value_boolean(false)
	defer exec.free_values(vals)

	payload, err := exec.encode_heap_row(vals)
	testing.expectf(t, !exec.has_error(err), "%s", err.message)
	exec.free_error(err)
	defer delete(payload)

	got, derr := exec.decode_heap_row(payload)
	testing.expectf(t, !exec.has_error(derr), "%s", derr.message)
	exec.free_error(derr)
	defer exec.free_values(got)

	testing.expect_value(t, got[0].kind, exec.Value_Kind.Boolean)
	testing.expect(t, got[0].i != 0)
	testing.expect_value(t, got[1].kind, exec.Value_Kind.Uuid)
	canon := exec.format_uuid_canonical(got[1].bytes)
	defer delete(canon)
	testing.expect_value(t, canon, "01234567-89ab-cdef-0123-456789abcdef")
	testing.expect_value(t, got[2].kind, exec.Value_Kind.Boolean)
	testing.expect_value(t, got[2].i, i64(0))
}

@(test)
test_parse_uuid_text_32_hex :: proc(t: ^testing.T) {
	raw: [16]u8
	testing.expect(t, exec.parse_uuid_text("550e8400e29b41d4a716446655440000", raw[:]))
	canon := exec.format_uuid_canonical(raw[:])
	defer delete(canon)
	testing.expect_value(t, canon, "550e8400-e29b-41d4-a716-446655440000")

	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)
	r, eerr := exec.exec_script(
		&s,
		"CREATE TABLE t (id UUID PRIMARY KEY);" +
		"INSERT INTO t VALUES ('550e8400e29b41d4a716446655440000');",
	)
	testing.expectf(t, !exec.has_error(eerr), "%s", eerr.message)
	exec.free_error(eerr)
	exec.free_result(r)

	sel, esel := exec.exec_statement(&s, "SELECT id FROM t;")
	testing.expectf(t, !exec.has_error(esel), "%s", esel.message)
	testing.expect_value(t, sel.rows[0][0], "550e8400-e29b-41d4-a716-446655440000")
	exec.free_error(esel)
	exec.free_result(sel)
}

@(test)
test_corrupt_heap_boolean_byte :: proc(t: ^testing.T) {
	// version=1, col_count=1, null_bitmap=0, tag=Boolean, payload=2 (>1)
	payload := []u8{1, 1, 0, 0, exec.ROW_TAG_BOOLEAN, 2}
	_, derr := exec.decode_heap_row(payload)
	testing.expect(t, exec.has_error(derr))
	testing.expect_value(t, derr.code, exec.Exec_Error_Code.Engine)
	testing.expect(t, strings.contains(derr.message, "corrupt heap boolean"))
	exec.free_error(derr)
}

@(test)
test_bool_alias_declared_storage :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, ok BOOL NOT NULL);" +
		"INSERT INTO t VALUES (1, TRUE), (2, FALSE);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	// Integer into BOOL → Constraint (same as BOOLEAN)
	ri, ei := exec.exec_statement(&s, "INSERT INTO t VALUES (3, 1);")
	testing.expect(t, exec.has_error(ei))
	testing.expect_value(t, ei.code, exec.Exec_Error_Code.Constraint)
	exec.free_error(ei)
	exec.free_result(ri)

	sel, esel := exec.exec_statement(&s, "SELECT id FROM t WHERE ok;")
	testing.expectf(t, !exec.has_error(esel), "%s", esel.message)
	testing.expect_value(t, len(sel.rows), 1)
	testing.expect_value(t, sel.rows[0][0], "1")
	exec.free_error(esel)
	exec.free_result(sel)
}

@(test)
test_cast_text_boolean_and_blob_uuid :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, s TEXT, b BLOB);" +
		"INSERT INTO t VALUES (1, 'TRUE', X'550e8400e29b41d4a716446655440000');" +
		"INSERT INTO t VALUES (2, 'false', X'00');",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	r1, e1 := exec.exec_statement(
		&s,
		"SELECT CAST(s AS BOOLEAN), CAST(b AS UUID) FROM t WHERE id = 1;",
	)
	testing.expectf(t, !exec.has_error(e1), "%s", e1.message)
	testing.expect_value(t, r1.rows[0][0], "TRUE")
	testing.expect_value(t, r1.rows[0][1], "550e8400-e29b-41d4-a716-446655440000")
	exec.free_error(e1)
	exec.free_result(r1)

	r2, e2 := exec.exec_statement(&s, "SELECT CAST(s AS BOOLEAN) FROM t WHERE id = 2;")
	testing.expectf(t, !exec.has_error(e2), "%s", e2.message)
	testing.expect_value(t, r2.rows[0][0], "FALSE")
	exec.free_error(e2)
	exec.free_result(r2)

	// Wrong blob length → Unsupported_Ast
	rb, eb := exec.exec_statement(&s, "SELECT CAST(b AS UUID) FROM t WHERE id = 2;")
	testing.expect(t, exec.has_error(eb))
	testing.expect_value(t, eb.code, exec.Exec_Error_Code.Unsupported_Ast)
	exec.free_error(eb)
	exec.free_result(rb)
}

@(test)
test_default_uuid_and_schema_print :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (" +
		"  ok BOOLEAN NOT NULL DEFAULT FALSE," +
		"  id UUID DEFAULT 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'," +
		"  n INT" +
		");" +
		"INSERT INTO t (n) VALUES (1);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	sel, esel := exec.exec_statement(&s, "SELECT ok, id, n FROM t;")
	testing.expectf(t, !exec.has_error(esel), "%s", esel.message)
	testing.expect_value(t, sel.rows[0][0], "FALSE")
	testing.expect_value(t, sel.rows[0][1], "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
	testing.expect_value(t, sel.rows[0][2], "1")
	exec.free_error(esel)
	exec.free_result(sel)

	schema, serr := exec.schema_sql(&s, "t")
	testing.expectf(t, !exec.has_error(serr), "%s", serr.message)
	defer exec.free_error(serr)
	defer delete(schema)
	testing.expect(t, strings.contains(schema, "ok BOOLEAN NOT NULL DEFAULT FALSE"))
	testing.expect(t, strings.contains(schema, "id UUID DEFAULT 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'"))
}

@(test)
test_create_index_on_boolean :: proc(t: ^testing.T) {
	e, err := engine.engine_open_memory()
	testing.expect(t, engine.ok(err))
	defer engine.engine_close(&e)
	s := exec.session_adopt(&e)

	r0, e0 := exec.exec_script(
		&s,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, ok BOOLEAN);" +
		"CREATE INDEX t_by_ok ON t (ok);" +
		"INSERT INTO t VALUES (1, TRUE), (2, FALSE), (3, TRUE);",
	)
	testing.expectf(t, !exec.has_error(e0), "%s", e0.message)
	exec.free_error(e0)
	exec.free_result(r0)

	sel, esel := exec.exec_statement(&s, "SELECT id FROM t WHERE ok = TRUE ORDER BY id;")
	testing.expectf(t, !exec.has_error(esel), "%s", esel.message)
	testing.expect_value(t, len(sel.rows), 2)
	testing.expect_value(t, sel.rows[0][0], "1")
	testing.expect_value(t, sel.rows[1][0], "3")
	exec.free_error(esel)
	exec.free_result(sel)

	schema, serr := exec.schema_sql(&s, "t")
	testing.expectf(t, !exec.has_error(serr), "%s", serr.message)
	defer exec.free_error(serr)
	defer delete(schema)
	testing.expect(t, strings.contains(schema, "CREATE INDEX t_by_ok ON t (ok);"))
}
