package dbfile

import "core:mem"
import "core:os"
import "core:slice"

// Vfs is a minimal byte-store seam so tests can run in memory without touching disk.
Vfs :: struct {
	impl:     rawptr,
	read_at:  proc(v: ^Vfs, offset: i64, buf: []u8) -> Db_Error,
	write_at: proc(v: ^Vfs, offset: i64, buf: []u8) -> Db_Error,
	size:     proc(v: ^Vfs) -> (i64, Db_Error),
	truncate: proc(v: ^Vfs, size: i64) -> Db_Error,
	sync:     proc(v: ^Vfs) -> Db_Error,
	close:    proc(v: ^Vfs) -> Db_Error,
}

// --- OS file backend ---------------------------------------------------------

Os_Vfs :: struct {
	file: ^os.File,
}

vfs_from_os_file :: proc(file: ^os.File, allocator := context.allocator) -> (Vfs, Db_Error) {
	backend := new(Os_Vfs, allocator)
	if backend == nil {
		return {}, .Io
	}
	backend.file = file
	return Vfs{
		impl     = backend,
		read_at  = os_vfs_read_at,
		write_at = os_vfs_write_at,
		size     = os_vfs_size,
		truncate = os_vfs_truncate,
		sync     = os_vfs_sync,
		close    = os_vfs_close,
	}, .None
}

os_vfs_read_at :: proc(v: ^Vfs, offset: i64, buf: []u8) -> Db_Error {
	backend := (^Os_Vfs)(v.impl)
	n, err := os.read_at(backend.file, buf, offset)
	if err != nil && err != os.ERROR_NONE {
		return .Io
	}
	if n != len(buf) {
		return .Short_Read
	}
	return .None
}

os_vfs_write_at :: proc(v: ^Vfs, offset: i64, buf: []u8) -> Db_Error {
	backend := (^Os_Vfs)(v.impl)
	n, err := os.write_at(backend.file, buf, offset)
	if err != nil && err != os.ERROR_NONE {
		return .Io
	}
	if n != len(buf) {
		return .Short_Write
	}
	return .None
}

os_vfs_size :: proc(v: ^Vfs) -> (i64, Db_Error) {
	backend := (^Os_Vfs)(v.impl)
	n, err := os.file_size(backend.file)
	if err != nil && err != os.ERROR_NONE {
		return 0, .Io
	}
	return n, .None
}

os_vfs_truncate :: proc(v: ^Vfs, size: i64) -> Db_Error {
	backend := (^Os_Vfs)(v.impl)
	err := os.truncate(backend.file, size)
	if err != nil && err != os.ERROR_NONE {
		return .Io
	}
	return .None
}

os_vfs_sync :: proc(v: ^Vfs) -> Db_Error {
	backend := (^Os_Vfs)(v.impl)
	err := os.sync(backend.file)
	if err != nil && err != os.ERROR_NONE {
		return .Io
	}
	return .None
}

os_vfs_close :: proc(v: ^Vfs) -> Db_Error {
	backend := (^Os_Vfs)(v.impl)
	if backend == nil {
		return .None
	}
	err := os.close(backend.file)
	free(backend)
	v.impl = nil
	if err != nil && err != os.ERROR_NONE {
		return .Io
	}
	return .None
}

// --- Memory backend ----------------------------------------------------------

Mem_Vfs :: struct {
	data:      [dynamic]u8,
	allocator: mem.Allocator,
}

open_memory_vfs :: proc(allocator := context.allocator) -> (Vfs, Db_Error) {
	backend := new(Mem_Vfs, allocator)
	if backend == nil {
		return {}, .Io
	}
	backend.allocator = allocator
	backend.data = make([dynamic]u8, 0, DEFAULT_PAGE_SIZE, allocator)
	return Vfs{
		impl     = backend,
		read_at  = mem_vfs_read_at,
		write_at = mem_vfs_write_at,
		size     = mem_vfs_size,
		truncate = mem_vfs_truncate,
		sync     = mem_vfs_sync,
		close    = mem_vfs_close,
	}, .None
}

mem_vfs_ensure :: proc(backend: ^Mem_Vfs, end: i64) -> Db_Error {
	if end < 0 {
		return .Invalid_Argument
	}
	need := int(end)
	if need <= len(backend.data) {
		return .None
	}
	old_len := len(backend.data)
	resize(&backend.data, need)
	if len(backend.data) < need {
		return .Io
	}
	for i in old_len ..< need {
		backend.data[i] = 0
	}
	return .None
}

mem_vfs_read_at :: proc(v: ^Vfs, offset: i64, buf: []u8) -> Db_Error {
	backend := (^Mem_Vfs)(v.impl)
	if offset < 0 {
		return .Invalid_Argument
	}
	end := offset + i64(len(buf))
	if end > i64(len(backend.data)) {
		return .Short_Read
	}
	copy(buf, backend.data[offset:end])
	return .None
}

mem_vfs_write_at :: proc(v: ^Vfs, offset: i64, buf: []u8) -> Db_Error {
	backend := (^Mem_Vfs)(v.impl)
	if offset < 0 {
		return .Invalid_Argument
	}
	end := offset + i64(len(buf))
	if err := mem_vfs_ensure(backend, end); err != .None {
		return err
	}
	copy(backend.data[offset:end], buf)
	return .None
}

mem_vfs_size :: proc(v: ^Vfs) -> (i64, Db_Error) {
	backend := (^Mem_Vfs)(v.impl)
	return i64(len(backend.data)), .None
}

mem_vfs_truncate :: proc(v: ^Vfs, size: i64) -> Db_Error {
	backend := (^Mem_Vfs)(v.impl)
	if size < 0 {
		return .Invalid_Argument
	}
	need := int(size)
	old_len := len(backend.data)
	resize(&backend.data, need)
	if len(backend.data) < need {
		return .Io
	}
	if need > old_len {
		slice.zero(backend.data[old_len:need])
	}
	return .None
}

mem_vfs_sync :: proc(v: ^Vfs) -> Db_Error {
	_ = v
	return .None
}

mem_vfs_close :: proc(v: ^Vfs) -> Db_Error {
	backend := (^Mem_Vfs)(v.impl)
	if backend == nil {
		return .None
	}
	delete(backend.data)
	free(backend)
	v.impl = nil
	return .None
}
