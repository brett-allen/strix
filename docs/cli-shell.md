# Plan: Interactive CLI Shell

SQLite-style interactive REPL for Strix: **SQL mode** (existing execute surface) plus **command mode** (`.dot` meta-commands, not SQL).

| | |
|---|---|
| **Branch** | `feature/cli-shell` |
| **Depends on** | Execute v1 DoD ([`sql-execute.md`](sql-execute.md) E1–E6 landed), dialect honesty ([`sql-dialect.md`](sql-dialect.md)), batch CLI (`strix init` / `strix sql` in [`src/cli`](../src/cli)) |
| **Does not invent** | A second SQL dialect — statements go through `src/exec` as today; meta-commands are a separate line-based language |

---

## Audience

| Reader | Use this doc to… |
|--------|------------------|
| Implementer | Start at [Prerequisites](#prerequisites--starting-state), then phase **C1** |
| PM / lead | Track [Phased delivery](#phased-delivery); minimum ship = [DoD](#definition-of-done-shell-v1) (**C1–C4**); **C5** is stretch |

**Rule for phases:** every phase ends with user-visible value. Scaffolding (REPL types, dispatch table, line buffer) is an implementation detail inside the phase that needs it — never a standalone milestone.

---

## Prerequisites / starting state

Already landed (do not re-implement):

| Layer | Status | Notes |
|-------|--------|--------|
| `src/exec` | E1–E6 | Session open/close; `exec_script` / `exec_statement`; result kinds; error formatting |
| `src/sql` | Parser v1 | Pure parse; no storage imports |
| `src/engine` | Storage S0–S4 + execute needs | Catalog v2 tables; indexes; CRUD |
| CLI batch | `strix init` / `strix sql` | `-c` / file / stdin; `--continue-on-error`; default path `database.strix`; `ensure_strix_path` |
| SELECT print | `format_result_set` / `print_result_set` | Aligned column table with headers always on |

**Honest surface:** shell SQL can only run what execute supports. Unsupported AST still fails with clear `Exec_Error` (see [`sql-dialect.md`](sql-dialect.md) “Executed vs parsed only”). Meta-commands must not pretend otherwise.

---

## Goals

- Interactive REPL that feels familiar to `sqlite3` users: open a DB, prompt, type SQL or `.commands`.
- **SQL mode:** accumulate lines until a statement terminator (`;`), then run via `src/exec` on the open session.
- **Command mode:** lines that begin with `.` are meta-commands — **not** parsed as SQL and **not** part of the SQL grammar.
- Keep **`strix sql`** and **`strix init`** behavior stable (batch / create); shell is additive.
- Print SELECT / DDL / DML results consistently with (or as a controlled extension of) today’s batch CLI formatting.
- Tests + coverage inventory (≥80%) for new shell surface, same hard rule as execute phases.

## Non-goals (shell v1)

- Full SQLite `.command` catalog (`.dump`, `.backup`, `.restore`, `.import`, `.excel`, `.eqp`, `.expert`, …).
- Tab completion, history search UI, syntax highlighting, pager integration.
- Network / multi-user server; shell is local file + TTY/stdin.
- A second SQL dialect, `PRAGMA` execution, or inventing SQL for introspection when a `.command` is the right tool.
- Changing batch `strix sql` semantics (exit codes, `-c`, stdin) except shared helpers refactored without behavior change.
- GUI / web console.
- Prepared-parameter UX (`.param` / bind helpers): execute **F4** provides a session API (`session_bind*` / `exec_statement_params`); shell/batch remain literals-in-SQL until a later shell plan.

---

## Architecture

```text
  argv
    │
    ├─ init  ──────────────────────────► engine_create (unchanged)
    ├─ sql   ──────────────────────────► batch: open → exec_script → print → exit
    └─ shell ──► REPL loop
                    │
                    ├─ line starts with '.' (after optional leading space)
                    │     → meta dispatcher (line-based; newline ends command)
                    │
                    └─ else
                          → append to SQL buffer
                          → when buffer has a complete stmt ('; ';')
                                → exec_statement / exec_script slice via src/exec
                                → print result / error
                                → clear buffer (keep leftover if any)
```

| Package | Role |
|---------|------|
| `src/cli` | Entry dispatch; batch `sql` / `init` stay; **shell REPL + meta-commands** live here (e.g. `shell.odin` / `meta.odin`) |
| `src/exec` | Unchanged contract for SQL; may add **thin introspection helpers** if catalog listing is awkward from CLI alone (prefer exec over teaching CLI about btree layout) |
| `src/sql` | Unchanged; shell does not import engine into the parser |
| `src/engine` | Open/close already via exec session; catalog reads for `.tables` / `.schema` as needed |

**Import rule (unchanged spirit):** `sql` ↛ `exec` / `engine`. Shell/CLI → `exec` (+ `engine` only for helpers already used or small open wrappers). Meta-commands are **not** SQL AST nodes.

### Two modes (hard boundary)

| Mode | Trigger | Completeness | Backend |
|------|---------|--------------|---------|
| **Command** | Trimmed line starts with `.` | Single physical line (newline ends it) | Meta dispatcher → catalog/print/session ops |
| **SQL** | Anything else | Buffer until `;` completes a statement (or script chunk) | `src/exec` only |

- A `.command` mid-SQL-buffer is **not** supported: if the buffer is non-empty and the user types a dot-line, **default:** reject with a clear error (“finish or clear the SQL buffer first”) and leave the buffer intact. (Open Q #3.)
- Dot-commands never require a trailing `;`. A trailing `;` on a meta-line is **default:** treated as part of arguments or rejected as unknown — prefer **strip one optional trailing `;`** for friendliness (`.quit;` works).

### Sketch API (CLI-local)

```odin
Shell_State :: struct {
  session:     exec.Exec_Session, // or optional / closed when no DB
  db_path:     string,            // display + reopen
  sql_buf:     strings.Builder,   // multi-line SQL accumulator
  headers:     bool,              // default true
  mode:        Display_Mode,      // .Column | .List
  // optional: last_error for exit policy stretch
}

shell_run :: proc(path: string, /* opts */) -> int   // process exit code

// Pure pieces for unit tests (no TTY):
shell_line_kind   :: proc(line: string) -> enum { Meta, Sql, Empty }
shell_sql_ready   :: proc(buf: string) -> bool       // has complete stmt via ';'
meta_parse        :: proc(line: string) -> (Meta_Cmd, error)
meta_dispatch     :: proc(s: ^Shell_State, cmd: Meta_Cmd) -> (ok: bool)
```

Exact names are flexible; the split **pure parse/buffer helpers + I/O REPL loop** is the contract. Types appear when C1 needs them — not as a prior scaffold phase.

---

## Entry points

| Invocation | Behavior | v1 |
|------------|----------|----|
| `strix shell [path]` | Interactive REPL; default path `database.strix`; `ensure_strix_path` | **Yes — primary** |
| `strix sql …` | Batch only (`-c` / file / stdin); **unchanged** | Keep |
| `strix init [path]` | Create DB; **unchanged** | Keep |
| `strix` (no args) | If stdin is a TTY → shell on default path; else usage + exit 1 | **C5 landed** |
| `strix shell [path] -c 'SQL'` | **Default:** not required — use `strix sql` for one-shot | Out of v1 |
| `sqlite3`-style `strix db.strix` (path as argv0 subcommand) | **Default:** no — conflicts with verb dispatch | Out of v1 |

Usage text must list `shell` alongside `init` / `sql`.

---

## REPL behavior

### Prompt

| State | Prompt | Notes |
|-------|--------|-------|
| Primary | `strix> ` | Default (open Q #2) |
| Continuation | `   ...> ` | SQL buffer non-empty / incomplete |
| After `.open` | same prompts | Path shown via `.help` / optional banner once at start |

**Startup banner (default):** one line, e.g. `Strix version …` / `Connected to path` — keep minimal; no ASCII art.

**Missing DB file:** if path does not exist, **default:** error and exit 1 with hint to `strix init` (do not auto-create in the shell). Same honesty as `session_open` failure today.

### SQL accumulation

1. Read a line (stdin). Empty lines: ignore if buffer empty; if buffer non-empty, append newline/whitespace as needed and keep waiting.
2. If command mode → handle meta; do not touch SQL buffer (except explicit clear — none in v1 beyond error policy above).
3. Else append line to `sql_buf` (with newline).
4. When the buffer contains at least one complete statement terminated by `;` (string/comment-aware enough to match execute expectations — **default:** reuse or share logic with script splitting / a small scanner that respects `'…'` and `--` / `/* */` so `;` inside strings does not end the statement):
   - Run the complete prefix via exec (one or more statements if multiple `;` arrived at once).
   - Print each result as today (`ok` / `N rows` / result set).
   - On error: print to stderr; **stay in the REPL** (interactive does not exit).
   - Leave any trailing incomplete text in the buffer.

**EOF (Ctrl-D):** if a flush fence is live → **refuse exit like `.quit`** (stderr: retry `COMMIT` first; stay in REPL on a TTY). Piped/non-TTY stdin EOF while fenced → exit **1** and **forfeit** in-memory recovery (cannot keep reading). If SQL buffer non-empty (and not fenced) → error “incomplete SQL” on stderr, exit **1**; if buffer empty → exit **0** (like a clean `.quit`). Destroy/close failure always forces exit **1**.

### Ctrl-C

**Default (v1):** process default (may kill the process). Fancy “clear buffer / reset line” is **C5 stretch** if the platform readline story allows it without a heavy dependency.

---

## Meta-command set

### v1 minimum (DoD)

| Command | Arguments | Behavior | AC (summary) |
|---------|-----------|----------|--------------|
| `.help` | none | List all shipped commands (v1 has no per-command `.help cmd` topic) | User sees every v1 command documented |
| `.quit` / `.exit` | none | Close session; exit process **0** | Synonyms; both work; **refuse** while flush fence live (retry `COMMIT` first) — no exit 0 over uncleared fence |
| `.tables` | none | List user table names (catalog), one per line or spaced like SQLite | After `CREATE TABLE`, name appears; empty DB → empty/no tables message |
| `.schema` | `[table]` | Print synthesized `CREATE TABLE` (and indexes if cheap) from **catalog meta**, not a second SQL dialect | No arg → all tables; with arg → that table or clear “no such table” |
| `.read` | `FILE` | Read file as SQL text; execute via `exec_script` on current session | Path may contain spaces (remainder of line, or `'…'` / `"…"` quotes); errors formatted; REPL continues; **prints each statement result** in script order (not only the last); incomplete/meta mix in file: SQL only (files are SQL scripts, not dot-commands) unless a later phase says otherwise |
| `.headers` | `on` \| `off` | Toggle column-name header row for result sets | Default **on**; affects shell SELECT print; batch `strix sql` stays headers-on unless later shared |
| `.mode` | `column` \| `list` | `column` = aligned table (today); `list` = separator-delimited (`\|` default, SQLite-like) | Switching modes changes subsequent SELECT output only |
| `.open` | `[path]` | Close current session; open path (`ensure_strix_path`); no arg → print current path; `.open path` switches | Path may contain spaces (remainder of line, or quoted); failed open → stderr, **keep previous session**; **refuse early** while `explicit_txn` or engine `in_txn` (COMMIT/ROLLBACK first — no silent rollback; covers flush-fence recovery; the late “close refused after opening the new path” branch is defensive/dead under that early check); on success reset `sql_buf`, restore `.output` to stdout, clear `had_sql_error`/`quit` (keep `--bail`); startup open failure → exit 1 |

### Out of scope for v1 (stretch / later)

| Command / feature | Notes |
|-------------------|--------|
| `.dump` | Full SQL dump — large; post-DoD |
| `.once` | One-shot output redirect — not landed |
| `.timer` | Wall time per stmt — stretch |
| `.width` | Column widths — stretch |
| `.output` / `.separator` / `.nullvalue` | **C5 landed** (see phase C5) |
| `.indexes` | Useful; can fold into `.schema` for v1 |
| Tab completion / `readline` | Stretch |
| Dot-commands inside `.read` files | **Default: no** — `.read` is SQL-only scripts |

---

## Interaction with batch CLI

| Concern | Policy |
|---------|--------|
| `strix sql` | Remains the batch entry; scripts, CI, `-c` |
| `strix shell` | Interactive only (v1) |
| Shared printers | Refactor `format_result_set` to honor headers/mode **when called from shell**; batch keeps current aligned+headers behavior (call with defaults) |
| `init` | Unchanged; shell does not create databases |
| Exit codes | Batch: non-zero on open/exec failure (today). Interactive: see [Errors & exit codes](#errors--exit-codes) |

Do **not** break existing CLI tests or `parse_sql_command_args` contracts while adding shell.

---

## Errors & exit codes

| Context | SQL / meta error | Process exit |
|---------|------------------|--------------|
| `strix sql` (batch) | stderr + stop (unless `--continue-on-error`) | **1** on failure; also **1** if close refused (flush fence) — **forfeits** in-memory recovery (no post-exit `COMMIT`) |
| `strix shell` startup open fail | stderr + hint `strix init` | **1** |
| `strix shell` during REPL | stderr; print `Exec_Error` via `format_error` when useful | **stay**; `.quit` / clean EOF → **0** when not fenced |
| Flush fence (recovery) | stderr; retry `COMMIT` on open session | `.quit` / EOF (TTY) / `--bail` exit **refused** until `COMMIT`; destroy refused; session kept open; non-TTY EOF while fenced → exit **1** + forfeit |
| Incomplete SQL on EOF | stderr | **1** |
| Unknown `.command` | stderr `unknown command: …` (suggest `.help`) | stay |
| Meta usage error | stderr short usage for that command | stay |

**Default:** interactive exit status does **not** reflect “last statement failed” (avoids surprising `0` vs `1` after exploratory errors). **C5:** `shell --bail` stops after a SQL error and exits **1** (sqlite `-bail`-like) — **except** while a flush fence is live: bail must not process-exit; stay for recovery `COMMIT`.

---

## Display model

| Setting | Default | Effect |
|---------|---------|--------|
| `.headers` | `on` | Print column names for `.Result_Set` |
| `.mode column` | **default** | Aligned columns (reuse / extend `format_result_set`) |
| `.mode list` | off | `col1\|col2\|…` per row; header line when headers on |

DDL/DML non-result output stays `ok` / `N rows` on stdout (not mode-sensitive).

**Multi-statement scripts** (`.read` and batch `strix sql`): `exec_script` keeps every statement result; the CLI prints them in order (`ok` / `N rows` / each result set), not only the last statement. Interactive typed SQL still runs one complete statement at a time via `exec_statement`.

**Paths with spaces:** `.open`, `.read`, and `.output` take the remainder of the line as the path, or a single-quoted / double-quoted path (trailing junk after a quoted path is rejected).

---

## Introspection without a second dialect

- **`.tables` / `.schema`** read catalog metadata (table names, columns, null/pk flags, indexes when available).
- **`.schema`** prints a **best-effort synthesized** `CREATE TABLE` / `CREATE INDEX` text suitable for humans — it is not guaranteed to round-trip through the parser bit-identically, and it must not claim execute supports constraints the catalog does not store.
- Prefer adding `exec` helpers (e.g. list tables, describe table) over duplicating btree walks in CLI.
- Optional later: persist original `CREATE` text in catalog ([`sql-execute.md`](sql-execute.md) open Q #5) — shell can prefer that when present; **not required for shell DoD**.

---

## Phased delivery

Minimum DoD = **C1–C4**. **C5** is stretch.

| Phase | Ships | Value |
|-------|-------|-------|
| **C1** | REPL + SQL mode + `.help` / `.quit` / `.exit` | Interactive SQL against a `.strix` file |
| **C2** | `.tables` / `.schema` | Catalog introspection without writing SQL |
| **C3** | `.headers` / `.mode` / `.read` | Display control + in-REPL scripts |
| **C4** | `.open` + polish + coverage DoD | Session switch + ship ← **DoD** |
| **C5** | Stretch UX | TTY bare `strix`, `.output`, Ctrl-C buffer clear, etc. |

### Phase C1 — REPL, SQL mode, help/quit

First milestone. Wire `strix shell [path]` end-to-end.

- [x] `strix shell [path]` opens session (default `database.strix`); missing file → clear error + exit 1
- [x] Prompt `strix> ` / continuation `   ...> `; multi-line SQL until `;`
- [x] Complete SQL runs through `src/exec`; print `ok` / `N rows` / result set; errors on stderr; **REPL continues**
- [x] String/comment-aware `;` termination (no false end inside `'…'` / comments)
- [x] `.help` lists v1 commands (C1 may note “coming soon” only for commands landed in later phases — prefer listing only what works **or** list all v1 with honest “not yet” ; **default:** list only implemented commands, grow the list each phase)
- [x] `.quit` and `.exit` close session and exit 0
- [x] Empty line / whitespace-only ignored at primary prompt
- [x] Usage (`strix help`) mentions `shell`
- [x] Tests: pure buffer/`;` readiness; meta parse for help/quit; smoke open+exec+quit (temp DB)
- [x] Wire shell tests into `./build.sh test` (e.g. `src/test/cli` or extend existing CLI tests)
- [x] Coverage inventory started: [`cli-shell-c1-coverage.md`](cli-shell-c1-coverage.md)

**Exit:** User can `strix init demo && strix shell demo`, type `CREATE TABLE…;`, `INSERT…;`, `SELECT…;`, see results, `.quit`. No empty “dispatch table only” phase.

### Phase C2 — `.tables` / `.schema`

- [x] `.tables` lists table names from catalog (stable order: lexical)
- [x] `.schema` with no args prints synthesized schema for all tables
- [x] `.schema table` prints one table or clear error if missing
- [x] Indexes: include `CREATE INDEX` lines when index catalog meta is available (E5); if awkward, tables-only schema is OK for C2 exit with a follow-up checkbox in C4
- [x] Tests: create/drop via SQL then `.tables` / `.schema` match catalog; unknown table error
- [x] Coverage inventory: [`cli-shell-c2-coverage.md`](cli-shell-c2-coverage.md)

**Exit:** User can explore a DB without memorizing `sqlite_master` (which Strix does not expose as SQL).

### Phase C3 — Display toggles + `.read`

- [x] `.headers on` / `.headers off` (invalid arg → usage error)
- [x] `.mode column` / `.mode list` (invalid → usage error)
- [x] SELECT printing respects headers + mode; batch `strix sql` unchanged defaults
- [x] `.read FILE` executes SQL file on current session; file errors and SQL errors reported; REPL continues
- [x] `.read` does **not** interpret dot-commands inside the file (SQL script only)
- [x] Tests: headers off omits names; list mode separators; `.read` temp `.sql` round-trip
- [x] Coverage inventory: [`cli-shell-c3-coverage.md`](cli-shell-c3-coverage.md)

**Exit:** User can load a script and tweak SELECT layout interactively.

### Phase C4 — `.open`, polish, DoD

- [x] `.open path` switches database (close old / open new); failed open keeps previous session when possible
- [x] `.open` refuses while an explicit transaction is open; successful switch resets SQL buffer / `.output` / error flags
- [x] `.open` with no args prints current resolved path
- [x] Dot-line while SQL buffer non-empty → clear error; buffer preserved (Q #3 default)
- [x] Optional trailing `;` on meta-commands accepted (stripped)
- [x] EOF policies: clean → 0; incomplete SQL → 1; flush fence → refuse exit like `.quit` (TTY stay / non-TTY forfeit)
- [x] Docs: this plan checkboxes updated; brief pointer from [`sql-execute.md`](sql-execute.md) CLI section to this doc (one paragraph / link — implementer updates when landing C1+)
- [x] Full v1 `.help` text complete for all DoD commands
- [x] Tests for `.open` switch + failed open; EOF exit codes where testable
- [x] Coverage inventory: [`cli-shell-c4-coverage.md`](cli-shell-c4-coverage.md); **≥80%** on shell v1 inventory

**Exit:** Full [DoD](#definition-of-done-shell-v1). **← minimum shell v1**

### Phase C5 — Stretch UX

- [x] Bare `strix` with TTY stdin → shell on default path (non-TTY keeps usage/exit 1)
- [x] `.output FILE` / `.output stdout` redirect
- [ ] Ctrl-C clears SQL buffer instead of killing — **deferred** (would need `sigaction` + non-blocking/interruptible line read; no readline dep added)
- [x] `.separator` for list mode; `.nullvalue` (CLI rewrites exec’s `"NULL"` sentinel; TEXT `'NULL'` is indistinguishable)
- [x] `shell --bail` — on SQL error set quit + process exit **1** (also if quitting after an error); **refuse quit/exit while flush fence live**
- [x] Coverage inventory: [`cli-shell-c5-coverage.md`](cli-shell-c5-coverage.md) (**93.8%**)

**Exit:** nicer power-user UX; not required for DoD. Ctrl-C buffer clear still open.

---

## Testing strategy

| Layer | Focus |
|-------|--------|
| Pure unit | `shell_line_kind`, SQL buffer readiness / `;` in strings, `meta_parse` argv split, display formatters |
| Integration | Temp `.strix` via `init`/`engine_create`; feed scripted lines to REPL driver (inject lines, no real TTY required) |
| CLI smoke | `strix shell` help/quit; create/insert/select path; meta introspection |
| Regression | Existing `strix sql` / `init` tests remain green |

**Hard rule (until coverage tooling exists):** each shell phase must ship an inventory of that phase’s new CLI/shell surface (public procs + helpers introduced/changed for the shell) with test mapping, and achieve **≥80% symbol coverage** by the inventory method — same spirit as [`exec-e1-coverage.md`](exec-e1-coverage.md) … [`exec-e6-coverage.md`](exec-e6-coverage.md). Tests must assert exit codes, printed output, and/or durable catalog outcomes — not vacuous “ran without crashing” alone.

Suggested layout:

```text
src/test/cli/          # or src/test/shell/
  shell_buffer_test.odin
  meta_parse_test.odin
  shell_repl_test.odin   # line-injection driver
docs/cli-shell-cN-coverage.md
```

---

## Documentation deliverables

| Doc | Purpose |
|-----|---------|
| `docs/cli-shell.md` | This plan (living) |
| `docs/cli-shell-c1-coverage.md` … `c5` | Phase inventories + ≥80% proof |
| `docs/sql-execute.md` | Cross-link from CLI surface section when shell lands |
| `docs/sql-dialect.md` | Unchanged dialect; shell must stay honest to executed subset |

---

## Definition of done (shell v1)

- [x] Phases **C1–C4** complete; tests green under `./build.sh test`
- [x] `strix shell [path]` interactive SQL + v1 meta-commands work on a real `.strix` file
- [x] `strix sql` / `strix init` behavior unchanged for existing users/tests
- [x] Meta-commands are line-based and **not** folded into `src/sql` grammar
- [x] SQL path uses `src/exec` only (no parallel executor)
- [x] Coverage inventories for C1–C4 with **≥80%** inventory coverage
- [x] `.help` documents the shipped command set

**Stretch (not required for DoD):** C5.

---

## Open questions

Defaults stand unless overridden before/during the relevant phase:

1. **Entry verb:** `shell` vs `repl` vs bare `strix` — **`strix shell [path]`** primary; **C5:** bare TTY → shell on default path.
2. **Prompt string:** `strix>` vs `db>` vs path-based — **default: `strix> ` / `   ...> `**.
3. **Dot-command while SQL buffer non-empty** — **default: error; preserve buffer.**
4. **`.read` and meta-commands** — **default: SQL only inside files.**
5. **Auto-create DB on shell open** — **default: no**; require `strix init`.
6. **Interactive exit code after SQL errors** — **default: `.quit`/clean EOF → 0**; **C5:** `shell --bail` → exit 1 after SQL error (refused while flush fence live).
7. **`.schema` fidelity** — **default: synthesize from catalog**; original SQL text if later stored is optional enhancement.
8. **Package split** — **default: keep shell in `package cli`** (extra files OK); new package only if CLI grows unwieldy.
9. **Line editing library** — **default: plain stdin lines for v1** (no linenoise/readline dependency). Ctrl-C buffer clear still deferred.
10. **Multiple statements pasted at once** — **default: run all complete `;`-terminated statements in order; leave incomplete suffix in buffer.**

---

## Immediate next steps

1. Land this plan on `feature/cli-shell`.
2. Implement **C1** (REPL + SQL + help/quit) with tests and `cli-shell-c1-coverage.md`.
3. Proceed C2 → C3 → C4 without skipping user-visible exits.
)
