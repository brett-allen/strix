# C1 Symbol Coverage Inventory

**Phase:** C1 (REPL + SQL mode + `.help` / `.quit` / `.exit`)  
**Plan:** [`cli-shell.md`](cli-shell.md)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch — not “compiles” or bare smoke without classification.

**Coverage ratio:** **18 / 19 = 94.7%** (≥ 80% required)

Uncovered (1): `shell_run` — stdin/`bufio.Scanner` REPL loop; process-coupled. Line-injection surface (`shell_run_lines` / `shell_process_line`) covers the same control paths without a real TTY.

---

## Pure buffer / line helpers (`src/cli/shell.odin`) — 6 / 6

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `shell_line_kind` | yes | `test_shell_line_kind_empty_meta_sql` | Empty; Meta (leading `.`); Sql |
| `shell_sql_ready` | yes | `test_shell_sql_ready_basic`, string/comment tests | ready / not ready |
| `shell_sql_first_complete_end` | yes | basic + string/comment tests | index after `;`; `-1`; `;` inside `'…'` / `--` / `/* */` / `"…"` / `X'…'` |
| `shell_prompt` | yes | `test_shell_prompt_primary_vs_continuation` | `strix> ` vs `   ...> ` |
| `shell_state_init` | yes | prompt + meta dispatch + repl tests | builder init |
| `shell_state_destroy` | yes | same + fence refuse (`test_shell_open_refuses_after_flush_fence`) | close + free; **refuse** while flush fence (session kept) |

---

## REPL / session (`src/cli/shell.odin`) — 8 / 9

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `shell_open_path` | yes | missing-file; smoke; meta dispatch | missing → exit 1 + hint; happy open |
| `print_exec_result` | yes | smoke SELECT/INSERT; existing `run_sql` SELECT | Ok; Rows_Affected; Result_Set |
| `shell_exec_sql` | yes | smoke; continue-on-error; string `;` | happy; Exec_Error on stderr, stays |
| `shell_drain_ready_sql` | yes | multiline CREATE; smoke | multi-line until `;`; drain |
| `shell_process_line` | yes | empty/primary; multiline; meta; SQL error continue; `test_shell_meta_while_sql_buffer_rejected` | Empty; Meta; Sql; meta-while-buffer rejected + buffer preserved |
| `shell_finish_eof` | yes | `test_shell_incomplete_eof_exits_1`; quit paths | incomplete → 1; quit/clean → 0 |
| `shell_run_lines` | yes | all shell smoke / policy tests | open fail; quit; incomplete EOF |
| `shell_run` | **no** | — | stdin scanner loop (use `shell_run_lines` in tests) |
| `run_shell_command` | yes | `test_run_dispatches_shell_subcommand` | too many args; missing path |

---

## Meta-commands (`src/cli/meta.odin`) — 4 / 4

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `meta_strip_trailing_semi` | yes | `test_meta_parse_unknown_and_strip_semi` | trailing `;` stripped |
| `meta_parse` | yes | `test_meta_parse_help_quit_exit`, unknown | Help; Quit (`.quit`/`.exit`/`.q`); Unknown; optional `;` |
| `meta_help_text` | yes | `test_meta_help_text_lists_implemented_only` | lists `.help`/`.quit`/`.exit` only |
| `meta_dispatch` | yes | `test_meta_dispatch_help_and_quit`, unknown | Help; Quit→exit; Unknown stays |

---

## CLI wiring (`src/cli/cli.odin`) — counted under dispatch

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `run` `shell` arm | yes | `test_usage_mentions_shell` | `shell` verb → open path / exit 1 |
| `print_usage` shell line | yes | help + too-many-args prints usage including `shell` | text includes `shell [path]` |

Regression: existing `strix sql` / `init` CLI tests remain green under `./build.sh test`.

---

## C1 AC branch matrix

| AC | Asserted |
|----|----------|
| `strix shell [path]` opens; missing → exit 1 + `strix init` hint | yes |
| Prompt primary / continuation | yes (`shell_prompt`) |
| Multi-line SQL until `;` | yes |
| Exec via `src/exec`; print ok / N rows / result set; errors stderr; continue | yes |
| String/comment-aware `;` | yes (unit + INSERT `'a;b'`) |
| `.help` lists implemented only | yes |
| `.quit` / `.exit` → 0 | yes |
| Empty/whitespace ignored at primary | yes |
| Usage mentions `shell` | yes |
| Tests wired into `./build.sh test` | yes (`src/test/cli`) |
