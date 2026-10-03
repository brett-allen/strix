package cli

import "core:fmt"
import "core:os"
import "core:strings"
import engine "../engine"
import exec "../exec"

DEFAULT_DB_PATH :: "database.strix"

// ensure_strix_path returns a heap-allocated path that ends with ".strix".
// Caller owns the result.
ensure_strix_path :: proc(path: string) -> string {
	if path == "" {
		return strings.clone(DEFAULT_DB_PATH)
	}
	if strings.has_suffix(path, ".strix") {
		return strings.clone(path)
	}
	return strings.concatenate({path, ".strix"})
}

// init_database creates a new Strix DB file (page 0 + table_prime) at path.
// Returns a process exit code: 0 on success, non-zero on failure.
init_database :: proc(path: string) -> int {
	resolved := ensure_strix_path(path)
	defer delete(resolved)

	e, err := engine.engine_create(resolved)
	if err != .None {
		fmt.eprintf("strix init: failed to create %s: %s\n", resolved, engine.error_string(err))
		return 1
	}
	engine.engine_close(&e)

	fmt.printf("created %s\n", resolved)
	return 0
}

print_usage :: proc() {
	fmt.eprintf(
		"Usage: strix <command> [args]\n" +
		"\n" +
		"Commands:\n" +
		"  init [path]              Create a new .strix database (default: %s)\n" +
		"  sql  [path] -c 'SQL'     Run SQL string against a database\n" +
		"  sql  [path] file.sql     Run SQL script file\n" +
		"  sql  [path]              Run SQL from stdin\n" +
		"      --continue-on-error  Keep running after statement errors\n" +
		"  help                     Show this help\n",
		DEFAULT_DB_PATH,
	)
}

// run_sql opens path and executes sql_text. Returns process exit code.
run_sql :: proc(path: string, sql_text: string, opts := exec.Exec_Options{}) -> int {
	resolved := ensure_strix_path(path)
	defer delete(resolved)

	session, err := exec.session_open(resolved)
	if exec.has_error(err) {
		fmt.eprintf("strix sql: open %s: %s\n", resolved, err.message)
		exec.free_error(err)
		return 1
	}
	defer exec.session_close(&session)

	result, eerr := exec.exec_script(&session, sql_text, opts)
	if exec.has_error(eerr) {
		loc := opts.source_path
		formatted := exec.format_error(eerr, loc)
		defer delete(formatted)
		fmt.eprintf("strix sql: %s\n", formatted)
		exec.free_error(eerr)
		exec.free_result(result)
		return 1
	}
	defer exec.free_result(result)

	switch result.kind {
	case .Ok:
		fmt.println("ok")
	case .Rows_Affected:
		fmt.printf("%d rows\n", result.rows_affected)
	case .Result_Set:
		print_result_set(result)
	}
	return 0
}

// format_result_set builds an aligned text table (header + rows). Caller deletes the string.
format_result_set :: proc(result: exec.Exec_Result, allocator := context.allocator) -> string {
	ncols := len(result.column_names)
	if ncols == 0 {
		return ""
	}
	widths := make([]int, ncols, allocator)
	defer delete(widths, allocator)
	for name, i in result.column_names {
		widths[i] = len(name)
	}
	for row in result.rows {
		for i in 0 ..< min(ncols, len(row)) {
			if len(row[i]) > widths[i] {
				widths[i] = len(row[i])
			}
		}
	}
	b: strings.Builder
	strings.builder_init(&b, allocator)
	for i in 0 ..< ncols {
		if i > 0 {
			strings.write_string(&b, "  ")
		}
		fmt.sbprintf(&b, "%-*s", widths[i], result.column_names[i])
	}
	strings.write_byte(&b, '\n')
	for row in result.rows {
		for i in 0 ..< ncols {
			if i > 0 {
				strings.write_string(&b, "  ")
			}
			cell := ""
			if i < len(row) {
				cell = row[i]
			}
			fmt.sbprintf(&b, "%-*s", widths[i], cell)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// print_result_set writes an aligned text table (header + rows) to stdout.
print_result_set :: proc(result: exec.Exec_Result) {
	text := format_result_set(result)
	defer delete(text)
	if text != "" {
		fmt.print(text)
	}
}

read_file_or_stdin :: proc(path: string) -> (string, bool) {
	data: []byte
	err: os.Error
	if path == "" {
		data, err = os.read_entire_file_from_file(os.stdin, context.allocator)
	} else {
		data, err = os.read_entire_file_from_path(path, context.allocator)
	}
	if err != os.ERROR_NONE {
		return "", false
	}
	return string(data), true
}

Sql_Input_Kind :: enum {
	None,
	Command, // -c / --command
	File, // path ending in .sql
	Stdin,
}

// Sql_Command_Args is the pure parse result of `strix sql …` argv (no I/O).
Sql_Command_Args :: struct {
	db_path:           string, // raw path token, or DEFAULT_DB_PATH
	input:             Sql_Input_Kind,
	sql_or_file:       string, // -c text or .sql path; "" for stdin
	continue_on_error: bool,
	ok:                bool,
	err_msg:           string, // static message when !ok
}

// parse_sql_command_args resolves path / -c / file.sql / stdin intent without reading files.
parse_sql_command_args :: proc(args: []string) -> Sql_Command_Args {
	out := Sql_Command_Args{
		db_path = DEFAULT_DB_PATH,
		input   = .Stdin,
		ok      = true,
	}
	saw_sql := false
	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "-c" || arg == "--command" {
			if i + 1 >= len(args) {
				return Sql_Command_Args{ok = false, err_msg = "-c requires a SQL string"}
			}
			out.input = .Command
			out.sql_or_file = args[i + 1]
			saw_sql = true
			i += 2
			continue
		}
		if arg == "--continue-on-error" {
			out.continue_on_error = true
			i += 1
			continue
		}
		if strings.has_suffix(arg, ".sql") {
			out.input = .File
			out.sql_or_file = arg
			saw_sql = true
			i += 1
			continue
		}
		out.db_path = arg
		i += 1
	}
	if !saw_sql {
		out.input = .Stdin
		out.sql_or_file = ""
	}
	return out
}

// run_sql_command parses `sql` subcommand args.
// Forms:
//   sql [path] -c SQL
//   sql [path] file.sql
//   sql [path]          (stdin)
run_sql_command :: proc(args: []string) -> int {
	parsed := parse_sql_command_args(args)
	if !parsed.ok {
		fmt.eprintf("strix sql: %s\n", parsed.err_msg)
		return 1
	}

	sql_text: string
	sql_owned := false
	defer if sql_owned {
		delete(sql_text)
	}

	opts := exec.Exec_Options{
		continue_on_error = parsed.continue_on_error,
	}

	switch parsed.input {
	case .Command:
		sql_text = parsed.sql_or_file
	case .File:
		data, ok := read_file_or_stdin(parsed.sql_or_file)
		if !ok {
			fmt.eprintf("strix sql: failed to read %s\n", parsed.sql_or_file)
			return 1
		}
		sql_text = data
		sql_owned = true
		opts.source_path = parsed.sql_or_file
	case .Stdin:
		data, ok := read_file_or_stdin("")
		if !ok {
			fmt.eprintln("strix sql: failed to read stdin")
			return 1
		}
		sql_text = data
		sql_owned = true
	case .None:
		fmt.eprintln("strix sql: no SQL input")
		return 1
	}

	if strings.trim_space(sql_text) == "" {
		fmt.eprintln("strix sql: empty SQL input")
		return 1
	}

	return run_sql(parsed.db_path, sql_text, opts)
}

// run dispatches CLI commands from argv (without the program name).
// Returns a process exit code.
run :: proc(args: []string) -> int {
	if len(args) == 0 {
		print_usage()
		return 1
	}

	switch args[0] {
	case "init":
		if len(args) > 2 {
			fmt.eprintln("strix init: too many arguments")
			print_usage()
			return 1
		}
		path := DEFAULT_DB_PATH
		if len(args) == 2 {
			path = args[1]
		}
		return init_database(path)
	case "sql":
		return run_sql_command(args[1:])
	case "help", "-h", "--help":
		print_usage()
		return 0
	case:
		fmt.eprintf("strix: unknown command %q\n", args[0])
		print_usage()
		return 1
	}
}
