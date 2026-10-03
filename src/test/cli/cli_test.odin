package cli_tests

import "core:testing"
import cli "../../cli"

@(test)
test_ensure_strix_path_default_and_suffix :: proc(t: ^testing.T) {
	a := cli.ensure_strix_path("")
	defer delete(a)
	testing.expect_value(t, a, cli.DEFAULT_DB_PATH)

	b := cli.ensure_strix_path("demo")
	defer delete(b)
	testing.expect_value(t, b, "demo.strix")

	c := cli.ensure_strix_path("foo.strix")
	defer delete(c)
	testing.expect_value(t, c, "foo.strix")
}
