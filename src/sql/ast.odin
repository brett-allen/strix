package sql

// AST nodes for the Strix SQL parser.
// All string fields are AST-owned (cloned). See package comment in parser.odin
// and docs/sql-ast.md for the ownership contract and Table_Element ordering.

Script :: struct {
	statements: []Statement,
}

Statement :: struct {
	kind: Statement_Kind,
	span: Span,
	data: Statement_Data,
}

Statement_Kind :: enum {
	Create_Table,
	Drop_Table,
	Create_Index,
	Drop_Index,
	Alter_Table,
	Select,
	Insert,
	Update,
	Delete,
	Begin,
	Commit,
	Rollback,
}

Statement_Data :: union {
	Create_Table_Stmt,
	Drop_Table_Stmt,
	Create_Index_Stmt,
	Drop_Index_Stmt,
	Alter_Table_Stmt,
	Select_Stmt,
	Insert_Stmt,
	Update_Stmt,
	Delete_Stmt,
	Begin_Stmt,
	Commit_Stmt,
	Rollback_Stmt,
}

// Transaction control (optional TRANSACTION keyword is accepted and discarded).
Begin_Stmt :: struct {}
Commit_Stmt :: struct {}
Rollback_Stmt :: struct {}

// Table body elements in source order (columns and table constraints interleaved).
Table_Element_Kind :: enum {
	Column,
	Table_Constraint,
}

Table_Element :: struct {
	kind:             Table_Element_Kind,
	column:           Column_Def,
	table_constraint: Table_Constraint,
}

Create_Table_Stmt :: struct {
	name:          string,
	if_not_exists: bool,
	elements:      []Table_Element, // preserves CREATE TABLE (…) source order
}

Column_Def :: struct {
	name:        string,
	type_name:   string, // empty if omitted
	constraints: []Column_Constraint,
	span:        Span,
}

Column_Constraint :: struct {
	kind:         Column_Constraint_Kind,
	default_expr: ^Expr, // Default
	check_expr:   ^Expr, // Check
	references:   Foreign_Key_Ref, // References
	span:         Span,
}

Column_Constraint_Kind :: enum {
	Primary_Key,
	Not_Null,
	Unique,
	Default,
	Check,
	References,
}

Foreign_Key_Ref :: struct {
	table:   string,
	columns: []string, // optional referenced column list
}

Table_Constraint :: struct {
	kind:       Table_Constraint_Kind,
	columns:    []string, // PK / UNIQUE / FK local columns
	check_expr: ^Expr,
	references: Foreign_Key_Ref,
	span:       Span,
}

Table_Constraint_Kind :: enum {
	Primary_Key,
	Unique,
	Check,
	Foreign_Key,
}

Create_Index_Stmt :: struct {
	name:          string,
	table_name:    string,
	if_not_exists: bool,
	unique:        bool,
	columns:       []Index_Column,
}

Index_Column :: struct {
	name: string,
	desc: bool,
}

Drop_Table_Stmt :: struct {
	name:      string,
	if_exists: bool,
}

Drop_Index_Stmt :: struct {
	name:      string,
	if_exists: bool,
}

Alter_Table_Stmt :: struct {
	table:  string,
	column: Column_Def, // ADD COLUMN only
}

// --- DML reads ---

Select_Stmt :: struct {
	is_distinct: bool,
	projection:  []Select_Item,
	from:        From_Item,
	joins:       []Join_Clause,
	where_expr:  ^Expr,
	group_by:    []^Expr,
	having:      ^Expr,
	order_by:    []Order_By_Item,
	limit:       ^Expr,
	offset:      ^Expr,
}

Select_Item_Kind :: enum {
	Expr,
	Star,
	Table_Star,
}

Select_Item :: struct {
	kind:  Select_Item_Kind,
	expr:  ^Expr,
	table: string,
	alias: string,
	span:  Span,
}

From_Item :: struct {
	table: string,
	alias: string,
	span:  Span,
}

Join_Kind :: enum {
	Inner, // JOIN / INNER JOIN
	Left,  // LEFT [OUTER] JOIN
	Cross, // CROSS JOIN or comma join
}

Join_Clause :: struct {
	kind:        Join_Kind,
	table:       From_Item,
	on:          ^Expr, // set for ON
	using_cols:  []string, // set for USING
	span:        Span,
}

Order_By_Item :: struct {
	expr: ^Expr,
	desc: bool,
	span: Span,
}

// --- DML writes ---

Insert_Conflict :: enum {
	None,
	Replace,
	Ignore,
}

Insert_Source :: enum {
	Values,
	Select,
}

Insert_Stmt :: struct {
	table:    string,
	columns:  []string,
	conflict: Insert_Conflict,
	source:   Insert_Source,
	rows:     [][]^Expr,
	select:   Select_Stmt,
}

Assignment :: struct {
	column: string,
	value:  ^Expr,
	span:   Span,
}

Update_Stmt :: struct {
	table:      string,
	sets:       []Assignment,
	where_expr: ^Expr,
}

Delete_Stmt :: struct {
	table:      string,
	where_expr: ^Expr,
}

// --- Expressions ---

Expr :: struct {
	kind: Expr_Kind,
	span: Span,
	data: Expr_Data,
}

Expr_Kind :: enum {
	Literal,
	Column_Ref,
	Placeholder,
	Star,
	Unary,
	Binary,
	Call,
	Is_Null,
	In_List,
	Between,
	Cast,
}

Expr_Data :: union {
	Literal_Data,
	Column_Ref_Data,
	Placeholder_Data,
	Unary_Data,
	Binary_Data,
	Call_Data,
	Is_Null_Data,
	In_List_Data,
	Between_Data,
	Cast_Data,
}

Literal_Kind :: enum {
	Integer,
	Float,
	String,
	Blob,
	Null,
}

Literal_Data :: struct {
	lit_kind: Literal_Kind,
	text:     string, // AST-owned (cloned); free_expr deletes it
}

Column_Ref_Data :: struct {
	segments: []string, // AST-owned; quoted idents stored normalized (delimiters stripped)
}

Placeholder_Data :: struct {
	index: int,
}

Unary_Op :: enum {
	Plus,
	Minus,
	Not,
}

Unary_Data :: struct {
	op:   Unary_Op,
	expr: ^Expr,
}

Binary_Op :: enum {
	Or,
	And,
	Concat,
	Add,
	Sub,
	Mul,
	Div,
	Mod,
	Eq,
	EqEq,
	NotEq,
	Lt,
	LtEq,
	Gt,
	GtEq,
}

Binary_Data :: struct {
	op:          Binary_Op,
	left, right: ^Expr,
}

Call_Data :: struct {
	name: string,
	args: []^Expr,
}

Is_Null_Data :: struct {
	expr:    ^Expr,
	negated: bool,
}

In_List_Data :: struct {
	expr:    ^Expr,
	values:  []^Expr,
	negated: bool,
}

Between_Data :: struct {
	expr:    ^Expr,
	low:     ^Expr,
	high:    ^Expr,
	negated: bool,
}

Cast_Data :: struct {
	expr:      ^Expr,
	type_name: string,
}
