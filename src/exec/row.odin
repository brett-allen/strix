package exec

import "core:encoding/endian"

// Heap leaf row payload — see docs/storage-format.md § Heap row payload.
HEAP_ROW_VERSION :: u8(1)

ROW_TAG_INTEGER :: u8(1)
ROW_TAG_FLOAT :: u8(2)
ROW_TAG_TEXT :: u8(3)
ROW_TAG_BLOB :: u8(4)

null_bitmap_len :: proc(col_count: int) -> int {
	if col_count <= 0 {
		return 0
	}
	return (col_count + 7) / 8
}

null_bitmap_set :: proc(bitmap: []u8, col: int) {
	bitmap[col / 8] |= u8(1) << uint(col % 8)
}

null_bitmap_get :: proc(bitmap: []u8, col: int) -> bool {
	return (bitmap[col / 8] & (u8(1) << uint(col % 8))) != 0
}

field_payload_size :: proc(v: Value) -> int {
	switch v.kind {
	case .Null:
		return 0
	case .Integer:
		return 1 + 8
	case .Float:
		return 1 + 8
	case .Text, .Blob:
		return 1 + 4 + len(v.bytes)
	}
	return 0
}

// encode_heap_row encodes values into a heap leaf payload (caller owns result).
encode_heap_row :: proc(values: []Value, allocator := context.allocator) -> ([]u8, Exec_Error) {
	if len(values) > 65535 {
		return nil, error_at(.Invalid_Schema, "too many columns for heap row")
	}
	ncol := len(values)
	nb := null_bitmap_len(ncol)
	need := 1 + 2 + nb
	for v in values {
		need += field_payload_size(v)
	}
	buf := make([]u8, need, allocator)
	buf[0] = HEAP_ROW_VERSION
	endian.put_u16(buf[1:3], .Little, u16(ncol))
	bitmap := buf[3:3 + nb]
	off := 3 + nb
	for i in 0 ..< ncol {
		v := values[i]
		if v.kind == .Null {
			null_bitmap_set(bitmap, i)
			continue
		}
		switch v.kind {
		case .Null:
		case .Integer:
			buf[off] = ROW_TAG_INTEGER
			off += 1
			endian.put_i64(buf[off:off + 8], .Little, v.i)
			off += 8
		case .Float:
			buf[off] = ROW_TAG_FLOAT
			off += 1
			endian.put_f64(buf[off:off + 8], .Little, v.f)
			off += 8
		case .Text:
			buf[off] = ROW_TAG_TEXT
			off += 1
			endian.put_u32(buf[off:off + 4], .Little, u32(len(v.bytes)))
			off += 4
			copy(buf[off:], v.bytes)
			off += len(v.bytes)
		case .Blob:
			buf[off] = ROW_TAG_BLOB
			off += 1
			endian.put_u32(buf[off:off + 4], .Little, u32(len(v.bytes)))
			off += 4
			copy(buf[off:], v.bytes)
			off += len(v.bytes)
		}
	}
	if off != len(buf) {
		delete(buf, allocator)
		return nil, error_at(.Engine, "heap row encode size mismatch")
	}
	return buf, ok_error()
}

// decode_heap_row decodes a heap leaf payload (caller frees with free_values).
decode_heap_row :: proc(payload: []u8, allocator := context.allocator) -> ([]Value, Exec_Error) {
	if len(payload) < 3 {
		return nil, error_at(.Engine, "heap row too short")
	}
	if payload[0] != HEAP_ROW_VERSION {
		return nil, make_error(.Engine, "unsupported heap row version %d", payload[0])
	}
	ncol_u, ok := endian.get_u16(payload[1:3], .Little)
	if !ok {
		return nil, error_at(.Engine, "corrupt heap row col_count")
	}
	ncol := int(ncol_u)
	nb := null_bitmap_len(ncol)
	if len(payload) < 3 + nb {
		return nil, error_at(.Engine, "heap row missing null bitmap")
	}
	bitmap := payload[3:3 + nb]
	off := 3 + nb
	vals := make([]Value, ncol, allocator)
	for i in 0 ..< ncol {
		if null_bitmap_get(bitmap, i) {
			vals[i] = value_null()
			continue
		}
		if off >= len(payload) {
			free_values(vals, allocator)
			return nil, make_error(.Engine, "heap row truncated at column %d", i)
		}
		tag := payload[off]
		off += 1
		switch tag {
		case ROW_TAG_INTEGER:
			if off + 8 > len(payload) {
				free_values(vals, allocator)
				return nil, error_at(.Engine, "heap row truncated integer")
			}
			n, ok_i := endian.get_i64(payload[off:off + 8], .Little)
			if !ok_i {
				free_values(vals, allocator)
				return nil, error_at(.Engine, "corrupt heap integer")
			}
			vals[i] = value_integer(n)
			off += 8
		case ROW_TAG_FLOAT:
			if off + 8 > len(payload) {
				free_values(vals, allocator)
				return nil, error_at(.Engine, "heap row truncated float")
			}
			f, ok_f := endian.get_f64(payload[off:off + 8], .Little)
			if !ok_f {
				free_values(vals, allocator)
				return nil, error_at(.Engine, "corrupt heap float")
			}
			vals[i] = value_float(f)
			off += 8
		case ROW_TAG_TEXT, ROW_TAG_BLOB:
			if off + 4 > len(payload) {
				free_values(vals, allocator)
				return nil, error_at(.Engine, "heap row truncated length")
			}
			nlen, ok_n := endian.get_u32(payload[off:off + 4], .Little)
			if !ok_n {
				free_values(vals, allocator)
				return nil, error_at(.Engine, "corrupt heap length")
			}
			off += 4
			if off + int(nlen) > len(payload) {
				free_values(vals, allocator)
				return nil, error_at(.Engine, "heap row truncated bytes")
			}
			raw := payload[off:off + int(nlen)]
			off += int(nlen)
			if tag == ROW_TAG_TEXT {
				vals[i] = value_text(string(raw), allocator)
			} else {
				vals[i] = value_blob(raw, allocator)
			}
		case:
			free_values(vals, allocator)
			return nil, make_error(.Engine, "unknown heap field tag %d", tag)
		}
	}
	if off != len(payload) {
		free_values(vals, allocator)
		return nil, error_at(.Engine, "heap row trailing bytes")
	}
	return vals, ok_error()
}
