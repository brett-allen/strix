# C5 Symbol Coverage Inventory

**Phase:** C5 (stretch UX: bare TTY entry, `.output`, `.separator` / `.nullvalue`, `shell --bail`)  
**Plan:** [`cli-shell.md`](cli-shell.md)  
**Prior:** [`cli-shell-c4-coverage.md`](cli-shell-c4-coverage.md)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch — not “compiles” or bare smoke without classification. Count is **unique procedure symbols** (one row per proc; multi-branch coverage listed in the Branches column).

**Coverage ratio:** **16 / 16 = 100%** (≥ 80% required)

**Deferred (not in inventory):** Ctrl-C buffer clear (no signal/readline dependency added).

---

## Bare entry + shell argv (`src/cli/cli.odin`, `shell.odin`) — 3 / 3

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `run_bare` | yes | `test_run_bare_non_tty_usage_exits_1`; `test_run_bare_tty_enters_shell_open_path` | non-TTY → usage + exit 1; TTY missing DB → 1; TTY existing DB → real `run_bare`→`shell_run` via stdin pipe + `.quit` → 0 |
| `parse_shell_command_args` | yes | `test_parse_shell_command_args_bail` | default path; `--bail`; path+bail either order; too many args; unknown option |
| `run_shell_command` | yes | parse + existing dispatch; bail via `shell_run_lines` / `shell_run` | wires parsed bail into `shell_run` |

---

## Display stretch (`src/cli/cli.odin`) — 3 / 3

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `display_cell` | yes | nullvalue format + shell stdout | NULL sentinel → nullvalue; other cells unchanged |
| `format_result_set` (sep/null) | yes | `test_format_result_set_custom_separator_and_nullvalue` | list `,` sep; `?` nullvalue; normalize empty opts |
| `format_result_set_list` / `_column` | yes | separator shell; nullvalue shell; format unit | custom sep; nullvalue widths/cells |

---

## Output redirect + bail (`src/cli/shell.odin`) — 7 / 7

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `shell_output_set` | yes | `test_shell_output_redirect_and_restore` | create file; stdout swapped; SELECT lands in file |
| `shell_output_restore` | yes | same + destroy path; `.open` hygiene | `.output stdout`; second SELECT on prior stdout |
| `shell_note_sql_error` | yes | bail tests + fence | sets `had_sql_error`; with bail sets `quit` **unless** flush fence live |
| `shell_drain_ready_sql` (bail stop) | yes | `test_shell_bail_stops_sibling_sql_on_same_line` | after `shell_exec_sql`, stop when `s.quit`; sibling on same line not run |
| `shell_finish_eof` / `shell_repl_stop_code` | yes | bail exit 1; clean EOF still 0 | bail+error → 1; incomplete still 1 |
| `shell_run_lines` (bail) | yes | `test_shell_bail_exits_1_on_sql_error`; same-line sibling | stops after SQL error; later SQL not run (next line + same line); exit 1 |
| `shell_run` (stdin + bail) | yes | `test_shell_run_stdin_quit_and_bail` | real stdin scanner loop: `.quit` → 0; `--bail` SQL error → 1 and later CREATE not durable |

---

## Meta C5 commands (`src/cli/meta.odin`) — 3 / 3

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `meta_parse` (Output/Separator/Nullvalue) | yes | `test_meta_parse_output_separator_nullvalue` | `.output`; `.separator`; `.nullvalue`; trailing `;` |
| `meta_run_output` / `_separator` / `_nullvalue` | yes | redirect; list sep; nullvalue; print-current | FILE; stdout; set sep; set null; no-arg print |
| `meta_help_text` / `meta_dispatch` | yes | `test_meta_help_text_lists_c5_commands` | lists new commands; dispatch arms exercised via shell |

---

## C5 AC / stretch matrix

| Item | Status | Asserted |
|------|--------|----------|
| Bare `strix` TTY → shell on default path | landed | `run_bare(true, …)` missing→1; existing DB via stdin pipe→`shell_run`→0 |
| Non-TTY bare keeps usage/exit 1 | landed | `run_bare(false)` → 1 |
| `.output FILE` / `.output stdout` | landed | file contains SELECT; restore to stdout |
| `.separator` for list mode | landed | `id,name` / `1,a` |
| `.nullvalue` | landed | `1|-` not `1\|NULL` (CLI sentinel rewrite) |
| `shell --bail` | landed | parse; `shell_run_lines` + real `shell_run` stdin bail → exit 1; stops further SQL; **refuses process-exit while flush fence** (`test_shell_bail_refuses_exit_while_fenced`) |
| Ctrl-C clear buffer | **deferred** | needs signal handler / readline; not done |
| Coverage inventory ≥ 80% | yes | this file 100% |

Regression: C1–C4 shell tests and batch `strix sql` / `init` remain green under `./build.sh test`.
