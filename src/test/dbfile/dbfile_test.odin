package dbfile_tests

import "core:fmt"
import "core:os"
import "core:testing"
import dbfile "../../dbfile"

@(test)
test_memory_create_bootstrap :: proc(t: ^testing.T) {
	f, err := dbfile.open_memory()
	testing.expectf(t, dbfile.ok(err), "open_memory: %v", err)
	defer dbfile.close(&f)

	testing.expect_value(t, f.page_size, dbfile.DEFAULT_PAGE_SIZE)
	testing.expect_value(t, f.page_count, u32(1))

	boot, berr := dbfile.read_bootstrap(&f)
	testing.expectf(t, dbfile.ok(berr), "read_bootstrap: %v", berr)
	testing.expect_value(t, boot.format_version, dbfile.FORMAT_VERSION)
	testing.expect_value(t, boot.page_size, dbfile.DEFAULT_PAGE_SIZE)
	testing.expect_value(t, boot.page_count, u32(1))
	testing.expect_value(t, boot.freelist_head, dbfile.Page_No(0))
	testing.expect_value(t, boot.table_prime_root, dbfile.Page_No(0))
	testing.expect(t, boot.checksum != 0)
}

@(test)
test_memory_write_page_n_and_read_back :: proc(t: ^testing.T) {
	f, err := dbfile.open_memory()
	testing.expect(t, dbfile.ok(err))
	defer dbfile.close(&f)

	page := make([]u8, f.page_size)
	defer delete(page)
	for i in 0 ..< len(page) {
		page[i] = u8(i & 0xff)
	}
	page[0] = 0xA5
	page[1] = 0x5A

	err = dbfile.write_page(&f, 3, page)
	testing.expectf(t, dbfile.ok(err), "write_page: %v", err)
	testing.expect_value(t, f.page_count, u32(4))

	boot, berr := dbfile.read_bootstrap(&f)
	testing.expect(t, dbfile.ok(berr))
	boot.page_count = f.page_count
	err = dbfile.write_bootstrap(&f, boot)
	testing.expectf(t, dbfile.ok(err), "write_bootstrap: %v", err)
	err = dbfile.sync(&f)
	testing.expect(t, dbfile.ok(err))

	got := make([]u8, f.page_size)
	defer delete(got)
	err = dbfile.read_page(&f, 3, got)
	testing.expectf(t, dbfile.ok(err), "read_page: %v", err)
	testing.expect_value(t, got[0], u8(0xA5))
	testing.expect_value(t, got[1], u8(0x5A))
	testing.expect_value(t, got[255], page[255])
}

@(test)
test_tempfile_create_reopen_roundtrip :: proc(t: ^testing.T) {
	path := test_temp_path("strix-dbfile-roundtrip.strix")
	defer os.remove(path)

	{
		f, err := dbfile.open_create(path)
		testing.expectf(t, dbfile.ok(err), "open_create: %v", err)

		payload := make([]u8, f.page_size)
		defer delete(payload)
		payload[0] = 'S'
		payload[1] = 'T'
		payload[2] = 'R'
		payload[100] = 42

		err = dbfile.write_page(&f, 2, payload)
		testing.expect(t, dbfile.ok(err))

		boot, berr := dbfile.read_bootstrap(&f)
		testing.expect(t, dbfile.ok(berr))
		boot.page_count = f.page_count
		boot.commit_counter = 7
		err = dbfile.write_bootstrap(&f, boot)
		testing.expect(t, dbfile.ok(err))
		err = dbfile.sync(&f)
		testing.expect(t, dbfile.ok(err))
		err = dbfile.close(&f)
		testing.expect(t, dbfile.ok(err))
	}

	{
		f, err := dbfile.open_existing(path)
		testing.expectf(t, dbfile.ok(err), "open_existing: %v", err)
		defer dbfile.close(&f)

		testing.expect_value(t, f.page_size, dbfile.DEFAULT_PAGE_SIZE)
		testing.expect_value(t, f.page_count, u32(3))

		boot, berr := dbfile.read_bootstrap(&f)
		testing.expect(t, dbfile.ok(berr))
		testing.expect_value(t, boot.page_count, u32(3))
		testing.expect_value(t, boot.commit_counter, u32(7))

		got := make([]u8, f.page_size)
		defer delete(got)
		err = dbfile.read_page(&f, 2, got)
		testing.expect(t, dbfile.ok(err))
		testing.expect_value(t, got[0], u8('S'))
		testing.expect_value(t, got[1], u8('T'))
		testing.expect_value(t, got[2], u8('R'))
		testing.expect_value(t, got[100], u8(42))
	}
}

@(test)
test_reject_bad_magic :: proc(t: ^testing.T) {
	path := test_temp_path("strix-dbfile-bad-magic.strix")
	defer os.remove(path)

	file, os_err := os.open(path, {.Read, .Write, .Create, .Trunc})
	testing.expect(t, os_err == nil || os_err == os.ERROR_NONE)
	junk := make([]u8, dbfile.DEFAULT_PAGE_SIZE)
	defer delete(junk)
	copy(junk, transmute([]u8)string("NotStrixXXXX"))
	_, werr := os.write_at(file, junk, 0)
	testing.expect(t, werr == nil || werr == os.ERROR_NONE)
	os.close(file)

	f, err := dbfile.open_existing(path)
	testing.expect_value(t, err, dbfile.Db_Error.Bad_Magic)
	testing.expect(t, f.closed || f.vfs.impl == nil)
}

@(test)
test_reject_corrupt_checksum :: proc(t: ^testing.T) {
	path := test_temp_path("strix-dbfile-bad-cksum.strix")
	defer os.remove(path)

	{
		f, err := dbfile.open_create(path)
		testing.expect(t, dbfile.ok(err))
		dbfile.close(&f)
	}

	file, os_err := os.open(path, {.Read, .Write})
	testing.expect(t, os_err == nil || os_err == os.ERROR_NONE)
	// Flip a byte inside the checksummed region (page_count field).
	patch := []u8{0xFF}
	_, werr := os.write_at(file, patch, 16)
	testing.expect(t, werr == nil || werr == os.ERROR_NONE)
	os.close(file)

	f, err := dbfile.open_existing(path)
	testing.expect_value(t, err, dbfile.Db_Error.Bad_Checksum)
	_ = f
}

@(test)
test_decode_rejects_out_of_range_roots :: proc(t: ^testing.T) {
	// M2: freelist_head / table_prime_root must be 0 or < page_count.
	boot := dbfile.Bootstrap{
		format_version   = dbfile.FORMAT_VERSION,
		page_size        = 4096,
		page_count       = 3,
		freelist_head    = 9,
		table_prime_root = 1,
	}
	buf: [dbfile.BOOTSTRAP_HEADER_SIZE]u8
	_, err := dbfile.encode_bootstrap(boot, buf[:])
	testing.expect(t, dbfile.ok(err))
	_, derr := dbfile.decode_bootstrap(buf[:], true)
	testing.expect_value(t, derr, dbfile.Db_Error.Invalid_Argument)

	boot2 := dbfile.Bootstrap{
		format_version   = dbfile.FORMAT_VERSION,
		page_size        = 4096,
		page_count       = 3,
		freelist_head    = 0,
		table_prime_root = 3,
	}
	_, err2 := dbfile.encode_bootstrap(boot2, buf[:])
	testing.expect(t, dbfile.ok(err2))
	_, derr2 := dbfile.decode_bootstrap(buf[:], true)
	testing.expect_value(t, derr2, dbfile.Db_Error.Invalid_Argument)
}

@(test)
test_encode_decode_roundtrip :: proc(t: ^testing.T) {
	boot := dbfile.Bootstrap{
		format_version   = dbfile.FORMAT_VERSION,
		page_size        = 4096,
		page_count       = 12,
		freelist_head    = 4,
		commit_counter   = 99,
		schema_cookie    = 3,
		table_prime_root = 7,
	}
	buf: [dbfile.BOOTSTRAP_HEADER_SIZE]u8
	cksum, err := dbfile.encode_bootstrap(boot, buf[:])
	testing.expect(t, dbfile.ok(err))
	testing.expect(t, cksum != 0)

	got, derr := dbfile.decode_bootstrap(buf[:], true)
	testing.expect(t, dbfile.ok(derr))
	testing.expect_value(t, got.page_size, boot.page_size)
	testing.expect_value(t, got.page_count, boot.page_count)
	testing.expect_value(t, got.freelist_head, boot.freelist_head)
	testing.expect_value(t, got.commit_counter, boot.commit_counter)
	testing.expect_value(t, got.schema_cookie, boot.schema_cookie)
	testing.expect_value(t, got.table_prime_root, boot.table_prime_root)
	testing.expect_value(t, got.checksum, cksum)
}

@(test)
test_open_create_rejects_existing :: proc(t: ^testing.T) {
	path := test_temp_path("strix-dbfile-exists.strix")
	defer os.remove(path)

	f, err := dbfile.open_create(path)
	testing.expect(t, dbfile.ok(err))
	dbfile.close(&f)

	_, err2 := dbfile.open_create(path)
	testing.expect_value(t, err2, dbfile.Db_Error.Exist)
}

test_temp_path :: proc(name: string) -> string {
	return fmt.tprintf("/tmp/%s", name)
}
