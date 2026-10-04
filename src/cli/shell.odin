package cli

import "core:bufio"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:terminal"
import engine "../engine"
import exec "../exec"

// Forfeit messages for non-interactive abandon (no retry-COMMIT coaching).
SHELL_FORFEIT_STDIN_CLOSED :: "strix shell: flush recovery forfeited — stdin closed; in-memory dirty pages abandoned"
SHELL_FORFEIT_INPUT_ENDED :: "strix shell: flush recovery forfeited — input ended; in-memory dirty pages abandoned"

PROMPT_PRIMARY :: "strix> "
PROMPT_CONT :: "   ...> "

Shell_Line_Kind :: enum {
	Empty,
	Meta,
	Sql,
}

Shell_State :: struct {
	session:       exec.Exec_Session,
	db_path:       string, // owned resolved path
	sql_buf:       strings.Builder,
	quit:          bool,
	headers:       bool, // .headers on|off; default true
	mode:          Display_Mode, // .mode column|list; default .Column
	separator:     string, // owned; list-mode column sep
	nullvalue:     string, // owned; display substitute for NULL sentinel
	out_file:      ^os.File, // non-nil when .output FILE is active
	saved_stdout:  ^os.File, // previous os.stdout while out_file active
	bail:          bool, // shell --bail: stop + exit 1 after SQL error
	had_sql_error: bool,
}

// shell_line_kind classifies a physical input line (trim-aware).
shell_line_kind :: proc(line: string) -> Shell_Line_Kind {
	t := strings.trim_space(line)
	if t == "" {
		return .Empty
	}
	if strings.has_prefix(t, ".") {
		return .Meta
	}
	return .Sql
}

// shell_sql_ready reports whether buf contains at least one complete
// statement terminated by ';' outside strings/comments.
shell_sql_ready :: proc(buf: string) -> bool {
	return shell_sql_first_complete_end(buf) >= 0
}

// shell_sql_first_complete_end returns the exclusive byte index after the
// first statement-terminating ';' (string/comment-aware), or -1 if none.
shell_sql_first_complete_end :: proc(buf: string) -> int {
	i := 0
	n := len(buf)
	for i < n {
		c := buf[i]
		// Line comment --
		if c == '-' && i + 1 < n && buf[i + 1] == '-' {
			i += 2
			for i < n && buf[i] != '\n' {
				i += 1
			}
			continue
		}
		// Block comment /* */
		if c == '/' && i + 1 < n && buf[i + 1] == '*' {
			i += 2
			for i < n {
				if buf[i] == '*' && i + 1 < n && buf[i + 1] == '/' {
					i += 2
					break
				}
				i += 1
			}
			continue
		}
		// String literal '...'
		if c == '\'' {
			i += 1
			for i < n {
				if buf[i] == '\'' {
					if i + 1 < n && buf[i + 1] == '\'' {
						i += 2 // escaped ''
						continue
					}
					i += 1
					break
				}
				i += 1
			}
			continue
		}
		// Double-quoted identifier "..."
		if c == '"' {
			i += 1
			for i < n {
				if buf[i] == '"' {
					if i + 1 < n && buf[i + 1] == '"' {
						i += 2
						continue
					}
					i += 1
					break
				}
				i += 1
			}
			continue
		}
		// Backtick identifier `...`
		if c == '`' {
			i += 1
			for i < n {
				if buf[i] == '`' {
					if i + 1 < n && buf[i + 1] == '`' {
						i += 2
						continue
					}
					i += 1
					break
				}
				i += 1
			}
			continue
		}
		// Bracket identifier [...]
		if c == '[' {
			i += 1
			for i < n {
				if buf[i] == ']' {
					i += 1
					break
				}
				i += 1
			}
			continue
		}
		// Blob literal X'...' / x'...'
		if (c == 'x' || c == 'X') && i + 1 < n && buf[i + 1] == '\'' {
			i += 2
			for i < n {
				if buf[i] == '\'' {
					i += 1
					break
				}
				i += 1
			}
			continue
		}
		if c == ';' {
			return i + 1
		}
		i += 1
	}
	return -1
}

shell_prompt :: proc(s: ^Shell_State) -> string {
	if strings.builder_len(s.sql_buf) > 0 {
		return PROMPT_CONT
	}
	return PROMPT_PRIMARY
}

shell_state_init :: proc(s: ^Shell_State) {
	s^ = {}
	s.headers = true
	s.mode = .Column
	s.separator = strings.clone(LIST_SEPARATOR)
	s.nullvalue = strings.clone(NULL_CELL_SENTINEL)
	strings.builder_init(&s.sql_buf)
}

// shell_state_destroy releases shell resources after a successful session_close.
// While a flush fence is live, close is refused: session/path/buffers stay intact
// so the caller can retry COMMIT. Returns false when destroy is refused or close fails.
shell_state_destroy :: proc(s: ^Shell_State) -> bool {
	if exec.session_flush_fence(&s.session) {
		fmt.eprintln(
			"strix shell: close refused — flush recovery required; retry COMMIT on this session",
		)
		return false
	}
	shell_output_restore(s)
	close_err := exec.session_close(&s.session)
	if exec.has_error(close_err) {
		fmt.eprintf("strix shell: close refused: %s\n", close_err.message)
		exec.free_error(close_err)
		return false
	}
	exec.free_error(close_err)
	strings.builder_destroy(&s.sql_buf)
	if s.db_path != "" {
		delete(s.db_path)
		s.db_path = ""
	}
	if s.separator != "" {
		delete(s.separator)
		s.separator = ""
	}
	if s.nullvalue != "" {
		delete(s.nullvalue)
		s.nullvalue = ""
	}
	return true
}

// shell_output_set redirects shell stdout prints to path (create/truncate).
shell_output_set :: proc(s: ^Shell_State, path: string) -> bool {
	f, err := os.create(path)
	if err != nil {
		fmt.eprintf("strix shell: failed to open output %s\n", path)
		return false
	}
	if s.out_file != nil {
		os.stdout = s.saved_stdout
		_ = os.close(s.out_file)
		s.out_file = nil
	} else {
		s.saved_stdout = os.stdout
	}
	s.out_file = f
	os.stdout = f
	return true
}

// shell_output_restore returns stdout to the pre-.output destination.
shell_output_restore :: proc(s: ^Shell_State) {
	if s.out_file == nil {
		return
	}
	os.stdout = s.saved_stdout
	_ = os.close(s.out_file)
	s.out_file = nil
	s.saved_stdout = nil
}

// shell_open_path opens path into s (startup). Returns process exit code (0 ok).
shell_open_path :: proc(s: ^Shell_State, path: string) -> int {
	resolved := ensure_strix_path(path)
	if !os.exists(resolved) {
		fmt.eprintf(
			"strix shell: database %s does not exist\nHint: create one with `strix init`\n",
			resolved,
		)
		delete(resolved)
		return 1
	}

	session, err := exec.session_open(resolved)
	if exec.has_error(err) {
		fmt.eprintf("strix shell: open %s: %s\n", resolved, err.message)
		fmt.eprintln("Hint: create one with `strix init`")
		exec.free_error(err)
		delete(resolved)
		return 1
	}
	exec.free_error(err)

	s.session = session
	s.db_path = resolved
	return 0
}

// shell_switch_path opens path, replacing the current session on success.
// On failure, prints to stderr and keeps the previous session intact.
// Refuses to switch while an explicit transaction is open or the engine is still
// in_txn (e.g. flush-fence recovery) — no silent rollback / discarded Flush_Failed.
// On success: resets sql_buf, restores .output to stdout, clears had_sql_error/quit
// (process-level --bail flag is kept).
shell_switch_path :: proc(s: ^Shell_State, path: string) -> bool {
	eng := exec.session_engine(&s.session)
	if s.session.explicit_txn || (eng != nil && eng.in_txn) {
		fmt.eprintln(
			"strix shell: cannot .open while a transaction is open; COMMIT or ROLLBACK first",
		)
		return false
	}

	resolved := ensure_strix_path(path)
	if !os.exists(resolved) {
		fmt.eprintf("strix shell: database %s does not exist\n", resolved)
		delete(resolved)
		return false
	}

	session, err := exec.session_open(resolved)
	if exec.has_error(err) {
		fmt.eprintf("strix shell: open %s: %s\n", resolved, err.message)
		exec.free_error(err)
		delete(resolved)
		return false
	}
	exec.free_error(err)

	// Close the current session before adopting the new one. If close is refused
	// (e.g. flush fence), keep the old session and close the newly opened one.
	close_err := exec.session_close(&s.session)
	if exec.has_error(close_err) {
		fmt.eprintf("strix shell: cannot .open: %s\n", close_err.message)
		exec.free_error(close_err)
		_ = exec.session_close(&session)
		delete(resolved)
		return false
	}
	exec.free_error(close_err)

	if s.db_path != "" {
		delete(s.db_path)
	}
	s.session = session
	s.db_path = resolved

	strings.builder_reset(&s.sql_buf)
	shell_output_restore(s)
	s.had_sql_error = false
	s.quit = false
	return true
}

shell_display_opts :: proc(s: ^Shell_State) -> Display_Opts {
	return Display_Opts {
		headers   = s.headers,
		mode      = s.mode,
		separator = s.separator,
		nullvalue = s.nullvalue,
	}
}

print_exec_result :: proc(result: exec.Exec_Result, opts := DEFAULT_DISPLAY_OPTS) {
	switch result.kind {
	case .Ok:
		fmt.println("ok")
	case .Rows_Affected:
		fmt.printf("%d rows\n", result.rows_affected)
	case .Result_Set:
		print_result_set(result, opts)
	}
}

shell_note_sql_error :: proc(s: ^Shell_State) {
	s.had_sql_error = true
	// --bail must not process-exit over a live flush fence (same spirit as .quit refuse).
	// Stay in the REPL so the user can retry COMMIT; siblings still stop via drain check.
	if s.bail && !exec.session_flush_fence(&s.session) {
		s.quit = true
	}
}

// shell_should_stop_sql reports whether drain/REPL should stop further SQL after an error.
// With --bail, stop siblings even while fenced (no quit/exit until fence clears).
shell_should_stop_sql :: proc(s: ^Shell_State) -> bool {
	return s.quit || (s.bail && s.had_sql_error)
}

shell_exec_sql :: proc(s: ^Shell_State, sql_text: string) {
	trimmed := strings.trim_space(sql_text)
	if trimmed == "" || trimmed == ";" {
		return
	}
	// Drop trailing ';' for exec_statement; keep text as-is for script-like chunks.
	result, err := exec.exec_statement(&s.session, sql_text)
	if exec.has_error(err) {
		formatted := exec.format_error(err)
		defer delete(formatted)
		fmt.eprintf("%s\n", formatted)
		exec.free_error(err)
		exec.free_result(result)
		shell_note_sql_error(s)
		return
	}
	defer exec.free_result(result)
	print_exec_result(result, shell_display_opts(s))
}

// shell_drain_ready_sql executes all complete statements in the buffer.
// Always consumes a statement after attempting it. On --bail stop, discards any
// remaining buffer so a later recovery COMMIT is not prepended to leftover siblings.
shell_drain_ready_sql :: proc(s: ^Shell_State) {
	for {
		buf := strings.to_string(s.sql_buf)
		end := shell_sql_first_complete_end(buf)
		if end < 0 {
			return
		}
		stmt := buf[:end]
		body := strings.trim_space(stmt[:len(stmt) - 1]) // without trailing ';'
		if body != "" {
			shell_exec_sql(s, stmt)
		}
		if shell_should_stop_sql(s) {
			// Drop failed stmt + unexecuted siblings; stay ready for next REPL line.
			strings.builder_reset(&s.sql_buf)
			return
		}
		rest := buf[end:]
		if len(rest) == 0 {
			strings.builder_reset(&s.sql_buf)
			return
		}
		rest_owned := strings.clone(rest)
		strings.builder_reset(&s.sql_buf)
		strings.write_string(&s.sql_buf, rest_owned)
		delete(rest_owned)
	}
}

// shell_process_line handles one physical line. Pure control + I/O for exec/print.
// Returns true when the REPL should stop (quit).
shell_process_line :: proc(s: ^Shell_State, line: string) -> (quit: bool) {
	kind := shell_line_kind(line)
	switch kind {
	case .Empty:
		if strings.builder_len(s.sql_buf) == 0 {
			return false
		}
		// Preserve blank line inside multi-line SQL.
		strings.write_byte(&s.sql_buf, '\n')
		return false
	case .Meta:
		if strings.builder_len(s.sql_buf) > 0 {
			fmt.eprintln("strix shell: finish or clear the SQL buffer before a .command")
			return false
		}
		cmd := meta_parse(line)
		return meta_dispatch(s, cmd)
	case .Sql:
		if strings.builder_len(s.sql_buf) > 0 {
			strings.write_byte(&s.sql_buf, '\n')
		}
		strings.write_string(&s.sql_buf, line)
		shell_drain_ready_sql(s)
		return false
	}
	return false
}

// shell_refuse_exit_while_fenced prints the .quit-style refuse message when a flush
// fence is live. Returns true when exit must be refused (caller stays in REPL).
shell_refuse_exit_while_fenced :: proc(s: ^Shell_State) -> bool {
	if !exec.session_flush_fence(&s.session) {
		return false
	}
	fmt.eprintln(
		"strix shell: cannot exit while flush recovery required; retry COMMIT first",
	)
	return true
}

// shell_finish_eof applies EOF/quit exit policy when exit is allowed:
// incomplete SQL → 1; with --bail, any prior SQL error → 1; else 0.
// While fenced, returns 1 without destroying — callers should prefer
// shell_refuse_exit_while_fenced and stay in the REPL (like .quit).
shell_finish_eof :: proc(s: ^Shell_State) -> int {
	if exec.session_flush_fence(&s.session) {
		return 1
	}
	if !s.quit && strings.builder_len(s.sql_buf) > 0 {
		fmt.eprintln("strix shell: incomplete SQL")
		return 1
	}
	if s.bail && s.had_sql_error {
		return 1
	}
	return 0
}

shell_repl_stop_code :: proc(s: ^Shell_State) -> int {
	return shell_finish_eof(s)
}

shell_destroy_exit :: proc(s: ^Shell_State, code: int) -> int {
	if !shell_state_destroy(s) {
		return 1
	}
	return code
}

// shell_inject_flush_fail_for_tests sets the pager flush-fail hook after open.
shell_inject_flush_fail_for_tests :: proc(s: ^Shell_State, n: int) {
	if n <= 0 {
		return
	}
	if eng := exec.session_engine(&s.session); eng != nil {
		if pager := engine.engine_pager_unsafe_for_tests(eng); pager != nil {
			pager.flush_fail_after_data_writes = n
		}
	}
}

// shell_run_lines drives the REPL from injected lines (no TTY).
// While fenced: .quit/--bail must not destroy/exit (stay + retry COMMIT coaching).
// EOF of the line list while fenced forfeits recovery (exit 1, forfeit-only stderr).
// flush_fail_after_data_writes is a test hook (0 = off).
shell_run_lines :: proc(
	path: string,
	lines: []string,
	show_banner := false,
	bail := false,
	flush_fail_after_data_writes := 0,
) -> int {
	s: Shell_State
	shell_state_init(&s)
	s.bail = bail

	if code := shell_open_path(&s, path); code != 0 {
		return shell_destroy_exit(&s, code)
	}
	shell_inject_flush_fail_for_tests(&s, flush_fail_after_data_writes)
	if show_banner {
		fmt.printf("Connected to %s\n", s.db_path)
	}

	for line in lines {
		if shell_process_line(&s, line) || s.quit {
			if shell_refuse_exit_while_fenced(&s) {
				s.quit = false
				continue
			}
			return shell_destroy_exit(&s, shell_repl_stop_code(&s))
		}
	}
	if exec.session_flush_fence(&s.session) {
		// Non-TTY input ended while fenced: forfeit-only (no refuse/retry-COMMIT).
		fmt.eprintln(SHELL_FORFEIT_INPUT_ENDED)
		return 1
	}
	return shell_destroy_exit(&s, shell_finish_eof(&s))
}

// shell_run opens path and runs an interactive stdin REPL.
// EOF while fenced: refuse like .quit and keep reading when stdin is a TTY;
// non-TTY EOF while fenced forfeits recovery (honest process exit 1, forfeit-only).
// flush_fail_after_data_writes is a test hook (0 = off).
shell_run :: proc(path: string, bail := false, flush_fail_after_data_writes := 0) -> int {
	s: Shell_State
	shell_state_init(&s)
	s.bail = bail

	if code := shell_open_path(&s, path); code != 0 {
		return shell_destroy_exit(&s, code)
	}
	shell_inject_flush_fail_for_tests(&s, flush_fail_after_data_writes)
	fmt.printf("Connected to %s\n", s.db_path)

	scanner: bufio.Scanner
	bufio.scanner_init(&scanner, os.to_reader(os.stdin))
	defer bufio.scanner_destroy(&scanner)
	stdin_tty := terminal.is_terminal(os.stdin)

	for {
		fmt.print(shell_prompt(&s))
		if !bufio.scan(&scanner) {
			if exec.session_flush_fence(&s.session) {
				if stdin_tty {
					// Ctrl-D refuse: print retry coaching; re-arm so user can COMMIT.
					_ = shell_refuse_exit_while_fenced(&s)
					bufio.scanner_destroy(&scanner)
					bufio.scanner_init(&scanner, os.to_reader(os.stdin))
					continue
				}
				// Piped stdin closed while fenced: forfeit-only (no refuse/retry-COMMIT).
				fmt.eprintln(SHELL_FORFEIT_STDIN_CLOSED)
				return 1
			}
			break
		}
		line := bufio.scanner_text(&scanner)
		if shell_process_line(&s, line) || s.quit {
			if shell_refuse_exit_while_fenced(&s) {
				s.quit = false
				continue
			}
			return shell_destroy_exit(&s, shell_repl_stop_code(&s))
		}
	}
	return shell_destroy_exit(&s, shell_finish_eof(&s))
}

Shell_Command_Args :: struct {
	path:    string,
	bail:    bool,
	ok:      bool,
	err_msg: string,
}

// parse_shell_command_args resolves `shell [path] [--bail]` (order flexible).
parse_shell_command_args :: proc(args: []string) -> Shell_Command_Args {
	out := Shell_Command_Args {
		path = DEFAULT_DB_PATH,
		ok   = true,
	}
	path_set := false
	for arg in args {
		if arg == "--bail" {
			out.bail = true
			continue
		}
		if strings.has_prefix(arg, "-") {
			return Shell_Command_Args{ok = false, err_msg = "unknown option"}
		}
		if path_set {
			return Shell_Command_Args{ok = false, err_msg = "too many arguments"}
		}
		out.path = arg
		path_set = true
	}
	return out
}

// run_shell_command parses `shell` subcommand args: shell [path] [--bail]
run_shell_command :: proc(args: []string) -> int {
	parsed := parse_shell_command_args(args)
	if !parsed.ok {
		fmt.eprintf("strix shell: %s\n", parsed.err_msg)
		print_usage()
		return 1
	}
	return shell_run(parsed.path, parsed.bail)
}
