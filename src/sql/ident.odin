package sql

import "core:strings"

// clone_ident_name copies an Ident token's text into AST-owned storage.
// Quoted forms ("…", `…`, […]) are normalized: delimiters stripped and
// doubled escapes unescaped. Unquoted idents are cloned verbatim.
// Token text itself always aliases the source buffer; only AST strings are owned.
clone_ident_name :: proc(text: string, allocator := context.allocator) -> string {
	if len(text) >= 2 {
		switch text[0] {
		case '"':
			if text[len(text) - 1] == '"' {
				return unescape_delimited(text, '"', allocator)
			}
		case '`':
			if text[len(text) - 1] == '`' {
				return unescape_delimited(text, '`', allocator)
			}
		case '[':
			if text[len(text) - 1] == ']' {
				return strings.clone(text[1:len(text) - 1], allocator)
			}
		}
	}
	return strings.clone(text, allocator)
}

unescape_delimited :: proc(text: string, delim: u8, allocator := context.allocator) -> string {
	inner := text[1:len(text) - 1]
	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)
	for i := 0; i < len(inner); {
		if inner[i] == delim && i + 1 < len(inner) && inner[i + 1] == delim {
			strings.write_byte(&b, delim)
			i += 2
			continue
		}
		strings.write_byte(&b, inner[i])
		i += 1
	}
	return strings.clone(strings.to_string(b), allocator)
}
