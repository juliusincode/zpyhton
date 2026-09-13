const std = @import("std");
const token = @import("token.zig");

pub const BinaryOp = enum {
    Add,
    Sub,
    Mul,
    Div,
    FloorDiv,
    Mod,
    Pow,
    Eq,
    Ne,
    Lt,
    Gt,
    Le,
    Ge,
    And,
    Or,
};

pub const UnaryOp = enum {
    Neg,
    Not,
    Pos,
};

pub const Expr = union(enum) {
    integer: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    none: void,
    identifier: []const u8,
    binary: Binary,
    unary: Unary,
    call: Call,
    list: List,
    subscript: Subscript,
    attribute: Attribute,

    pub const Binary = struct {
        op: BinaryOp,
        left: *Expr,
        right: *Expr,
    };

    pub const Unary = struct {
        op: UnaryOp,
        operand: *Expr,
    };

    pub const Call = struct {
        callee: *Expr,
        args: []const *Expr,
    };

    pub const List = struct {
        elements: []const *Expr,
    };

    pub const Subscript = struct {
        value: *Expr,
        index: *Expr,
    };

    pub const Attribute = struct {
        value: *Expr,
        attr: []const u8,
    };
};

pub const Stmt = union(enum) {
    expr: *Expr,
    assign: Assign,
    if_stmt: If,
    while_stmt: While,
    for_stmt: For,
    def: Def,
    return_stmt: Return,
    print: Print,
    pass: void,
    break_stmt: void,
    continue_stmt: void,
    block: Block,

    pub const Assign = struct {
        name: []const u8,
        value: *Expr,
    };

    pub const If = struct {
        condition: *Expr,
        then_body: []const *Stmt,
        elifs: []const Elif,
        else_body: ?[]const *Stmt,

        pub const Elif = struct {
            condition: *Expr,
            body: []const *Stmt,
        };
    };

    pub const While = struct {
        condition: *Expr,
        body: []const *Stmt,
    };

    pub const For = struct {
        target: []const u8,
        iterable: *Expr,
        body: []const *Stmt,
    };

    pub const Def = struct {
        name: []const u8,
        params: []const []const u8,
        body: []const *Stmt,
    };

    pub const Return = struct {
        value: ?*Expr,
    };

    pub const Print = struct {
        args: []const *Expr,
    };

    pub const Block = struct {
        statements: []const *Stmt,
    };
};

pub const Program = struct {
    statements: []const *Stmt,
};
