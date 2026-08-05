const Value = @import("value.zig");

pub const Expr = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    identifier: []const u8,
    binary_op: BinaryOp,
    unary_op: UnaryOp,
    function_call: FunctionCall,
    table_constructor: []TableField,
    method_call: MethodCall,
};

pub const BinaryOp = struct {
    op: Op,
    left: *Expr,
    right: *Expr,
};

pub const UnaryOp = struct {
    op: Op,
    operand: *Expr,
};

pub const Op = enum {
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    concat,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_op,
    or_op,
    length,
    not,
    negate,
};

pub const FunctionCall = struct {
    base: *Expr,
    args: []Expr,
};

pub const MethodCall = struct {
    base: *Expr,
    method: []const u8,
    args: []Expr,
};

pub const TableField = struct {
    key: ?Expr,
    value: Expr,
};

pub const Stmt = union(enum) {
    expression: Expr,
    assignment: Assignment,
    local_assignment: LocalAssignment,
    block: []Stmt,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    repeat_stmt: RepeatStmt,
    for_num_stmt: ForNumStmt,
    for_in_stmt: ForInStmt,
    function_def: FunctionDef,
    local_function_def: LocalFunctionDef,
    return_stmt: []Expr,
    break_stmt,
    empty,
};

pub const Assignment = struct {
    targets: []Expr,
    values: []Expr,
};

pub const LocalAssignment = struct {
    names: []const []const u8,
    values: []Expr,
};

pub const IfStmt = struct {
    condition: Expr,
    then_body: []Stmt,
    elseif_clauses: []ElseIfClause,
    else_body: ?[]Stmt,
};

pub const ElseIfClause = struct {
    condition: Expr,
    body: []Stmt,
};

pub const WhileStmt = struct {
    condition: Expr,
    body: []Stmt,
};

pub const RepeatStmt = struct {
    body: []Stmt,
    condition: Expr,
};

pub const ForNumStmt = struct {
    var_name: []const u8,
    start_val: Expr,
    end_val: Expr,
    step_val: ?Expr,
    body: []Stmt,
};

pub const ForInStmt = struct {
    names: []const []const u8,
    iterators: []Expr,
    body: []Stmt,
};

pub const FunctionDef = struct {
    params: []const []const u8,
    body: []Stmt,
};

pub const LocalFunctionDef = struct {
    name: []const u8,
    params: []const []const u8,
    body: []Stmt,
};
