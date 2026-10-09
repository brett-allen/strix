package sql

import "core:mem"
import "core:strconv"

free_expr :: proc(expr: ^Expr, allocator := context.allocator) {
	if expr == nil {
		return
	}
	#partial switch expr.kind {
	case .Literal:
		data := &expr.data.(Literal_Data)
		delete(data.text, allocator)
	case .Column_Ref:
		data := &expr.data.(Column_Ref_Data)
		for seg in data.segments {
			delete(seg, allocator)
		}
		delete(data.segments, allocator)
	case .Placeholder, .Star:
	case .Unary:
		data := &expr.data.(Unary_Data)
		free_expr(data.expr, allocator)
	case .Binary:
		data := &expr.data.(Binary_Data)
		free_expr(data.left, allocator)
		free_expr(data.right, allocator)
	case .Call:
		data := &expr.data.(Call_Data)
		delete(data.name, allocator)
		for arg in data.args {
			free_expr(arg, allocator)
		}
		delete(data.args, allocator)
	case .Is_Null:
		data := &expr.data.(Is_Null_Data)
		free_expr(data.expr, allocator)
	case .In_List:
		data := &expr.data.(In_List_Data)
		free_expr(data.expr, allocator)
		for v in data.values {
			free_expr(v, allocator)
		}
		delete(data.values, allocator)
	case .Between:
		data := &expr.data.(Between_Data)
		free_expr(data.expr, allocator)
		free_expr(data.low, allocator)
		free_expr(data.high, allocator)
	case .Cast:
		data := &expr.data.(Cast_Data)
		free_expr(data.expr, allocator)
		delete(data.type_name, allocator)
	}
	free(expr, allocator)
}

placeholder_index_from_text :: proc(text: string) -> int {
	if len(text) <= 1 {
		return 0
	}
	n, ok := strconv.parse_int(text[1:])
	if !ok || n < 0 {
		return 0
	}
	return n
}

// assign_placeholder_index numbers bare `?` left-to-right (0, 1, 2, …).
// Explicit `?N` uses N and advances the auto counter past N when needed.
assign_placeholder_index :: proc(p: ^Parser, text: string) -> int {
	if len(text) <= 1 {
		idx := p.next_placeholder
		p.next_placeholder = idx + 1
		return idx
	}
	idx := placeholder_index_from_text(text)
	if idx >= p.next_placeholder {
		p.next_placeholder = idx + 1
	}
	return idx
}
