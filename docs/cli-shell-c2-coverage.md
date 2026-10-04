# C2 Symbol Coverage Inventory

**Phase:** C2 (`.tables` / `.schema` catalog introspection)  
**Plan:** [`cli-shell.md`](cli-shell.md)  
**Prior:** [`cli-shell-c1-coverage.md`](cli-shell-c1-coverage.md)  
**Method:** Manual inventory (no llvm-cov). A symbol counts as covered only if a test asserts a **code and/or durable outcome** on a meaningful branch — not “compiles” or bare smoke without classification. Count is **unique procedure symbols** (one row per proc; multi-branch coverage listed in the Branches column).

**Coverage ratio:** **13 / 13 = 100%** (≥ 80% required)

---

## Engine catalog list (`src/engine/catalog.odin`) — 2 / 2

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `catalog_list_tables` | yes | `test_list_tables_lexical_and_empty`; shell create/drop | empty; multiple tables; after DROP |
| `free_catalog_table_names` | yes | same (defer free) | frees owned names + slice |

---

## Exec introspection (`src/exec/introspect.odin`) — 6 / 6

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `list_tables` | yes | lexical; after drop; shell match | empty; sorted lexical |
| `free_table_names` | yes | same | frees |
| `schema_sql` | yes | `test_schema_sql_one_and_all_with_index`; unknown; shell stdout | empty filter → all lexical; one-table; `Unknown_Table` |
| `schema_sql_one` | yes | schema + index DESC; unknown | CREATE TABLE; CREATE INDEX … DESC; missing |
| `write_column_def` | yes | schema synthesis | type; NOT NULL; PRIMARY KEY; DEFAULT |
| `write_default_literal` | yes | INT / TEXT / `X'ABCD'` defaults | Integer; Text; Blob |

---

## Meta-commands (`src/cli/meta.odin`) — 5 / 5

| Symbol | Tested? | Test name(s) | Branches covered |
|--------|---------|--------------|------------------|
| `meta_parse` | yes | `test_meta_parse_tables_schema_and_strip_semi` | `.tables`; `.schema users;`; unknown `.dump` |
| `meta_help_text` | yes | `test_meta_help_text_lists_c2_commands` | lists `.tables`/`.schema`; omits `.read`/`.open` |
| `meta_dispatch` | yes | shell schema stdout; usage; `test_meta_dispatch_unknown_stays` | Tables; Schema; Unknown stays |
| `meta_run_tables` | yes | shell stdout after CREATE/DROP; usage reject | printed names; args → usage |
| `meta_run_schema` | yes | shell stdout all/one; unknown; `test_shell_schema_usage_rejects_extra_args` | printed CREATE; unknown; multi-arg usage |

---

## C2 AC branch matrix

| AC | Asserted |
|----|----------|
| `.tables` lexical catalog names | yes (`list_tables` + shell stdout after CREATE/DROP) |
| `.schema` no args → all tables synthesized | yes (shell stdout + `schema_sql`) |
| `.schema table` → one table or clear error | yes (`Unknown_Table` + meta_dispatch; shell stdout one-table) |
| Indexes include `CREATE INDEX` when meta available | yes (`t_by_name` DESC / `apple_by_name`) |
| Thin `exec` helpers (no btree walk in CLI) | yes (`list_tables` / `schema_sql` only from CLI) |
| Tests wired; `./build.sh test` | yes (`src/test/exec/introspect_test.odin`, `src/test/cli/shell_schema_test.odin`) |

Regression: C1 shell buffer/meta/REPL tests and batch `strix sql` / `init` remain green.
