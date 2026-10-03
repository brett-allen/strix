package exec

Result_Kind :: enum {
	Ok,
	Rows_Affected,
	Result_Set,
}

Exec_Result :: struct {
	kind:          Result_Kind,
	rows_affected: int,
	column_names:  []string, // Result_Set: owned names
	rows:          [][]string, // Result_Set: owned cell strings
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

rows_affected_result :: proc(n: int) -> Exec_Result {
	return Exec_Result{kind = .Rows_Affected, rows_affected = n}
}

// result_set_result takes ownership of column_names and rows.
result_set_result :: proc(column_names: []string, rows: [][]string) -> Exec_Result {
	return Exec_Result{
		kind         = .Result_Set,
		column_names = column_names,
		rows         = rows,
	}
}
