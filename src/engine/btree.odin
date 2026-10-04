package engine

import "core:slice"
import dbfile "../dbfile"
import paging "../paging"

/*
	Root ownership rule:
	- Ephemeral/test trees: btree_create/open require caller-owned root: ^Page_No
	  (Caller_Root). Root splits write through that slot.
	- Catalog trees: catalog_open_* / table_prime_tree bind Catalog_Object or
	  Table_Prime so splits update table_prime / page-0 meta.
	- bind == None: root-changing splits return .Unbound_Root (no silent loss).
*/

// btree_create allocates an empty leaf root. `root` is required and updated.
btree_create :: proc(e: ^Engine, root: ^dbfile.Page_No) -> (tree: Btree, err: Engine_Error) {
	if err = require_txn(e); err != .None {
		return {}, err
	}
	if root == nil {
		return {}, .Invalid_Argument
	}
	page_no, aerr := paging.alloc_page(&e.pager)
	if aerr != .None {
		return {}, from_page_error(aerr)
	}
	data, perr := pin_rw(e, page_no)
	if perr != .None {
		return {}, perr
	}
	init_empty_leaf(data)
	unpin_page(e, page_no)
	root^ = page_no
	return Btree{
		engine    = e,
		root      = page_no,
		bind      = .Caller_Root,
		root_slot = root,
	}, .None
}

// btree_open attaches to *root. Root splits update *root (Caller_Root).
btree_open :: proc(e: ^Engine, root: ^dbfile.Page_No) -> (tree: Btree, err: Engine_Error) {
	if err = require_open(e); err != .None {
		return {}, err
	}
	if root == nil || root^ == 0 {
		return {}, .Invalid_Argument
	}
	return Btree{
		engine    = e,
		root      = root^,
		bind      = .Caller_Root,
		root_slot = root,
	}, .None
}

btree_root :: proc(t: ^Btree) -> dbfile.Page_No {
	return t.root if t != nil else 0
}

btree_bind_prime :: proc(t: ^Btree) {
	if t == nil {
		return
	}
	t.bind = .Table_Prime
	t.root_slot = nil
	t.cat_key_len = 0
}

btree_bind_catalog_key :: proc(t: ^Btree, key: []u8) -> Engine_Error {
	if t == nil {
		return .Closed
	}
	if len(key) == 0 || len(key) > MAX_CATALOG_KEY {
		return .Invalid_Argument
	}
	t.bind = .Catalog_Object
	t.root_slot = nil
	t.cat_key_len = u16(len(key))
	copy(t.cat_key[:len(key)], key)
	return .None
}

// btree_require_root_bind rejects unbound trees before a root page is published.
btree_require_root_bind :: proc(t: ^Btree) -> Engine_Error {
	if t == nil {
		return .Closed
	}
	switch t.bind {
	case .None:
		return .Unbound_Root
	case .Caller_Root:
		if t.root_slot == nil {
			return .Unbound_Root
		}
		return .None
	case .Table_Prime, .Catalog_Object:
		return .None
	}
	return .Unbound_Root
}

// btree_persist_root write-through for a *candidate* new root (handle not advanced yet).
btree_persist_root :: proc(t: ^Btree, new_root: dbfile.Page_No) -> Engine_Error {
	if t == nil || t.engine == nil {
		return .Closed
	}
	if new_root == 0 {
		return .Invalid_Argument
	}
	if err := btree_require_root_bind(t); err != .None {
		return err
	}
	switch t.bind {
	case .None:
		return .Unbound_Root
	case .Caller_Root:
		t.root_slot^ = new_root
		return .None
	case .Table_Prime:
		t.engine.table_prime_root = new_root
		return .None
	case .Catalog_Object:
		return catalog_update_root(t.engine, t.cat_key[:t.cat_key_len], new_root)
	}
	return .Unbound_Root
}

// btree_commit_new_root persists ownership then advances the handle.
// On persist failure the handle root is unchanged (caller must free new_root).
btree_commit_new_root :: proc(t: ^Btree, new_root: dbfile.Page_No) -> Engine_Error {
	if err := btree_persist_root(t, new_root); err != .None {
		return err
	}
	t.root = new_root
	return .None
}

// btree_update_payload replaces payload for an existing key (same length only).
btree_update_payload :: proc(t: ^Btree, key, payload: []u8) -> Engine_Error {
	if t == nil || t.engine == nil {
		return .Closed
	}
	if err := require_txn(t.engine); err != .None {
		return err
	}
	if len(key) == 0 {
		return .Invalid_Argument
	}
	path := make([dynamic]Path_Slot, 0, 8)
	defer delete(path)
	leaf, err := btree_find_leaf(t, key, &path)
	if err != .None {
		return err
	}
	data, perr := pin_rw(t.engine, leaf)
	if perr != .None {
		return perr
	}
	defer unpin_page(t.engine, leaf)

	idx, exact, lerr := leaf_lower_bound(data, key)
	if lerr != .None {
		return lerr
	}
	if !exact {
		return .Not_Found
	}
	_, old_p, rerr := read_leaf_cell(data, idx)
	if rerr != .None {
		return rerr
	}
	if len(old_p) != len(payload) {
		return .Invalid_Argument
	}
	copy(old_p, payload)
	return .None
}

btree_insert :: proc(t: ^Btree, key, payload: []u8) -> Engine_Error {
	if t == nil || t.engine == nil {
		return .Closed
	}
	if err := require_txn(t.engine); err != .None {
		return err
	}
	if len(key) == 0 {
		return .Invalid_Argument
	}
	ps := int(t.engine.pager.page_size)
	if leaf_cell_size(len(key), len(payload)) > max_leaf_record(ps) {
		return .Too_Large
	}

	path := make([dynamic]Path_Slot, 0, 8)
	defer delete(path)

	leaf, err := btree_find_leaf(t, key, &path)
	if err != .None {
		return err
	}

	data, perr := pin_rw(t.engine, leaf)
	if perr != .None {
		return perr
	}
	ierr := leaf_insert_nosplit(data, key, payload)
	if ierr == .None || ierr == .Exists {
		unpin_page(t.engine, leaf)
		return ierr
	}
	if ierr != .Too_Large {
		unpin_page(t.engine, leaf)
		return ierr
	}
	unpin_page(t.engine, leaf)

	return btree_split_insert_leaf(t, leaf, key, payload, path[:])
}

btree_delete :: proc(t: ^Btree, key: []u8) -> Engine_Error {
	if t == nil || t.engine == nil {
		return .Closed
	}
	if err := require_txn(t.engine); err != .None {
		return err
	}
	path := make([dynamic]Path_Slot, 0, 8)
	defer delete(path)
	leaf, err := btree_find_leaf(t, key, &path)
	if err != .None {
		return err
	}
	data, perr := pin_rw(t.engine, leaf)
	if perr != .None {
		return perr
	}
	defer unpin_page(t.engine, leaf)

	idx, exact, lerr := leaf_lower_bound(data, key)
	if lerr != .None {
		return lerr
	}
	if !exact {
		return .Not_Found
	}
	return leaf_remove_at(data, idx)
}

btree_get :: proc(t: ^Btree, key: []u8, allocator := context.allocator) -> (payload: []u8, err: Engine_Error) {
	if t == nil || t.engine == nil {
		return nil, .Closed
	}
	if err := require_open(t.engine); err != .None {
		return nil, err
	}
	path := make([dynamic]Path_Slot, 0, 8)
	defer delete(path)
	leaf, ferr := btree_find_leaf(t, key, &path)
	if ferr != .None {
		return nil, ferr
	}
	data, perr := pin_ro(t.engine, leaf)
	if perr != .None {
		return nil, perr
	}
	defer unpin_page(t.engine, leaf)

	idx, exact, lerr := leaf_lower_bound(data, key)
	if lerr != .None {
		return nil, lerr
	}
	if !exact {
		return nil, .Not_Found
	}
	_, p, rerr := read_leaf_cell(data, idx)
	if rerr != .None {
		return nil, rerr
	}
	return slice.clone(p, allocator), .None
}

btree_find_leaf :: proc(t: ^Btree, key: []u8, path: ^[dynamic]Path_Slot) -> (dbfile.Page_No, Engine_Error) {
	page_no := t.root
	for {
		data, err := pin_ro(t.engine, page_no)
		if err != .None {
			return 0, err
		}
		ptype := page_type(data)
		if ptype == BTREE_PAGE_LEAF {
			unpin_page(t.engine, page_no)
			return page_no, .None
		}
		if ptype != BTREE_PAGE_INTERIOR {
			unpin_page(t.engine, page_no)
			return 0, .Corrupt
		}
		child, slot, cerr := interior_child_for_key(data, key)
		unpin_page(t.engine, page_no)
		if cerr != .None {
			return 0, cerr
		}
		append(path, Path_Slot{page_no = page_no, child_slot = slot})
		page_no = child
	}
}

btree_split_insert_leaf :: proc(
	t: ^Btree,
	leaf: dbfile.Page_No,
	key, payload: []u8,
	path: []Path_Slot,
) -> Engine_Error {
	page_size := int(t.engine.pager.page_size)

	data, err := pin_ro(t.engine, leaf)
	if err != .None {
		return err
	}

	recs, cerr := collect_leaf_records(data)
	if cerr != .None {
		unpin_page(t.engine, leaf)
		return cerr
	}
	defer free_leaf_records(recs)

	idx, exact, lerr := leaf_lower_bound(data, key)
	if lerr != .None {
		unpin_page(t.engine, leaf)
		return lerr
	}
	if exact {
		unpin_page(t.engine, leaf)
		return .Exists
	}

	old_next := dbfile.Page_No(page_special(data))
	leaf_backup := slice.clone(data)
	unpin_page(t.engine, leaf)
	defer delete(leaf_backup)

	all := make([]Leaf_Record, len(recs) + 1)
	defer free_leaf_records(all)
	for i in 0 ..< idx {
		all[i] = Leaf_Record{key = slice.clone(recs[i].key), payload = slice.clone(recs[i].payload)}
	}
	all[idx] = Leaf_Record{key = slice.clone(key), payload = slice.clone(payload)}
	for i in idx ..< len(recs) {
		all[i + 1] = Leaf_Record{key = slice.clone(recs[i].key), payload = slice.clone(recs[i].payload)}
	}

	mid, ok := choose_leaf_split_mid(page_size, all)
	if !ok {
		return .Too_Large // no safe split; no pages mutated
	}
	left_recs := all[:mid]
	right_recs := all[mid:]
	sep := slice.clone(right_recs[0].key)
	defer delete(sep)

	left_img := make([]u8, page_size)
	defer delete(left_img)
	right_img := make([]u8, page_size)
	defer delete(right_img)

	right_no, aerr := paging.alloc_page(&t.engine.pager)
	if aerr != .None {
		return from_page_error(aerr)
	}

	if perr := pack_leaf_scratch(left_img, left_recs, right_no); perr != .None {
		_ = paging.free_page(&t.engine.pager, right_no)
		return perr
	}
	if perr := pack_leaf_scratch(right_img, right_recs, old_next); perr != .None {
		_ = paging.free_page(&t.engine.pager, right_no)
		return perr
	}

	// Publish leaf halves only after both images packed successfully.
	if perr := publish_page(t.engine, leaf, left_img); perr != .None {
		_ = paging.free_page(&t.engine.pager, right_no)
		return perr
	}
	if perr := publish_page(t.engine, right_no, right_img); perr != .None {
		_ = publish_page(t.engine, leaf, leaf_backup)
		_ = paging.free_page(&t.engine.pager, right_no)
		return perr
	}

	serr := btree_insert_separator(t, path, sep, leaf, right_no)
	if serr != .None {
		// Roll back leaf mutation; free the sibling.
		_ = publish_page(t.engine, leaf, leaf_backup)
		_ = paging.free_page(&t.engine.pager, right_no)
		return serr
	}
	return .None
}

btree_insert_separator :: proc(
	t: ^Btree,
	path: []Path_Slot,
	sep: []u8,
	left, right: dbfile.Page_No,
) -> Engine_Error {
	page_size := int(t.engine.pager.page_size)

	if len(path) == 0 {
		// Fail before allocating a new root if ownership is unbound (W2).
		if err := btree_require_root_bind(t); err != .None {
			return err
		}
		root_img := make([]u8, page_size)
		defer delete(root_img)
		recs := []Interior_Record{{child = left, key = sep}}
		if rerr := pack_interior_scratch(root_img, recs, right); rerr != .None {
			return rerr
		}
		root_no, aerr := paging.alloc_page(&t.engine.pager)
		if aerr != .None {
			return from_page_error(aerr)
		}
		if perr := publish_page(t.engine, root_no, root_img); perr != .None {
			_ = paging.free_page(&t.engine.pager, root_no)
			return perr
		}
		// Persist ownership before advancing t.root. On failure free the orphan
		// interior so leaf-split rollback (restore leaf + free sibling) stays consistent.
		if err := btree_commit_new_root(t, root_no); err != .None {
			_ = paging.free_page(&t.engine.pager, root_no)
			return err
		}
		return .None
	}

	parent_slot := path[len(path) - 1]
	parent := parent_slot.page_no
	slot := parent_slot.child_slot
	parent_path := path[:len(path) - 1]

	data, err := pin_ro(t.engine, parent)
	if err != .None {
		return err
	}

	irecs, ierr := collect_interior_records(data)
	if ierr != .None {
		unpin_page(t.engine, parent)
		return ierr
	}
	defer free_interior_records(irecs)
	rightmost := dbfile.Page_No(page_special(data))
	parent_backup := slice.clone(data)
	unpin_page(t.engine, parent)
	defer delete(parent_backup)

	n := len(irecs)
	new_recs: [dynamic]Interior_Record
	defer {
		for r in new_recs {
			delete(r.key)
		}
		delete(new_recs)
	}

	new_rightmost := rightmost
	if slot < n {
		for i in 0 ..< slot {
			append(&new_recs, Interior_Record{child = irecs[i].child, key = slice.clone(irecs[i].key)})
		}
		append(&new_recs, Interior_Record{child = left, key = slice.clone(sep)})
		append(&new_recs, Interior_Record{child = right, key = slice.clone(irecs[slot].key)})
		for i in slot + 1 ..< n {
			append(&new_recs, Interior_Record{child = irecs[i].child, key = slice.clone(irecs[i].key)})
		}
	} else {
		for i in 0 ..< n {
			append(&new_recs, Interior_Record{child = irecs[i].child, key = slice.clone(irecs[i].key)})
		}
		append(&new_recs, Interior_Record{child = left, key = slice.clone(sep)})
		new_rightmost = right
	}

	parent_img := make([]u8, page_size)
	defer delete(parent_img)
	rerr := pack_interior_scratch(parent_img, new_recs[:], new_rightmost)
	if rerr == .None {
		return publish_page(t.engine, parent, parent_img)
	}
	if rerr != .Too_Large {
		return rerr
	}

	// Parent full — split without having mutated parent.
	return btree_split_interior(t, parent, new_recs[:], new_rightmost, parent_path, parent_backup)
}

btree_split_interior :: proc(
	t: ^Btree,
	page_no: dbfile.Page_No,
	recs: []Interior_Record,
	rightmost: dbfile.Page_No,
	path: []Path_Slot,
	page_backup: []u8,
) -> Engine_Error {
	page_size := int(t.engine.pager.page_size)
	n := len(recs)
	if n < 2 {
		return .Corrupt
	}

	mid, ok := choose_interior_split_mid(page_size, recs)
	if !ok {
		return .Too_Large
	}

	left_recs := make([]Interior_Record, mid)
	defer free_interior_records(left_recs)
	for i in 0 ..< mid {
		left_recs[i] = Interior_Record{child = recs[i].child, key = slice.clone(recs[i].key)}
	}
	left_rightmost := recs[mid].child
	promo := slice.clone(recs[mid].key)
	defer delete(promo)

	right_count := n - mid - 1
	right_recs := make([]Interior_Record, right_count)
	defer free_interior_records(right_recs)
	for i in 0 ..< right_count {
		src := mid + 1 + i
		right_recs[i] = Interior_Record{child = recs[src].child, key = slice.clone(recs[src].key)}
	}
	right_rightmost := rightmost

	left_img := make([]u8, page_size)
	defer delete(left_img)
	right_img := make([]u8, page_size)
	defer delete(right_img)

	if err := pack_interior_scratch(left_img, left_recs, left_rightmost); err != .None {
		return err
	}
	if err := pack_interior_scratch(right_img, right_recs, right_rightmost); err != .None {
		return err
	}

	right_no, aerr := paging.alloc_page(&t.engine.pager)
	if aerr != .None {
		return from_page_error(aerr)
	}

	if err := publish_page(t.engine, page_no, left_img); err != .None {
		_ = paging.free_page(&t.engine.pager, right_no)
		return err
	}
	if err := publish_page(t.engine, right_no, right_img); err != .None {
		_ = publish_page(t.engine, page_no, page_backup)
		_ = paging.free_page(&t.engine.pager, right_no)
		return err
	}

	serr := btree_insert_separator(t, path, promo, page_no, right_no)
	if serr != .None {
		_ = publish_page(t.engine, page_no, page_backup)
		_ = paging.free_page(&t.engine.pager, right_no)
		return serr
	}
	return .None
}

// btree_free_tree walks every page of the btree rooted at `root` and returns
// them to the freelist (interior children first, then the node). Requires txn.
btree_free_tree :: proc(e: ^Engine, root: dbfile.Page_No) -> Engine_Error {
	if root == 0 {
		return .None
	}
	if err := require_txn(e); err != .None {
		return err
	}
	return btree_free_node(e, root)
}

btree_free_node :: proc(e: ^Engine, page_no: dbfile.Page_No) -> Engine_Error {
	data, perr := pin_ro(e, page_no)
	if perr != .None {
		return perr
	}
	kind := page_type(data)
	if kind == BTREE_PAGE_INTERIOR {
		n := int(page_n_cells(data))
		children := make([dynamic]dbfile.Page_No, 0, n + 1)
		defer delete(children)
		for i in 0 ..< n {
			ch, _, cerr := read_interior_cell(data, i)
			if cerr != .None {
				unpin_page(e, page_no)
				return cerr
			}
			append(&children, ch)
		}
		rightmost := dbfile.Page_No(page_special(data))
		if rightmost != 0 {
			append(&children, rightmost)
		}
		unpin_page(e, page_no)
		for ch in children {
			if err := btree_free_node(e, ch); err != .None {
				return err
			}
		}
	} else if kind == BTREE_PAGE_LEAF {
		unpin_page(e, page_no)
	} else {
		unpin_page(e, page_no)
		return .Corrupt
	}
	return page_free(e, page_no)
}

// --- test / introspection helpers (read-only) ---

btree_page_kind :: proc(e: ^Engine, page_no: dbfile.Page_No) -> (kind: u8, err: Engine_Error) {
	data, perr := pin_ro(e, page_no)
	if perr != .None {
		return 0, perr
	}
	defer unpin_page(e, page_no)
	return page_type(data), .None
}

// btree_leftmost_leaf descends from `root` to the leftmost leaf page.
btree_leftmost_leaf :: proc(e: ^Engine, root: dbfile.Page_No) -> (dbfile.Page_No, Engine_Error) {
	page_no := root
	for {
		kind, err := btree_page_kind(e, page_no)
		if err != .None {
			return 0, err
		}
		if kind == BTREE_PAGE_LEAF {
			return page_no, .None
		}
		if kind != BTREE_PAGE_INTERIOR {
			return 0, .Corrupt
		}
		data, perr := pin_ro(e, page_no)
		if perr != .None {
			return 0, perr
		}
		child, cerr := child_at_slot(data, 0)
		unpin_page(e, page_no)
		if cerr != .None {
			return 0, cerr
		}
		page_no = child
	}
}

btree_leaf_next :: proc(e: ^Engine, leaf: dbfile.Page_No) -> (next: dbfile.Page_No, err: Engine_Error) {
	data, perr := pin_ro(e, leaf)
	if perr != .None {
		return 0, perr
	}
	defer unpin_page(e, leaf)
	if page_type(data) != BTREE_PAGE_LEAF {
		return 0, .Invalid_Argument
	}
	return dbfile.Page_No(page_special(data)), .None
}
