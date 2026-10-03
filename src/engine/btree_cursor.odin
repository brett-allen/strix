package engine

import dbfile "../dbfile"

btree_cursor_init :: proc(t: ^Btree) -> Btree_Cursor {
	return Btree_Cursor{tree = t, valid = false}
}

btree_cursor_close :: proc(c: ^Btree_Cursor) {
	if c == nil {
		return
	}
	delete(c.key_buf)
	delete(c.payload_buf)
	c.key_buf = nil
	c.payload_buf = nil
	c.valid = false
}

btree_cursor_key :: proc(c: ^Btree_Cursor) -> []u8 {
	if c == nil || !c.valid {
		return nil
	}
	return c.key_buf[:]
}

btree_cursor_payload :: proc(c: ^Btree_Cursor) -> []u8 {
	if c == nil || !c.valid {
		return nil
	}
	return c.payload_buf[:]
}

btree_cursor_valid :: proc(c: ^Btree_Cursor) -> bool {
	return c != nil && c.valid
}

// btree_seek_ge positions at the first key >= target (or invalid if none).
btree_seek_ge :: proc(c: ^Btree_Cursor, key: []u8) -> Engine_Error {
	if c == nil || c.tree == nil || c.tree.engine == nil {
		return .Closed
	}
	if err := require_open(c.tree.engine); err != .None {
		return err
	}
	c.valid = false

	path := make([dynamic]Path_Slot, 0, 8)
	defer delete(path)
	leaf, err := btree_find_leaf(c.tree, key, &path)
	if err != .None {
		return err
	}

	data, perr := pin_ro(c.tree.engine, leaf)
	if perr != .None {
		return perr
	}

	idx, _, lerr := leaf_lower_bound(data, key)
	if lerr != .None {
		unpin_page(c.tree.engine, leaf)
		return lerr
	}
	n := int(page_n_cells(data))
	if idx < n {
		lerr = cursor_load_cell(c, leaf, data, idx)
		unpin_page(c.tree.engine, leaf)
		return lerr
	}
	next := dbfile.Page_No(page_special(data))
	unpin_page(c.tree.engine, leaf)
	return cursor_seek_from_leaf_start(c, next)
}

cursor_seek_from_leaf_start :: proc(c: ^Btree_Cursor, start: dbfile.Page_No) -> Engine_Error {
	page_no := start
	for page_no != 0 {
		data, err := pin_ro(c.tree.engine, page_no)
		if err != .None {
			return err
		}
		n := int(page_n_cells(data))
		if n > 0 {
			lerr := cursor_load_cell(c, page_no, data, 0)
			unpin_page(c.tree.engine, page_no)
			return lerr
		}
		next := dbfile.Page_No(page_special(data))
		unpin_page(c.tree.engine, page_no)
		page_no = next
	}
	c.valid = false
	return .None
}

// btree_next advances to the next key in order.
btree_next :: proc(c: ^Btree_Cursor) -> Engine_Error {
	if c == nil || c.tree == nil || c.tree.engine == nil {
		return .Closed
	}
	if !c.valid {
		return .None
	}
	if err := require_open(c.tree.engine); err != .None {
		return err
	}

	page_no := c.page_no
	idx := c.cell_index + 1

	data, err := pin_ro(c.tree.engine, page_no)
	if err != .None {
		c.valid = false
		return err
	}
	n := int(page_n_cells(data))
	if idx < n {
		lerr := cursor_load_cell(c, page_no, data, idx)
		unpin_page(c.tree.engine, page_no)
		return lerr
	}
	next := dbfile.Page_No(page_special(data))
	unpin_page(c.tree.engine, page_no)
	return cursor_seek_from_leaf_start(c, next)
}

cursor_load_cell :: proc(c: ^Btree_Cursor, page_no: dbfile.Page_No, data: []u8, idx: int) -> Engine_Error {
	k, p, err := read_leaf_cell(data, idx)
	if err != .None {
		c.valid = false
		return err
	}
	resize(&c.key_buf, len(k))
	resize(&c.payload_buf, len(p))
	copy(c.key_buf[:], k)
	copy(c.payload_buf[:], p)
	c.page_no = page_no
	c.cell_index = idx
	c.valid = true
	return .None
}
