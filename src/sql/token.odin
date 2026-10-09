package sql

// Span locates a region in the source text.
// offset/length are byte indices into the original string.
// line and column are 1-based positions of the first byte.
Span :: struct {
	offset: int,
	length: int,
	line:   int,
	column: int,
}

Token :: struct {
	kind: Token_Kind,
	text: string, // slice into the original source (or keyword spelling)
	span: Span,
}

Token_Kind :: enum {
	Invalid,
	EOF,

	// Literals / names
	Ident,
	Integer,
	Float,
	String,
	Blob,

	// Punctuators / operators
	LParen,    // (
	RParen,    // )
	Comma,     // ,
	Semicolon, // ;
	Dot,       // .
	Star,      // *
	Slash,     // /
	Percent,   // %
	Plus,      // +
	Minus,     // -
	Eq,        // =
	EqEq,      // ==
	NotEq,     // != or <>
	Lt,        // <
	LtEq,      // <=
	Gt,        // >
	GtEq,      // >=
	Concat,    // ||
	Question,  // ?

	// Keywords (SQLite-shaped subset used by later phases)
	Kw_Abort,
	Kw_Action,
	Kw_Add,
	Kw_After,
	Kw_All,
	Kw_Alter,
	Kw_And,
	Kw_As,
	Kw_Asc,
	Kw_Attach,
	Kw_Autoincrement,
	Kw_Before,
	Kw_Begin,
	Kw_Between,
	Kw_By,
	Kw_Cascade,
	Kw_Case,
	Kw_Cast,
	Kw_Check,
	Kw_Collate,
	Kw_Column,
	Kw_Commit,
	Kw_Conflict,
	Kw_Constraint,
	Kw_Create,
	Kw_Cross,
	Kw_Current_Date,
	Kw_Current_Time,
	Kw_Current_Timestamp,
	Kw_Database,
	Kw_Default,
	Kw_Deferrable,
	Kw_Deferred,
	Kw_Delete,
	Kw_Desc,
	Kw_Detach,
	Kw_Distinct,
	Kw_Drop,
	Kw_Each,
	Kw_Else,
	Kw_End,
	Kw_Escape,
	Kw_Except,
	Kw_Exclusive,
	Kw_Exists,
	Kw_Explain,
	Kw_Fail,
	Kw_False,
	Kw_For,
	Kw_Foreign,
	Kw_From,
	Kw_Full,
	Kw_Glob,
	Kw_Group,
	Kw_Having,
	Kw_If,
	Kw_Ignore,
	Kw_Immediate,
	Kw_In,
	Kw_Index,
	Kw_Indexed,
	Kw_Initially,
	Kw_Inner,
	Kw_Insert,
	Kw_Instead,
	Kw_Intersect,
	Kw_Into,
	Kw_Is,
	Kw_Isnull,
	Kw_Join,
	Kw_Key,
	Kw_Left,
	Kw_Like,
	Kw_Limit,
	Kw_Match,
	Kw_Natural,
	Kw_No,
	Kw_Not,
	Kw_Notnull,
	Kw_Null,
	Kw_Of,
	Kw_Offset,
	Kw_On,
	Kw_Or,
	Kw_Order,
	Kw_Outer,
	Kw_Plan,
	Kw_Pragma,
	Kw_Primary,
	Kw_Query,
	Kw_Raise,
	Kw_Recursive,
	Kw_References,
	Kw_Regexp,
	Kw_Reindex,
	Kw_Release,
	Kw_Rename,
	Kw_Replace,
	Kw_Restrict,
	Kw_Right,
	Kw_Rollback,
	Kw_Row,
	Kw_Rows,
	Kw_Savepoint,
	Kw_Select,
	Kw_Set,
	Kw_Table,
	Kw_Temp,
	Kw_Temporary,
	Kw_Then,
	Kw_To,
	Kw_Transaction,
	Kw_Trigger,
	Kw_True,
	Kw_Union,
	Kw_Unique,
	Kw_Update,
	Kw_Using,
	Kw_Vacuum,
	Kw_Values,
	Kw_View,
	Kw_Virtual,
	Kw_When,
	Kw_Where,
	Kw_With,
	Kw_Without,
}

keyword_entry :: struct {
	name: string,
	kind: Token_Kind,
}

// Case-insensitive keyword table. Lookup folds ASCII A–Z only.
KEYWORDS := [?]keyword_entry{
	{"ABORT", .Kw_Abort},
	{"ACTION", .Kw_Action},
	{"ADD", .Kw_Add},
	{"AFTER", .Kw_After},
	{"ALL", .Kw_All},
	{"ALTER", .Kw_Alter},
	{"AND", .Kw_And},
	{"AS", .Kw_As},
	{"ASC", .Kw_Asc},
	{"ATTACH", .Kw_Attach},
	{"AUTOINCREMENT", .Kw_Autoincrement},
	{"BEFORE", .Kw_Before},
	{"BEGIN", .Kw_Begin},
	{"BETWEEN", .Kw_Between},
	{"BY", .Kw_By},
	{"CASCADE", .Kw_Cascade},
	{"CASE", .Kw_Case},
	{"CAST", .Kw_Cast},
	{"CHECK", .Kw_Check},
	{"COLLATE", .Kw_Collate},
	{"COLUMN", .Kw_Column},
	{"COMMIT", .Kw_Commit},
	{"CONFLICT", .Kw_Conflict},
	{"CONSTRAINT", .Kw_Constraint},
	{"CREATE", .Kw_Create},
	{"CROSS", .Kw_Cross},
	{"CURRENT_DATE", .Kw_Current_Date},
	{"CURRENT_TIME", .Kw_Current_Time},
	{"CURRENT_TIMESTAMP", .Kw_Current_Timestamp},
	{"DATABASE", .Kw_Database},
	{"DEFAULT", .Kw_Default},
	{"DEFERRABLE", .Kw_Deferrable},
	{"DEFERRED", .Kw_Deferred},
	{"DELETE", .Kw_Delete},
	{"DESC", .Kw_Desc},
	{"DETACH", .Kw_Detach},
	{"DISTINCT", .Kw_Distinct},
	{"DROP", .Kw_Drop},
	{"EACH", .Kw_Each},
	{"ELSE", .Kw_Else},
	{"END", .Kw_End},
	{"ESCAPE", .Kw_Escape},
	{"EXCEPT", .Kw_Except},
	{"EXCLUSIVE", .Kw_Exclusive},
	{"EXISTS", .Kw_Exists},
	{"EXPLAIN", .Kw_Explain},
	{"FAIL", .Kw_Fail},
	{"FALSE", .Kw_False},
	{"FOR", .Kw_For},
	{"FOREIGN", .Kw_Foreign},
	{"FROM", .Kw_From},
	{"FULL", .Kw_Full},
	{"GLOB", .Kw_Glob},
	{"GROUP", .Kw_Group},
	{"HAVING", .Kw_Having},
	{"IF", .Kw_If},
	{"IGNORE", .Kw_Ignore},
	{"IMMEDIATE", .Kw_Immediate},
	{"IN", .Kw_In},
	{"INDEX", .Kw_Index},
	{"INDEXED", .Kw_Indexed},
	{"INITIALLY", .Kw_Initially},
	{"INNER", .Kw_Inner},
	{"INSERT", .Kw_Insert},
	{"INSTEAD", .Kw_Instead},
	{"INTERSECT", .Kw_Intersect},
	{"INTO", .Kw_Into},
	{"IS", .Kw_Is},
	{"ISNULL", .Kw_Isnull},
	{"JOIN", .Kw_Join},
	{"KEY", .Kw_Key},
	{"LEFT", .Kw_Left},
	{"LIKE", .Kw_Like},
	{"LIMIT", .Kw_Limit},
	{"MATCH", .Kw_Match},
	{"NATURAL", .Kw_Natural},
	{"NO", .Kw_No},
	{"NOT", .Kw_Not},
	{"NOTNULL", .Kw_Notnull},
	{"NULL", .Kw_Null},
	{"OF", .Kw_Of},
	{"OFFSET", .Kw_Offset},
	{"ON", .Kw_On},
	{"OR", .Kw_Or},
	{"ORDER", .Kw_Order},
	{"OUTER", .Kw_Outer},
	{"PLAN", .Kw_Plan},
	{"PRAGMA", .Kw_Pragma},
	{"PRIMARY", .Kw_Primary},
	{"QUERY", .Kw_Query},
	{"RAISE", .Kw_Raise},
	{"RECURSIVE", .Kw_Recursive},
	{"REFERENCES", .Kw_References},
	{"REGEXP", .Kw_Regexp},
	{"REINDEX", .Kw_Reindex},
	{"RELEASE", .Kw_Release},
	{"RENAME", .Kw_Rename},
	{"REPLACE", .Kw_Replace},
	{"RESTRICT", .Kw_Restrict},
	{"RIGHT", .Kw_Right},
	{"ROLLBACK", .Kw_Rollback},
	{"ROW", .Kw_Row},
	{"ROWS", .Kw_Rows},
	{"SAVEPOINT", .Kw_Savepoint},
	{"SELECT", .Kw_Select},
	{"SET", .Kw_Set},
	{"TABLE", .Kw_Table},
	{"TEMP", .Kw_Temp},
	{"TEMPORARY", .Kw_Temporary},
	{"THEN", .Kw_Then},
	{"TO", .Kw_To},
	{"TRANSACTION", .Kw_Transaction},
	{"TRIGGER", .Kw_Trigger},
	{"TRUE", .Kw_True},
	{"UNION", .Kw_Union},
	{"UNIQUE", .Kw_Unique},
	{"UPDATE", .Kw_Update},
	{"USING", .Kw_Using},
	{"VACUUM", .Kw_Vacuum},
	{"VALUES", .Kw_Values},
	{"VIEW", .Kw_View},
	{"VIRTUAL", .Kw_Virtual},
	{"WHEN", .Kw_When},
	{"WHERE", .Kw_Where},
	{"WITH", .Kw_With},
	{"WITHOUT", .Kw_Without},
}

is_keyword :: proc(kind: Token_Kind) -> bool {
	return kind >= .Kw_Abort && kind <= .Kw_Without
}

lookup_keyword :: proc(ident: string) -> (Token_Kind, bool) {
	for entry in KEYWORDS {
		if ascii_equal_fold(ident, entry.name) {
			return entry.kind, true
		}
	}
	return .Ident, false
}

ascii_equal_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		ca := a[i]
		cb := b[i]
		if ca >= 'A' && ca <= 'Z' {
			ca += 'a' - 'A'
		}
		if cb >= 'A' && cb <= 'Z' {
			cb += 'a' - 'A'
		}
		if ca != cb {
			return false
		}
	}
	return true
}

token_kind_string :: proc(kind: Token_Kind) -> string {
	#partial switch kind {
	case .Invalid:
		return "Invalid"
	case .EOF:
		return "EOF"
	case .Ident:
		return "Ident"
	case .Integer:
		return "Integer"
	case .Float:
		return "Float"
	case .String:
		return "String"
	case .Blob:
		return "Blob"
	case .LParen:
		return "("
	case .RParen:
		return ")"
	case .Comma:
		return ","
	case .Semicolon:
		return ";"
	case .Dot:
		return "."
	case .Star:
		return "*"
	case .Slash:
		return "/"
	case .Percent:
		return "%"
	case .Plus:
		return "+"
	case .Minus:
		return "-"
	case .Eq:
		return "="
	case .EqEq:
		return "=="
	case .NotEq:
		return "!="
	case .Lt:
		return "<"
	case .LtEq:
		return "<="
	case .Gt:
		return ">"
	case .GtEq:
		return ">="
	case .Concat:
		return "||"
	case .Question:
		return "?"
	}
	if is_keyword(kind) {
		for entry in KEYWORDS {
			if entry.kind == kind {
				return entry.name
			}
		}
	}
	return "Token"
}
