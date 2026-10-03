package exec_tests

import "core:testing"
import exec "../../exec"

@(test)
test_heap_row_codec_roundtrip_all_kinds :: proc(t: ^testing.T) {
	vals := make([]exec.Value, 5)
	vals[0] = exec.value_null()
	vals[1] = exec.value_integer(-7)
	vals[2] = exec.value_float(1.5)
	vals[3] = exec.value_text("hi")
	vals[4] = exec.value_blob([]u8{0xAB, 0xCD})
	defer exec.free_values(vals)

	payload, err := exec.encode_heap_row(vals)
	testing.expectf(t, !exec.has_error(err), "%s", err.message)
	exec.free_error(err)
	defer delete(payload)

	testing.expect_value(t, payload[0], exec.HEAP_ROW_VERSION)
	testing.expect(t, len(payload) > 3)

	got, derr := exec.decode_heap_row(payload)
	testing.expectf(t, !exec.has_error(derr), "%s", derr.message)
	exec.free_error(derr)
	defer exec.free_values(got)

	testing.expect_value(t, len(got), 5)
	testing.expect_value(t, got[0].kind, exec.Value_Kind.Null)
	testing.expect_value(t, got[1].kind, exec.Value_Kind.Integer)
	testing.expect_value(t, got[1].i, i64(-7))
	testing.expect_value(t, got[2].kind, exec.Value_Kind.Float)
	testing.expect_value(t, got[2].f, f64(1.5))
	testing.expect_value(t, got[3].kind, exec.Value_Kind.Text)
	testing.expect_value(t, string(got[3].bytes), "hi")
	testing.expect_value(t, got[4].kind, exec.Value_Kind.Blob)
	testing.expect_value(t, len(got[4].bytes), 2)
	testing.expect_value(t, got[4].bytes[0], u8(0xAB))
	testing.expect_value(t, got[4].bytes[1], u8(0xCD))
}

@(test)
test_heap_row_decode_rejects_bad_version :: proc(t: ^testing.T) {
	bad := []u8{99, 0, 0}
	_, err := exec.decode_heap_row(bad)
	testing.expect(t, exec.has_error(err))
	testing.expect_value(t, err.code, exec.Exec_Error_Code.Engine)
	exec.free_error(err)
}
