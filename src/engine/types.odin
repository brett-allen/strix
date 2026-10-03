package engine

import dbfile "../dbfile"
import paging "../paging"

Engine_Options :: struct {
	pager:    paging.Pager_Options,
	db:       dbfile.Open_Options,
}

/*
	Engine — session + transactions over paging.

	B+tree KV API lives in this package (S3). table_prime catalog is S4.
	Catalog-backed btree root identity is write-through (not handle-local only).
*/
Engine :: struct {
	pager:                 paging.Pager,
	closed:                bool,
	in_txn:                bool,
	commit_counter:        u32,
	schema_cookie:         u32,
	table_prime_root:      dbfile.Page_No,
	// Snapshots taken at txn_begin; restored on txn_rollback (H1).
	txn_schema_cookie:     u32,
	txn_table_prime_root:  dbfile.Page_No,
}
