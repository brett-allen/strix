package tests

import "core:testing"
import strix ".."

@(test)
test_greeting :: proc(t: ^testing.T) {
	got := strix.greeting()
	testing.expect(t, len(got) > 0)
}
