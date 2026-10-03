package main

import "core:fmt"
import "core:os"
import "core:strings"
import sql "../../src/sql"

FIXTURES :: []string{"bootstrap.sql", "bootstrap_v1.sql", "crud.sql", "phase5.sql"}

main :: proc() {
	root := "src/test/sql/fixtures"
	for name in FIXTURES {
		sql_path := fmt.tprintf("%s/%s", root, name)
		data, read_err := os.read_entire_file_from_path(sql_path, context.allocator)
		if read_err != os.ERROR_NONE {
			fmt.eprintf("failed to read %s: %v\n", sql_path, read_err)
			os.exit(1)
		}
		defer delete(data)

		script, err := sql.parse_script(string(data))
		if sql.has_error(err) {
			fmt.eprintf("%s: %s\n", name, err.message)
			sql.free_error(err)
			os.exit(1)
		}
		defer sql.free_script(script)

		dump := sql.print_script(script)
		defer delete(dump)
		trimmed := strings.trim_right(dump, " \t\r\n")
		out := fmt.tprintf("%s\n", trimmed)

		ast_path := fmt.tprintf("%s/%s.ast", root, name[:len(name) - 4])
		werr := os.write_entire_file(ast_path, out)
		if werr != nil {
			fmt.eprintf("failed to write %s: %v\n", ast_path, werr)
			os.exit(1)
		}
		fmt.printf("wrote %s\n", ast_path)
	}
}
