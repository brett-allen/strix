package cli_tests

import "core:strings"
import "core:testing"
import cli "../../cli"

@(test)
test_meta_parse_help_quit_exit :: proc(t: ^testing.T) {
	h := cli.meta_parse(".help")
	testing.expect(t, h.ok)
	testing.expect_value(t, h.kind, cli.Meta_Kind.Help)

	h2 := cli.meta_parse("  .help;  ")
	testing.expect(t, h2.ok)
	testing.expect_value(t, h2.kind, cli.Meta_Kind.Help)

	q := cli.meta_parse(".quit")
	testing.expect(t, q.ok)
	testing.expect_value(t, q.kind, cli.Meta_Kind.Quit)

	e := cli.meta_parse(".exit;")
	testing.expect(t, e.ok)
	testing.expect_value(t, e.kind, cli.Meta_Kind.Quit)

	q2 := cli.meta_parse(".q")
	testing.expect(t, q2.ok)
	testing.expect_value(t, q2.kind, cli.Meta_Kind.Quit)
}

@(test)
test_meta_parse_tables_schema_and_strip_semi :: proc(t: ^testing.T) {
	tb := cli.meta_parse(".tables")
	testing.expect(t, tb.ok)
	testing.expect_value(t, tb.kind, cli.Meta_Kind.Tables)

	sc := cli.meta_parse(".schema users;")
	testing.expect(t, sc.ok)
	testing.expect_value(t, sc.kind, cli.Meta_Kind.Schema)
	testing.expect_value(t, sc.args, "users")

	u := cli.meta_parse(".dump")
	testing.expect(t, u.ok)
	testing.expect_value(t, u.kind, cli.Meta_Kind.Unknown)
	testing.expect_value(t, u.name, "dump")

	stripped := cli.meta_strip_trailing_semi("  .quit;  ")
	testing.expect_value(t, stripped, ".quit")
}

@(test)
test_meta_help_text_lists_c3_commands :: proc(t: ^testing.T) {
	// C3 surface still listed; .open is documented as of C4 (full v1 help).
	text := cli.meta_help_text()
	testing.expect(t, strings.contains(text, ".help"))
	testing.expect(t, strings.contains(text, ".quit"))
	testing.expect(t, strings.contains(text, ".exit"))
	testing.expect(t, strings.contains(text, ".tables"))
	testing.expect(t, strings.contains(text, ".schema"))
	testing.expect(t, strings.contains(text, ".headers"))
	testing.expect(t, strings.contains(text, ".mode"))
	testing.expect(t, strings.contains(text, ".read"))
}

@(test)
test_meta_parse_headers_mode_read :: proc(t: ^testing.T) {
	h := cli.meta_parse(".headers off")
	testing.expect(t, h.ok)
	testing.expect_value(t, h.kind, cli.Meta_Kind.Headers)
	testing.expect_value(t, h.args, "off")

	m := cli.meta_parse(".mode list;")
	testing.expect(t, m.ok)
	testing.expect_value(t, m.kind, cli.Meta_Kind.Mode)
	testing.expect_value(t, m.args, "list")

	r := cli.meta_parse(".read script.sql")
	testing.expect(t, r.ok)
	testing.expect_value(t, r.kind, cli.Meta_Kind.Read)
	testing.expect_value(t, r.args, "script.sql")
}

@(test)
test_meta_dispatch_unknown_stays :: proc(t: ^testing.T) {
	s: cli.Shell_State
	cli.shell_state_init(&s)
	defer cli.shell_state_destroy(&s)
	u := cli.meta_parse(".dump")
	testing.expect(t, !cli.meta_dispatch(&s, u))
	testing.expect(t, !s.quit)
}
