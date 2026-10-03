package cli

import "core:fmt"
import "core:strings"
import engine "../engine"

DEFAULT_DB_PATH :: "database.strix"

// ensure_strix_path returns a heap-allocated path that ends with ".strix".
// Caller owns the result.
ensure_strix_path :: proc(path: string) -> string {
	if path == "" {
		return strings.clone(DEFAULT_DB_PATH)
	}
	if strings.has_suffix(path, ".strix") {
		return strings.clone(path)
	}
	return strings.concatenate({path, ".strix"})
}

// init_database creates a new Strix DB file (page 0 + table_prime) at path.
// Returns a process exit code: 0 on success, non-zero on failure.
init_database :: proc(path: string) -> int {
	resolved := ensure_strix_path(path)
	defer delete(resolved)

	e, err := engine.engine_create(resolved)
	if err != .None {
		fmt.eprintf("strix init: failed to create %s: %s\n", resolved, engine.error_string(err))
		return 1
	}
	engine.engine_close(&e)

	fmt.printf("created %s\n", resolved)
	return 0
}

print_usage :: proc() {
	fmt.eprintf(
		"Usage: strix <command> [args]\n" +
		"\n" +
		"Commands:\n" +
		"  init [path]   Create a new .strix database (default: %s)\n" +
		"  help          Show this help\n",
		DEFAULT_DB_PATH,
	)
}

// run dispatches CLI commands from argv (without the program name).
// Returns a process exit code.
run :: proc(args: []string) -> int {
	if len(args) == 0 {
		print_usage()
		return 1
	}

	switch args[0] {
	case "init":
		if len(args) > 2 {
			fmt.eprintln("strix init: too many arguments")
			print_usage()
			return 1
		}
		path := DEFAULT_DB_PATH
		if len(args) == 2 {
			path = args[1]
		}
		return init_database(path)
	case "help", "-h", "--help":
		print_usage()
		return 0
	case:
		fmt.eprintf("strix: unknown command %q\n", args[0])
		print_usage()
		return 1
	}
}
