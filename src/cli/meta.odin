package cli

import "core:fmt"
import "core:os"
import "core:strings"
import exec "../exec"

Meta_Kind :: enum {
	Help,
	Quit,
	Tables,
	Schema,
	Headers,
	Mode,
	Read,
	Open,
	Output,
	Separator,
	Nullvalue,
	Unknown,
}

// Meta_Cmd is the pure parse result of a dot-command line (no I/O).
Meta_Cmd :: struct {
	kind:    Meta_Kind,
	name:    string, // command token without leading '.'
	args:    string, // remainder after command (trimmed)
	ok:      bool,
	err_msg: string, // static when !ok
}

// meta_strip_trailing_semi removes one optional trailing ';' (after trim).
meta_strip_trailing_semi :: proc(line: string) -> string {
	t := strings.trim_space(line)
	if strings.has_suffix(t, ";") {
		return strings.trim_space(t[:len(t) - 1])
	}
	return t
}

// meta_parse_path_arg extracts a single file path from meta-command args.
// SQLite-ish: the remainder of the line is the path (spaces allowed), or a
// single- or double-quoted path. Trailing junk after a quoted path is rejected.
// The returned path is a slice into `args` (not allocated).
meta_parse_path_arg :: proc(args: string) -> (path: string, ok: bool) {
	t := strings.trim_space(args)
	if t == "" {
		return "", false
	}
	if t[0] == '"' || t[0] == '\'' {
		quote := t[0]
		end := -1
		for i := 1; i < len(t); i += 1 {
			if t[i] == quote {
				end = i
				break
			}
		}
		if end < 0 {
			return "", false
		}
		if strings.trim_space(t[end + 1:]) != "" {
			return "", false
		}
		return t[1:end], true
	}
	return t, true
}

// meta_parse parses a meta-command line (leading '.'). Pure; no I/O.
meta_parse :: proc(line: string) -> Meta_Cmd {
	t := meta_strip_trailing_semi(line)
	if t == "" || !strings.has_prefix(t, ".") {
		return Meta_Cmd{ok = false, err_msg = "not a meta-command"}
	}
	body := t[1:]
	if body == "" {
		return Meta_Cmd{ok = false, err_msg = "empty command"}
	}

	name_end := 0
	for name_end < len(body) {
		c := body[name_end]
		if c == ' ' || c == '\t' {
			break
		}
		name_end += 1
	}
	name := body[:name_end]
	args := strings.trim_space(body[name_end:])

	switch name {
	case "help", "h", "?":
		return Meta_Cmd{kind = .Help, name = name, args = args, ok = true}
	case "quit", "exit", "q":
		return Meta_Cmd{kind = .Quit, name = name, args = args, ok = true}
	case "tables":
		return Meta_Cmd{kind = .Tables, name = name, args = args, ok = true}
	case "schema":
		return Meta_Cmd{kind = .Schema, name = name, args = args, ok = true}
	case "headers":
		return Meta_Cmd{kind = .Headers, name = name, args = args, ok = true}
	case "mode":
		return Meta_Cmd{kind = .Mode, name = name, args = args, ok = true}
	case "read":
		return Meta_Cmd{kind = .Read, name = name, args = args, ok = true}
	case "open":
		return Meta_Cmd{kind = .Open, name = name, args = args, ok = true}
	case "output":
		return Meta_Cmd{kind = .Output, name = name, args = args, ok = true}
	case "separator":
		return Meta_Cmd{kind = .Separator, name = name, args = args, ok = true}
	case "nullvalue":
		return Meta_Cmd{kind = .Nullvalue, name = name, args = args, ok = true}
	case:
		return Meta_Cmd{kind = .Unknown, name = name, args = args, ok = true}
	}
}

// meta_help_text returns help for all shipped shell commands.
meta_help_text :: proc() -> string {
	return "Commands:\n" +
		"  .help              Show this help\n" +
		"  .quit / .exit      Close the session and exit\n" +
		"  .tables            List table names\n" +
		"  .schema [table]    Show CREATE schema (all tables, or one)\n" +
		"  .headers on|off    Toggle column headers for SELECT\n" +
		"  .mode column|list  Set SELECT output mode\n" +
		"  .separator STR     Set list-mode column separator (default |)\n" +
		"  .nullvalue STR     Set display string for NULL cells (default NULL)\n" +
		"  .output FILE       Redirect stdout prints to FILE (quoted path OK)\n" +
		"  .output stdout     Restore stdout\n" +
		"  .read FILE         Execute SQL from FILE (SQL only; no .commands; quoted path OK)\n" +
		"  .open [path]       Show current DB path, or switch to path (quoted path OK)\n"
}

// meta_dispatch runs a parsed meta-command against shell state.
// Returns true when the REPL should exit (quit/exit).
meta_dispatch :: proc(s: ^Shell_State, cmd: Meta_Cmd) -> (quit: bool) {
	if !cmd.ok {
		fmt.eprintf("strix shell: %s\n", cmd.err_msg)
		return false
	}
	switch cmd.kind {
	case .Help:
		fmt.print(meta_help_text())
		return false
	case .Quit:
		if exec.session_flush_fence(&s.session) {
			fmt.eprintln(
				"strix shell: cannot .quit while flush recovery required; retry COMMIT first",
			)
			return false
		}
		s.quit = true
		return true
	case .Tables:
		meta_run_tables(s, cmd)
		return false
	case .Schema:
		meta_run_schema(s, cmd)
		return false
	case .Headers:
		meta_run_headers(s, cmd)
		return false
	case .Mode:
		meta_run_mode(s, cmd)
		return false
	case .Read:
		meta_run_read(s, cmd)
		return false
	case .Open:
		meta_run_open(s, cmd)
		return false
	case .Output:
		meta_run_output(s, cmd)
		return false
	case .Separator:
		meta_run_separator(s, cmd)
		return false
	case .Nullvalue:
		meta_run_nullvalue(s, cmd)
		return false
	case .Unknown:
		fmt.eprintf("unknown command: .%s\n", cmd.name)
		fmt.eprintln("type .help for available commands")
		return false
	}
	return false
}

meta_run_tables :: proc(s: ^Shell_State, cmd: Meta_Cmd) {
	if cmd.args != "" {
		fmt.eprintln("usage: .tables")
		return
	}
	names, err := exec.list_tables(&s.session)
	if exec.has_error(err) {
		formatted := exec.format_error(err)
		defer delete(formatted)
		fmt.eprintf("%s\n", formatted)
		exec.free_error(err)
		return
	}
	defer exec.free_table_names(names)
	for name in names {
		fmt.println(name)
	}
}

meta_run_schema :: proc(s: ^Shell_State, cmd: Meta_Cmd) {
	// Single optional table name; reject extra tokens.
	table := ""
	if cmd.args != "" {
		parts := strings.fields(cmd.args)
		defer delete(parts)
		if len(parts) != 1 {
			fmt.eprintln("usage: .schema [table]")
			return
		}
		table = parts[0]
	}
	text, err := exec.schema_sql(&s.session, table)
	if exec.has_error(err) {
		formatted := exec.format_error(err)
		defer delete(formatted)
		fmt.eprintf("%s\n", formatted)
		exec.free_error(err)
		return
	}
	defer delete(text)
	fmt.print(text)
}

meta_run_headers :: proc(s: ^Shell_State, cmd: Meta_Cmd) {
	parts := strings.fields(cmd.args)
	defer delete(parts)
	if len(parts) != 1 {
		fmt.eprintln("usage: .headers on|off")
		return
	}
	switch parts[0] {
	case "on":
		s.headers = true
	case "off":
		s.headers = false
	case:
		fmt.eprintln("usage: .headers on|off")
	}
}

meta_run_mode :: proc(s: ^Shell_State, cmd: Meta_Cmd) {
	parts := strings.fields(cmd.args)
	defer delete(parts)
	if len(parts) != 1 {
		fmt.eprintln("usage: .mode column|list")
		return
	}
	switch parts[0] {
	case "column":
		s.mode = .Column
	case "list":
		s.mode = .List
	case:
		fmt.eprintln("usage: .mode column|list")
	}
}

meta_run_open :: proc(s: ^Shell_State, cmd: Meta_Cmd) {
	if cmd.args == "" {
		fmt.println(s.db_path)
		return
	}
	path, ok := meta_parse_path_arg(cmd.args)
	if !ok {
		fmt.eprintln("usage: .open [path]")
		return
	}
	_ = shell_switch_path(s, path)
}

meta_run_output :: proc(s: ^Shell_State, cmd: Meta_Cmd) {
	path, ok := meta_parse_path_arg(cmd.args)
	if !ok {
		fmt.eprintln("usage: .output FILE|stdout")
		return
	}
	if path == "stdout" {
		shell_output_restore(s)
		return
	}
	_ = shell_output_set(s, path)
}

meta_run_separator :: proc(s: ^Shell_State, cmd: Meta_Cmd) {
	// Allow empty separator via `.separator ''` is not supported; one token required.
	// No args → print current separator (sqlite-like).
	if cmd.args == "" {
		fmt.println(s.separator)
		return
	}
	parts := strings.fields(cmd.args)
	defer delete(parts)
	if len(parts) != 1 {
		fmt.eprintln("usage: .separator STR")
		return
	}
	delete(s.separator)
	s.separator = strings.clone(parts[0])
}

meta_run_nullvalue :: proc(s: ^Shell_State, cmd: Meta_Cmd) {
	if cmd.args == "" {
		fmt.println(s.nullvalue)
		return
	}
	parts := strings.fields(cmd.args)
	defer delete(parts)
	if len(parts) != 1 {
		fmt.eprintln("usage: .nullvalue STR")
		return
	}
	delete(s.nullvalue)
	s.nullvalue = strings.clone(parts[0])
}

// meta_run_read executes a SQL-only script file on the current session.
// Dot-commands inside the file are not interpreted (passed to exec as SQL).
meta_run_read :: proc(s: ^Shell_State, cmd: Meta_Cmd) {
	path, ok := meta_parse_path_arg(cmd.args)
	if !ok {
		fmt.eprintln("usage: .read FILE")
		return
	}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != os.ERROR_NONE {
		fmt.eprintf("strix shell: failed to read %s\n", path)
		return
	}
	defer delete(data)

	result, eerr := exec.exec_script(&s.session, string(data), exec.Exec_Options{source_path = path})
	if exec.has_error(eerr) {
		formatted := exec.format_error(eerr, path)
		defer delete(formatted)
		fmt.eprintf("%s\n", formatted)
		exec.free_error(eerr)
		exec.free_result(result)
		shell_note_sql_error(s)
		return
	}
	defer exec.free_result(result)
	print_exec_result(result, shell_display_opts(s))
}
