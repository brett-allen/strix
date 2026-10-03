package engine

import "core:os"
import dbfile "../dbfile"
import paging "../paging"

// engine_create creates a new DB file (page 0 initialized) and opens a session.
engine_create :: proc(path: string, opts: Engine_Options = {}) -> (e: Engine, err: Engine_Error) {
	p, perr := paging.pager_open_create(path, opts.pager, opts.db)
	if perr != .None {
		return {}, from_page_error(perr)
	}
	e, err = engine_from_pager(p)
	if err != .None {
		paging.pager_close(&p)
		os.remove(path)
		return {}, err
	}
	if err = engine_ensure_catalog(&e); err != .None {
		engine_close(&e)
		os.remove(path)
		return {}, err
	}
	return e, .None
}

// engine_open opens an existing DB file.
engine_open :: proc(path: string, opts: Engine_Options = {}) -> (e: Engine, err: Engine_Error) {
	p, perr := paging.pager_open_existing(path, opts.pager)
	if perr != .None {
		return {}, from_page_error(perr)
	}
	e, err = engine_from_pager(p)
	if err != .None {
		paging.pager_close(&p)
		return {}, err
	}
	if e.table_prime_root == 0 {
		engine_close(&e)
		return {}, .Catalog_Missing
	}
	return e, .None
}

// engine_open_memory creates an in-memory DB session (tests).
engine_open_memory :: proc(opts: Engine_Options = {}) -> (e: Engine, err: Engine_Error) {
	p, perr := paging.pager_open_memory(opts.pager, opts.db)
	if perr != .None {
		return {}, from_page_error(perr)
	}
	e, err = engine_from_pager(p)
	if err != .None {
		paging.pager_close(&p)
		return {}, err
	}
	if err = engine_ensure_catalog(&e); err != .None {
		engine_close(&e)
		return {}, err
	}
	return e, .None
}

engine_from_pager :: proc(p: paging.Pager) -> (e: Engine, err: Engine_Error) {
	pager := p
	boot, berr := dbfile.read_bootstrap(&pager.file)
	if berr != .None {
		paging.pager_close(&pager)
		return {}, .Db
	}
	e = Engine{
		pager            = pager,
		closed           = false,
		in_txn           = false,
		commit_counter   = boot.commit_counter,
		schema_cookie    = boot.schema_cookie,
		table_prime_root = boot.table_prime_root,
	}
	return e, .None
}

engine_close :: proc(e: ^Engine) -> Engine_Error {
	if e == nil || e.closed {
		return .None
	}
	// Rollback any open txn so dirty pages are not silently flushed.
	if e.in_txn {
		_ = txn_rollback(e)
	}
	err := from_page_error(paging.pager_close(&e.pager))
	e.closed = true
	e.in_txn = false
	return err
}

txn_begin :: proc(e: ^Engine) -> Engine_Error {
	if err := require_open(e); err != .None {
		return err
	}
	if e.in_txn {
		return .In_Txn
	}
	e.txn_schema_cookie = e.schema_cookie
	e.txn_table_prime_root = e.table_prime_root
	e.in_txn = true
	return .None
}

// txn_commit flushes dirty pages (data → page 0 → sync) and bumps commit_counter.
// Persists schema_cookie and table_prime_root from engine meta into page 0.
txn_commit :: proc(e: ^Engine) -> Engine_Error {
	if err := require_open(e); err != .None {
		return err
	}
	if !e.in_txn {
		return .No_Txn
	}

	next_counter := e.commit_counter + 1
	boot := dbfile.Bootstrap{
		commit_counter   = next_counter,
		schema_cookie    = e.schema_cookie,
		table_prime_root = e.table_prime_root,
	}
	ferr := paging.flush(&e.pager, boot)
	if ferr != .None {
		// Stay in_txn; pager may set flush_failed fence (H2).
		return from_page_error(ferr)
	}
	e.commit_counter = next_counter
	e.in_txn = false
	return .None
}

// txn_rollback discards dirty pager state and restores schema_cookie / table_prime_root.
// Refuses discard after a partial flush failure (.Flush_Failed) until a flush succeeds.
txn_rollback :: proc(e: ^Engine) -> Engine_Error {
	if err := require_open(e); err != .None {
		return err
	}
	if !e.in_txn {
		return .No_Txn
	}
	derr := paging.discard_dirty(&e.pager)
	if derr != .None {
		return from_page_error(derr)
	}
	e.schema_cookie = e.txn_schema_cookie
	e.table_prime_root = e.txn_table_prime_root
	e.in_txn = false
	return .None
}

require_open :: proc(e: ^Engine) -> Engine_Error {
	if e == nil || e.closed {
		return .Closed
	}
	return .None
}

require_txn :: proc(e: ^Engine) -> Engine_Error {
	if err := require_open(e); err != .None {
		return err
	}
	if !e.in_txn {
		return .No_Txn
	}
	return .None
}

page_size :: proc(e: ^Engine) -> u32 {
	if e == nil {
		return 0
	}
	return e.pager.page_size
}

commit_counter :: proc(e: ^Engine) -> u32 {
	if e == nil {
		return 0
	}
	return e.commit_counter
}

schema_cookie :: proc(e: ^Engine) -> u32 {
	if e == nil {
		return 0
	}
	return e.schema_cookie
}

// engine_pager_unsafe_for_tests exposes the pager for pager-level tests only.
// Do NOT call paging.flush on this handle for engine DBs — it skips engine meta
// (commit_counter / schema_cookie / table_prime_root) unless you pass a full Bootstrap.
engine_pager_unsafe_for_tests :: proc(e: ^Engine) -> ^paging.Pager {
	if e == nil || e.closed {
		return nil
	}
	return &e.pager
}
