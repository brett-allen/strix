package exec_tests

import "core:strings"
import "core:testing"
import engine "../../engine"
import exec "../../exec"
import sql "../../sql"

@(test)
test_ok_has_free_error :: proc(t: ^testing.T) {
	ok := exec.ok_error()
	testing.expect(t, !exec.has_error(ok))
	exec.free_error(ok) // no-op

	err := exec.make_error(.Unsupported_Ast, "nope %d", 7)
	testing.expect(t, exec.has_error(err))
	testing.expect_value(t, err.code, exec.Exec_Error_Code.Unsupported_Ast)
	testing.expect(t, err.message == "nope 7")
	exec.free_error(err)

	err2 := exec.error_at(.Invalid_Schema, "bad schema")
	testing.expect_value(t, err2.code, exec.Exec_Error_Code.Invalid_Schema)
	testing.expect_value(t, err2.message, "bad schema")
	exec.free_error(err2)
}

@(test)
test_format_error_with_and_without_span :: proc(t: ^testing.T) {
	no_span := exec.make_error(.Parse, "boom")
	defer exec.free_error(no_span)
	f1 := exec.format_error(no_span)
	defer delete(f1)
	testing.expect_value(t, f1, "boom")

	with_span := exec.make_error(.Parse, "boom", span = sql.Span{line = 3, column = 8})
	defer exec.free_error(with_span)
	f2 := exec.format_error(with_span)
	defer delete(f2)
	testing.expect_value(t, f2, "3:8: boom")

	empty := exec.format_error(exec.ok_error())
	testing.expect_value(t, empty, "")
}

@(test)
test_from_parse_error :: proc(t: ^testing.T) {
	none := exec.from_parse_error(sql.ok_error())
	testing.expect(t, !exec.has_error(none))

	perr := sql.Parse_Error{
		code    = .Unexpected_Token,
		message = "expected IDENT",
		span    = sql.Span{line = 1, column = 2},
	}
	got := exec.from_parse_error(perr)
	testing.expect_value(t, got.code, exec.Exec_Error_Code.Parse)
	testing.expect_value(t, got.message, "expected IDENT")
	testing.expect_value(t, got.span.line, 1)
	exec.free_error(got)

	empty_msg := exec.from_parse_error(sql.Parse_Error{code = .Expected_Statement})
	testing.expect_value(t, empty_msg.code, exec.Exec_Error_Code.Parse)
	testing.expect_value(t, empty_msg.message, "parse error")
	exec.free_error(empty_msg)
}

@(test)
test_from_engine_error_mapping :: proc(t: ^testing.T) {
	none := exec.from_engine_error(.None)
	testing.expect(t, !exec.has_error(none))

	cases := []struct {
		eng:  engine.Engine_Error,
		want: exec.Exec_Error_Code,
	}{
		{.Exists, .Table_Exists},
		{.Not_Found, .Unknown_Table},
		{.Has_Indexes, .Has_Indexes},
		{.Closed, .Closed},
		{.Io, .Io},
		{.Invalid_Argument, .Invalid_Schema},
		{.Corrupt, .Engine},
	}
	for c in cases {
		got := exec.from_engine_error(c.eng)
		testing.expect_value(t, got.code, c.want)
		testing.expect(t, len(got.message) > 0)
		exec.free_error(got)
	}
}

@(test)
test_ok_result_and_free_result :: proc(t: ^testing.T) {
	r := exec.ok_result()
	testing.expect_value(t, r.kind, exec.Result_Kind.Ok)
	exec.free_result(r)

	names := make([]string, 2)
	names[0] = strings.clone("a")
	names[1] = strings.clone("b")
	row0 := make([]string, 2)
	row0[0] = strings.clone("1")
	row0[1] = strings.clone("2")
	rows := make([][]string, 1)
	rows[0] = row0
	owned := exec.Exec_Result{kind = .Result_Set, column_names = names, rows = rows}
	exec.free_result(owned)
}
