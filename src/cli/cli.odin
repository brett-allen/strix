package cli

import "core:fmt"
import "core:os"
import "core:strings"
import "core:terminal"
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
		"  shell [path] [--bail]    Interactive SQL shell (default: %s)\n" +
		"  help                     Show this help\n" +
		"\n" +
		"With no command, if stdin is a TTY, enters the shell on %s.\n",
		DEFAULT_DB_PATH,
		DEFAULT_DB_PATH,
		DEFAULT_DB_PATH,
	)
}

// run_sql opens path and executes sql_text. Returns process exit code.
// Close refusal (flush fence) always yields exit 1 — never `_ = session_close`.
// Batch process exit forfeits in-memory recovery (no post-exit COMMIT coaching).
run_sql :: proc(path: string, sql_text: string, opts := exec.Exec_Options{}) -> int {
	resolved := ensure_strix_path(path)
	defer delete(resolved)

	session, err := exec.session_open(resolved)
	if exec.has_error(err) {
		fmt.eprintf("strix sql: open %s: %s\n", resolved, err.message)
		exec.free_error(err)
		return 1
	}

	// Test hook: inject pager flush failure before running the script.
	if opts.flush_fail_after_data_writes > 0 {
		if eng := exec.session_engine(&session); eng != nil {
			if pager := engine.engine_pager_unsafe_for_tests(eng); pager != nil {
				pager.flush_fail_after_data_writes = opts.flush_fail_after_data_writes
			}
		}
	}

	exit_code := 0
	result, eerr := exec.exec_script(&session, sql_text, opts)
	fenced := exec.session_flush_fence(&session)
	if exec.has_error(eerr) {
		// While fenced, skip in-process "retry COMMIT" coaching — process exit
		// cannot keep a recovery session; close path prints forfeit-only.
		if !fenced {
			loc := opts.source_path
			formatted := exec.format_error(eerr, loc)
			defer delete(formatted)
			fmt.eprintf("strix sql: %s\n", formatted)
		}
		exec.free_error(eerr)
		exec.free_result(result)
		exit_code = 1
	} else {
		print_exec_result(result)
		exec.free_result(result)
	}

	close_err := exec.session_close(&session)
	if exec.has_error(close_err) {
		// Forfeit-only: never echo engine "retry COMMIT (close refused)".
		fmt.eprintln(
			"strix sql: flush recovery forfeited — process exit abandons in-memory dirty pages; database may be torn after partial flush",
		)
		exec.free_error(close_err)
		return 1
	}
	exec.free_error(close_err)
	return exit_code
}

Display_Mode :: enum {
	Column,
	List,
}

// Display_Opts controls SELECT result printing (shell toggles; batch uses defaults).
Display_Opts :: struct {
	headers:   bool,
	mode:      Display_Mode,
	separator: string, // list-mode column separator; default "|"
	nullvalue: string, // display for exec NULL sentinel; default "NULL"
}

DEFAULT_DISPLAY_OPTS :: Display_Opts {
	headers   = true,
	mode      = .Column,
	separator = "|",
	nullvalue = "NULL",
}

// Matches exec.format_value_cell for .Null values (CLI cannot distinguish TEXT 'NULL').
NULL_CELL_SENTINEL :: "NULL"

LIST_SEPARATOR :: "|"

display_cell :: proc(cell: string, nullvalue: string) -> string {
	if cell == NULL_CELL_SENTINEL {
		return nullvalue
	}
	return cell
}

// format_result_set builds a text table. Caller deletes the string.
// Default opts match batch `strix sql` (headers on, column mode).
format_result_set :: proc(
	result: exec.Exec_Result,
	opts := DEFAULT_DISPLAY_OPTS,
	allocator := context.allocator,
) -> string {
	ncols := len(result.column_names)
	if ncols == 0 {
		return ""
	}
	// Normalize zero-value partial literals (separator/nullvalue omitted).
	nopts := opts
	if nopts.separator == "" {
		nopts.separator = LIST_SEPARATOR
	}
	if nopts.nullvalue == "" {
		nopts.nullvalue = NULL_CELL_SENTINEL
	}
	switch nopts.mode {
	case .List:
		return format_result_set_list(result, nopts, allocator)
	case .Column:
		return format_result_set_column(result, nopts, allocator)
	}
	return ""
}

format_result_set_column :: proc(
	result: exec.Exec_Result,
	opts: Display_Opts,
	allocator := context.allocator,
) -> string {
	ncols := len(result.column_names)
	widths := make([]int, ncols, allocator)
	defer delete(widths, allocator)
	for name, i in result.column_names {
		if opts.headers {
			widths[i] = len(name)
		}
	}
	for row in result.rows {
		for i in 0 ..< min(ncols, len(row)) {
			cell := display_cell(row[i], opts.nullvalue)
			if len(cell) > widths[i] {
				widths[i] = len(cell)
			}
		}
	}
	b: strings.Builder
	strings.builder_init(&b, allocator)
	if opts.headers {
		for i in 0 ..< ncols {
			if i > 0 {
				strings.write_string(&b, "  ")
			}
			fmt.sbprintf(&b, "%-*s", widths[i], result.column_names[i])
		}
		strings.write_byte(&b, '\n')
	}
	for row in result.rows {
		for i in 0 ..< ncols {
			if i > 0 {
				strings.write_string(&b, "  ")
			}
			cell := ""
			if i < len(row) {
				cell = display_cell(row[i], opts.nullvalue)
			}
			fmt.sbprintf(&b, "%-*s", widths[i], cell)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

format_result_set_list :: proc(
	result: exec.Exec_Result,
	opts: Display_Opts,
	allocator := context.allocator,
) -> string {
	ncols := len(result.column_names)
	sep := opts.separator if opts.separator != "" else LIST_SEPARATOR
	b: strings.Builder
	strings.builder_init(&b, allocator)
	if opts.headers {
		for i in 0 ..< ncols {
			if i > 0 {
				strings.write_string(&b, sep)
			}
			strings.write_string(&b, result.column_names[i])
		}
		strings.write_byte(&b, '\n')
	}
	for row in result.rows {
		for i in 0 ..< ncols {
			if i > 0 {
				strings.write_string(&b, sep)
			}
			cell := ""
			if i < len(row) {
				cell = display_cell(row[i], opts.nullvalue)
			}
			strings.write_string(&b, cell)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// print_result_set writes a result table to stdout (default = batch aligned+headers).
print_result_set :: proc(result: exec.Exec_Result, opts := DEFAULT_DISPLAY_OPTS) {
	text := format_result_set(result, opts)
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

// run_bare handles `strix` with no args: TTY stdin → shell; else usage + exit 1.
run_bare :: proc(stdin_is_tty: bool, path := DEFAULT_DB_PATH) -> int {
	if stdin_is_tty {
		return shell_run(path)
	}
	print_usage()
	return 1
}

// run dispatches CLI commands from argv (without the program name).
// Returns a process exit code.
run :: proc(args: []string) -> int {
	if len(args) == 0 {
		return run_bare(terminal.is_terminal(os.stdin))
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
	case "shell":
		return run_shell_command(args[1:])
	case "help", "-h", "--help":
		print_usage()
		return 0
	case:
		fmt.eprintf("strix: unknown command %q\n", args[0])
		print_usage()
		return 1
	}
}
