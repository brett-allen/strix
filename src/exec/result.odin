package exec

Result_Kind :: enum {
	Ok,
	Rows_Affected,
	Result_Set, // reserved for SELECT (E3)
}

Exec_Result :: struct {
	kind:          Result_Kind,
	rows_affected: int,
	// SELECT fields reserved for E3
	column_names:  []string,
	rows:          [][]string,
}

free_result :: proc(result: Exec_Result, allocator := context.allocator) {
	for name in result.column_names {
		if name != "" {
			delete(name, allocator)
		}
	}
	if result.column_names != nil {
		delete(result.column_names, allocator)
	}
	for row in result.rows {
		for cell in row {
			if cell != "" {
				delete(cell, allocator)
			}
		}
		if row != nil {
			delete(row, allocator)
		}
	}
	if result.rows != nil {
		delete(result.rows, allocator)
	}
}

ok_result :: proc() -> Exec_Result {
	return Exec_Result{kind = .Ok}
}
