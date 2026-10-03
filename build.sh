#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

OUT="${OUT:-strix}"
SRC="${SRC:-src}"

usage() {
	cat <<EOF
Usage: $(basename "$0") <command> [odin-args...]

Commands:
  build   Compile the executable (default)
  run     Build and run
  test    Run package tests under src/test/, src/test/sql/, src/test/dbfile/, src/test/paging/, and src/test/engine/
  clean   Remove build artifacts

Environment:
  OUT     Binary name (default: strix)
  SRC     Source package directory (default: src)
EOF
}

cmd="${1:-build}"
shift || true

case "$cmd" in
	build)
		odin build "$SRC" -out:"$OUT" "$@"
		;;
	run)
		odin run "$SRC" -out:"$OUT" "$@"
		;;
	test)
		odin test "$SRC/test" "$@"
		odin test "$SRC/test/sql" "$@"
		odin test "$SRC/test/dbfile" "$@"
		odin test "$SRC/test/paging" "$@"
		odin test "$SRC/test/engine" "$@"
		;;
	clean)
		rm -f "$OUT" "$OUT.exe" "$OUT.dll" "$OUT.lib"
		rm -rf "$OUT.dSYM"
		;;
	-h|--help|help)
		usage
		;;
	*)
		echo "unknown command: $cmd" >&2
		usage >&2
		exit 1
		;;
esac
