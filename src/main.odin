package main

import "core:os"
import cli "./cli"

main :: proc() {
	code := cli.run(os.args[1:])
	os.exit(code)
}
