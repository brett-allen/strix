package exec

import "core:encoding/endian"
import "core:strings"
import engine "../engine"
import sql "../sql"

// Index key field tags — see docs/storage-format.md § Secondary index key bytes.
IDX_TAG_NULL :: u8(0)
IDX_TAG_INTEGER :: u8(1)
IDX_TAG_FLOAT :: u8(2)
IDX_TAG_TEXT :: u8(3)
IDX_TAG_BLOB :: u8(4)

index_field_size :: proc(v: Value) -> int {
	switch v.kind {
	case .Null:
		return 1
	case .Integer, .Float:
		return 1 + 8
	case .Text, .Blob:
		return 1 + 4 + len(v.bytes) + 1 // tag | len | bytes | 0x00
	}
	return 1
}

// encode_index_key builds memcmp-ordered index_key_bytes from column values (no rowid suffix).
encode_index_key :: proc(vals: []Value, allocator := context.allocator) -> ([]u8, Exec_Error) {
	need := 0
	for v in vals {
		need += index_field_size(v)
	}
	buf := make([]u8, need, allocator)
	off := 0
	for v in vals {
		switch v.kind {
		case .Null:
			buf[off] = IDX_TAG_NULL
			off += 1
		case .Integer:
			buf[off] = IDX_TAG_INTEGER
			off += 1
			// Flip sign bit so signed integers sort in memcmp order.
			ordered := u64(v.i) ~ (u64(1) << 63)
			if !endian.put_u64(buf[off:off + 8], .Big, ordered) {
				delete(buf, allocator)
				return nil, error_at(.Engine, "index key integer encode failed")
			}
			off += 8
		case .Float:
			buf[off] = IDX_TAG_FLOAT
			off += 1
			bits := transmute(u64)v.f
			if !endian.put_u64(buf[off:off + 8], .Big, bits) {
				delete(buf, allocator)
				return nil, error_at(.Engine, "index key float encode failed")
			}
			off += 8
		case .Text:
			buf[off] = IDX_TAG_TEXT
			off += 1
			if !endian.put_u32(buf[off:off + 4], .Big, u32(len(v.bytes))) {
				delete(buf, allocator)
				return nil, error_at(.Engine, "index key text encode failed")
			}
			off += 4
			copy(buf[off:], v.bytes)
			off += len(v.bytes)
			buf[off] = 0
			off += 1
		case .Blob:
			buf[off] = IDX_TAG_BLOB
			off += 1
			if !endian.put_u32(buf[off:off + 4], .Big, u32(len(v.bytes))) {
				delete(buf, allocator)
				return nil, error_at(.Engine, "index key blob encode failed")
			}
			off += 4
			copy(buf[off:], v.bytes)
			off += len(v.bytes)
			buf[off] = 0
			off += 1
		}
	}
	if off != len(buf) {
		delete(buf, allocator)
		return nil, error_at(.Engine, "index key encode size mismatch")
	}
	return buf, ok_error()
}

// extract_index_values picks indexed column values from a full row (by table column names).
extract_index_values :: proc(
	row_vals: []Value,
	table_columns: []engine.Catalog_Column,
	index_columns: []engine.Catalog_Column,
	allocator := context.allocator,
) -> ([]Value, Exec_Error) {
	out := make([]Value, len(index_columns), allocator)
	for ic, i in index_columns {
		idx := find_column_index(table_columns, ic.name)
		if idx < 0 {
			free_values(out[:i], allocator)
			return nil, make_error(.Unknown_Column, "index column %q missing from table", ic.name)
		}
		out[i] = clone_value(row_vals[idx], allocator)
	}
	return out, ok_error()
}

encode_index_key_from_row :: proc(
	row_vals: []Value,
	table_columns: []engine.Catalog_Column,
	index_columns: []engine.Catalog_Column,
	allocator := context.allocator,
) -> ([]u8, Exec_Error) {
	vals, err := extract_index_values(row_vals, table_columns, index_columns, allocator)
	if has_error(err) {
		return nil, err
	}
	defer free_values(vals, allocator)
	return encode_index_key(vals, allocator)
}

// table_indexes_maintained loads indexes for a table; errors with Has_Indexes if any lack columns.
table_indexes_maintained :: proc(
	e: ^engine.Engine,
	table_name: string,
	span: sql.Span,
	allocator := context.allocator,
) -> ([]engine.Catalog_Index_Ref, Exec_Error) {
	refs, err := engine.catalog_indexes_on_table(e, table_name, allocator)
	if err != .None {
		return nil, from_engine_error(err, span)
	}
	for r in refs {
		if len(r.entry.columns) == 0 {
			engine.free_catalog_index_refs(refs, allocator)
			return nil, make_error(
				.Has_Indexes,
				"cannot mutate table %q: index %q has no column metadata (drop and recreate)",
				table_name,
				r.name,
				span = span,
			)
		}
	}
	return refs, ok_error()
}

index_insert_for_row :: proc(
	e: ^engine.Engine,
	refs: []engine.Catalog_Index_Ref,
	table_columns: []engine.Catalog_Column,
	row_vals: []Value,
	rowid: u64,
	span: sql.Span,
) -> Exec_Error {
	for r in refs {
		ikey, kerr := encode_index_key_from_row(row_vals, table_columns, r.entry.columns)
		if has_error(kerr) {
			return kerr
		}
		tree, oerr := engine.catalog_open_index(e, r.name)
		if oerr != .None {
			delete(ikey)
			return from_engine_error(oerr, span)
		}
		ierr := engine.index_insert_entry(&tree, ikey, rowid)
		delete(ikey)
		if ierr != .None {
			return from_engine_error(ierr, span)
		}
	}
	return ok_error()
}

index_delete_for_row :: proc(
	e: ^engine.Engine,
	refs: []engine.Catalog_Index_Ref,
	table_columns: []engine.Catalog_Column,
	row_vals: []Value,
	rowid: u64,
	span: sql.Span,
) -> Exec_Error {
	for r in refs {
		ikey, kerr := encode_index_key_from_row(row_vals, table_columns, r.entry.columns)
		if has_error(kerr) {
			return kerr
		}
		tree, oerr := engine.catalog_open_index(e, r.name)
		if oerr != .None {
			delete(ikey)
			return from_engine_error(oerr, span)
		}
		derr := engine.index_delete_entry(&tree, ikey, rowid)
		delete(ikey)
		if derr != .None {
			return from_engine_error(derr, span)
		}
	}
	return ok_error()
}

// find_single_column_eq_const matches WHERE col = literal (or literal = col).
find_single_column_eq_const :: proc(
	where_expr: ^sql.Expr,
	table_columns: []engine.Catalog_Column,
	table_name, alias: string,
) -> (col_idx: int, const_val: Value, ok: bool) {
	col_idx = -1
	if where_expr == nil || where_expr.kind != .Binary {
		return -1, {}, false
	}
	b := where_expr.data.(sql.Binary_Data)
	if b.op != .Eq && b.op != .EqEq {
		return -1, {}, false
	}
	left, right := b.left, b.right
	if left == nil || right == nil {
		return -1, {}, false
	}

	try_side :: proc(
		col_expr, lit_expr: ^sql.Expr,
		table_columns: []engine.Catalog_Column,
		table_name, alias: string,
	) -> (int, Value, bool) {
		if col_expr.kind != .Column_Ref || lit_expr.kind != .Literal {
			return -1, {}, false
		}
		ref := col_expr.data.(sql.Column_Ref_Data)
		segs := ref.segments
		col_name: string
		if len(segs) == 1 {
			col_name = segs[0]
		} else if len(segs) == 2 {
			qual := segs[0]
			if !(strings.equal_fold(qual, table_name) || (alias != "" && strings.equal_fold(qual, alias))) {
				return -1, {}, false
			}
			col_name = segs[1]
		} else {
			return -1, {}, false
		}
		idx := find_column_index(table_columns, col_name)
		if idx < 0 {
			return -1, {}, false
		}
		v, err := eval_literal_expr(lit_expr)
		if has_error(err) {
			free_error(err)
			return -1, {}, false
		}
		// Index keys are tagged exact (INT vs FLOAT); eval_compare coerces numerics.
		// Skip point-lookup for Integer/Float so seq scan stays correct (e.g. qty=20.0).
		if v.kind == .Integer || v.kind == .Float {
			free_value(v)
			return -1, {}, false
		}
		return idx, v, true
	}

	if i, v, yes := try_side(left, right, table_columns, table_name, alias); yes {
		return i, v, true
	}
	if i, v, yes := try_side(right, left, table_columns, table_name, alias); yes {
		return i, v, true
	}
	return -1, {}, false
}

// find_usable_eq_index finds a single-column index on col_idx.
find_usable_eq_index :: proc(
	refs: []engine.Catalog_Index_Ref,
	table_columns: []engine.Catalog_Column,
	col_idx: int,
) -> (index_name: string, ok: bool) {
	if col_idx < 0 || col_idx >= len(table_columns) {
		return "", false
	}
	want := table_columns[col_idx].name
	for r in refs {
		if len(r.entry.columns) == 1 && strings.equal_fold(r.entry.columns[0].name, want) {
			return r.name, true
		}
	}
	return "", false
}
