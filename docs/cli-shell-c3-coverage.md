# C3 Symbol Coverage Inventory

**Phase:** C3 (`.headers` / `.mode` / `.read` + display-aware SELECT print)  
**Plan:** [`cli-shell.md`](cli-shell.md)  
**Prior:** [`cli-shell-c2-coverage.md`](cli-shell-c2-coverage.md)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch — not “compiles” or bare smoke without classification. Count is **unique procedure symbols** (one row per proc; multi-branch coverage listed in the Branches column).

**Coverage ratio:** **12 / 12 = 100%** (≥ 80% required)

---

## Display formatting (`src/cli/cli.odin`) — 4 / 4

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `format_result_set` | yes | `test_format_result_set_headers_off_omits_names`; list mode; batch defaults | Column+headers; Column+no headers; List; default opts (= batch) |
| `format_result_set_column` | yes | headers off / on via `format_result_set` | header row present/absent; aligned cells |
| `format_result_set_list` | yes | `test_format_result_set_list_mode_separators` | `\|` separators; headers on/off |
| `print_result_set` | yes | shell stdout headers/list tests | writes formatted text to stdout |

---

## Shell display wiring (`src/cli/shell.odin`) — 2 / 2

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `shell_display_opts` | yes | shell headers/list stdout; `.read` print path | reads `s.headers` / `s.mode` |
| `print_exec_result` | yes | shell SELECT paths; batch `run_sql` unchanged | Ok / Rows_Affected / Result_Set with opts |

---

## Meta-commands (`src/cli/meta.odin`) — 6 / 6

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `meta_parse` | yes | `test_meta_parse_headers_mode_read` | Headers; Mode; Read; trailing `;` |
| `meta_help_text` | yes | `test_meta_help_text_lists_c3_commands` | lists `.headers`/`.mode`/`.read` |
| `meta_dispatch` | yes | usage reject; shell stdout; `.read`; on/column arms | Headers; Mode; Read arms |
| `meta_run_headers` | yes | `test_shell_headers_off_omits_names_stdout`; `test_shell_headers_on_and_mode_column_dispatch`; usage reject | **`on`**; **`off`**; invalid → usage (state unchanged) |
| `meta_run_mode` | yes | `test_shell_mode_list_stdout`; `test_shell_headers_on_and_mode_column_dispatch`; usage reject | **`column`**; **`list`**; invalid → usage |
| `meta_run_read` | yes | round-trip; missing file; **dot-lines as SQL**; **SQL error continues** | SQL file exec; missing → error + REPL continues; file `.quit`/`.tables` → SQL error, **not** meta (`!s.quit`); bad INSERT → error, later SQL works |

---

## C3 AC branch matrix

| AC | Asserted |
|----|----------|
| `.headers on` / `.headers off` (invalid → usage) | yes (`on` + `off` dispatch state; usage reject) |
| `.mode column` / `.mode list` (invalid → usage) | yes (`column` + `list` dispatch state; list stdout; usage reject) |
| SELECT printing respects headers + mode | yes (format unit + shell stdout) |
| Batch `strix sql` unchanged defaults | yes (`test_batch_sql_select_still_headers_on` + existing E3 SELECT test) |
| `.read FILE` SQL-only on current session | yes (temp `.sql` round-trip; tables/rows durable) |
| File / SQL errors reported; REPL continues | yes (missing file; **SQL error in `.read`** + later INSERT durable; dispatch returns; no quit) |
| No dot-commands interpreted inside `.read` file | yes (`test_shell_read_dot_commands_are_sql_not_meta`: `.quit`/`.tables` in file → not meta; `!s.quit`; later SQL works) |
| Tests: headers off; list separators; `.read` round-trip | yes (`shell_display_test.odin`) |
| Coverage inventory ≥ 80% | yes (this file; arms/branches named above are test-backed) |
| `.help` lists C3 commands | yes (`meta_help_text`) |

Regression: C1/C2 shell tests and batch `strix sql` / `init` remain green under `./build.sh test`.
