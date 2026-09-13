const std = @import("std");
const token = @import("token.zig");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");

const Token = token.Token;
const TokenType = token.TokenType;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Program = ast.Program;

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidSyntax,
    OutOfMemory,
};

pub const Parser = struct {
    tokens: []const Token,
    current: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token) Parser {
        return .{
            .tokens = tokens,
            .allocator = allocator,
        };
    }

    pub fn parse(self: *Parser) ParseError!Program {
        var statements: std.ArrayList(*Stmt) = .empty;
        errdefer {
            // On error, partial AST stays in the caller arena until freeAst/deinit
            statements.deinit(self.allocator);
        }

        while (!self.isAtEnd()) {
            // Skip leading newlines
            while (self.check(.Newline)) _ = self.advance();
            if (self.isAtEnd()) break;

            const stmt = try self.statement();
            try statements.append(self.allocator, stmt);

            // Optional newlines after statement
            while (self.check(.Newline)) _ = self.advance();
        }

        return .{ .statements = try statements.toOwnedSlice(self.allocator) };
    }

    fn statement(self: *Parser) ParseError!*Stmt {
        if (self.match(.KwIf)) return self.ifStatement();
        if (self.match(.KwWhile)) return self.whileStatement();
        if (self.match(.KwFor)) return self.forStatement();
        if (self.match(.KwDef)) return self.defStatement();
        if (self.match(.KwReturn)) return self.returnStatement();
        if (self.match(.KwPrint)) return self.printStatement();
        if (self.match(.KwPass)) {
            _ = try self.expectNewlineOrEof();
            return try self.allocStmt(.{ .pass = {} });
        }
        if (self.match(.KwBreak)) {
            _ = try self.expectNewlineOrEof();
            return try self.allocStmt(.{ .break_stmt = {} });
        }
        if (self.match(.KwContinue)) {
            _ = try self.expectNewlineOrEof();
            return try self.allocStmt(.{ .continue_stmt = {} });
        }

        // Assignment or expression statement
        const expr = try self.expression();

        if (self.match(.Assign)) {
            // Must be identifier on left
            if (expr.* != .identifier) return error.InvalidSyntax;
            const name = try self.dupe(expr.identifier);
            const value = try self.expression();
            _ = try self.expectNewlineOrEof();
            return try self.allocStmt(.{ .assign = .{ .name = name, .value = value } });
        }

        _ = try self.expectNewlineOrEof();
        return try self.allocStmt(.{ .expr = expr });
    }

    fn ifStatement(self: *Parser) ParseError!*Stmt {
        const condition = try self.expression();
        _ = try self.consume(.Colon, "expected ':' after if condition");
        _ = try self.consume(.Newline, "expected newline after ':'");
        const then_body = try self.block();

        var elifs: std.ArrayList(Stmt.If.Elif) = .empty;
        errdefer elifs.deinit(self.allocator);

        while (self.match(.KwElif)) {
            const elif_cond = try self.expression();
            _ = try self.consume(.Colon, "expected ':' after elif condition");
            _ = try self.consume(.Newline, "expected newline after ':'");
            const elif_body = try self.block();
            try elifs.append(self.allocator, .{ .condition = elif_cond, .body = elif_body });
        }

        var else_body: ?[]const *Stmt = null;
        if (self.match(.KwElse)) {
            _ = try self.consume(.Colon, "expected ':' after else");
            _ = try self.consume(.Newline, "expected newline after ':'");
            else_body = try self.block();
        }

        return try self.allocStmt(.{
            .if_stmt = .{
                .condition = condition,
                .then_body = then_body,
                .elifs = try elifs.toOwnedSlice(self.allocator),
                .else_body = else_body,
            },
        });
    }

    fn whileStatement(self: *Parser) ParseError!*Stmt {
        const condition = try self.expression();
        _ = try self.consume(.Colon, "expected ':' after while condition");
        _ = try self.consume(.Newline, "expected newline after ':'");
        const body = try self.block();
        return try self.allocStmt(.{
            .while_stmt = .{ .condition = condition, .body = body },
        });
    }

    fn forStatement(self: *Parser) ParseError!*Stmt {
        const target = try self.consume(.Identifier, "expected loop variable");
        const target_name = try self.dupe(target.lexeme);
        _ = try self.consume(.KwIn, "expected 'in' after for target");
        const iterable = try self.expression();
        _ = try self.consume(.Colon, "expected ':' after for iterable");
        _ = try self.consume(.Newline, "expected newline after ':'");
        const body = try self.block();
        return try self.allocStmt(.{
            .for_stmt = .{ .target = target_name, .iterable = iterable, .body = body },
        });
    }

    fn defStatement(self: *Parser) ParseError!*Stmt {
        const name_tok = try self.consume(.Identifier, "expected function name");
        const fname = try self.dupe(name_tok.lexeme);
        _ = try self.consume(.LParen, "expected '(' after function name");

        var params: std.ArrayList([]const u8) = .empty;
        errdefer params.deinit(self.allocator);

        if (!self.check(.RParen)) {
            while (true) {
                const param = try self.consume(.Identifier, "expected parameter name");
                try params.append(self.allocator, try self.dupe(param.lexeme));
                if (!self.match(.Comma)) break;
            }
        }
        _ = try self.consume(.RParen, "expected ')' after parameters");
        _ = try self.consume(.Colon, "expected ':' after function signature");
        _ = try self.consume(.Newline, "expected newline after ':'");
        const body = try self.block();

        return try self.allocStmt(.{
            .def = .{
                .name = fname,
                .params = try params.toOwnedSlice(self.allocator),
                .body = body,
            },
        });
    }

    fn returnStatement(self: *Parser) ParseError!*Stmt {
        var value: ?*Expr = null;
        if (!self.check(.Newline) and !self.isAtEnd()) {
            value = try self.expression();
        }
        _ = try self.expectNewlineOrEof();
        return try self.allocStmt(.{ .return_stmt = .{ .value = value } });
    }

    fn printStatement(self: *Parser) ParseError!*Stmt {
        // Support both print(...) and print x, y  (simple form)
        var args: std.ArrayList(*Expr) = .empty;
        errdefer args.deinit(self.allocator);

        if (self.match(.LParen)) {
            if (!self.check(.RParen)) {
                while (true) {
                    try args.append(self.allocator, try self.expression());
                    if (!self.match(.Comma)) break;
                }
            }
            _ = try self.consume(.RParen, "expected ')' after print arguments");
        } else {
            // bare print expr
            try args.append(self.allocator, try self.expression());
            while (self.match(.Comma)) {
                try args.append(self.allocator, try self.expression());
            }
        }
        _ = try self.expectNewlineOrEof();
        return try self.allocStmt(.{ .print = .{ .args = try args.toOwnedSlice(self.allocator) } });
    }

    fn block(self: *Parser) ParseError![]const *Stmt {
        _ = try self.consume(.Indent, "expected indented block");
        var statements: std.ArrayList(*Stmt) = .empty;
        errdefer statements.deinit(self.allocator);

        while (!self.check(.Dedent) and !self.isAtEnd()) {
            while (self.check(.Newline)) _ = self.advance();
            if (self.check(.Dedent) or self.isAtEnd()) break;
            try statements.append(self.allocator, try self.statement());
        }

        if (!self.isAtEnd()) {
            _ = try self.consume(.Dedent, "expected dedent after block");
        }
        return try statements.toOwnedSlice(self.allocator);
    }

    // ── Expression parsing (Pratt-style / precedence climbing) ──

    fn expression(self: *Parser) ParseError!*Expr {
        return self.orExpr();
    }

    fn orExpr(self: *Parser) ParseError!*Expr {
        var left = try self.andExpr();
        while (self.match(.KwOr)) {
            const right = try self.andExpr();
            left = try self.allocExpr(.{ .binary = .{ .op = .Or, .left = left, .right = right } });
        }
        return left;
    }

    fn andExpr(self: *Parser) ParseError!*Expr {
        var left = try self.notExpr();
        while (self.match(.KwAnd)) {
            const right = try self.notExpr();
            left = try self.allocExpr(.{ .binary = .{ .op = .And, .left = left, .right = right } });
        }
        return left;
    }

    fn notExpr(self: *Parser) ParseError!*Expr {
        if (self.match(.KwNot)) {
            const operand = try self.notExpr();
            return try self.allocExpr(.{ .unary = .{ .op = .Not, .operand = operand } });
        }
        return self.comparison();
    }

    fn comparison(self: *Parser) ParseError!*Expr {
        var left = try self.term();
        while (true) {
            const op: ?ast.BinaryOp = if (self.match(.Equal))
                .Eq
            else if (self.match(.NotEqual))
                .Ne
            else if (self.match(.Less))
                .Lt
            else if (self.match(.Greater))
                .Gt
            else if (self.match(.LessEqual))
                .Le
            else if (self.match(.GreaterEqual))
                .Ge
            else
                null;
            if (op == null) break;
            const right = try self.term();
            left = try self.allocExpr(.{ .binary = .{ .op = op.?, .left = left, .right = right } });
        }
        return left;
    }

    fn term(self: *Parser) ParseError!*Expr {
        var left = try self.factor();
        while (true) {
            const op: ?ast.BinaryOp = if (self.match(.Plus))
                .Add
            else if (self.match(.Minus))
                .Sub
            else
                null;
            if (op == null) break;
            const right = try self.factor();
            left = try self.allocExpr(.{ .binary = .{ .op = op.?, .left = left, .right = right } });
        }
        return left;
    }

    fn factor(self: *Parser) ParseError!*Expr {
        var left = try self.power();
        while (true) {
            const op: ?ast.BinaryOp = if (self.match(.Star))
                .Mul
            else if (self.match(.Slash))
                .Div
            else if (self.match(.SlashSlash))
                .FloorDiv
            else if (self.match(.Percent))
                .Mod
            else
                null;
            if (op == null) break;
            const right = try self.power();
            left = try self.allocExpr(.{ .binary = .{ .op = op.?, .left = left, .right = right } });
        }
        return left;
    }

    fn power(self: *Parser) ParseError!*Expr {
        var left = try self.unary();
        if (self.match(.StarStar)) {
            // right-associative
            const right = try self.power();
            left = try self.allocExpr(.{ .binary = .{ .op = .Pow, .left = left, .right = right } });
        }
        return left;
    }

    fn unary(self: *Parser) ParseError!*Expr {
        if (self.match(.Minus)) {
            const operand = try self.unary();
            return try self.allocExpr(.{ .unary = .{ .op = .Neg, .operand = operand } });
        }
        if (self.match(.Plus)) {
            const operand = try self.unary();
            return try self.allocExpr(.{ .unary = .{ .op = .Pos, .operand = operand } });
        }
        return self.call();
    }

    fn call(self: *Parser) ParseError!*Expr {
        var expr = try self.primary();

        while (true) {
            if (self.match(.LParen)) {
                var args: std.ArrayList(*Expr) = .empty;
                errdefer args.deinit(self.allocator);
                if (!self.check(.RParen)) {
                    while (true) {
                        try args.append(self.allocator, try self.expression());
                        if (!self.match(.Comma)) break;
                    }
                }
                _ = try self.consume(.RParen, "expected ')' after arguments");
                expr = try self.allocExpr(.{
                    .call = .{
                        .callee = expr,
                        .args = try args.toOwnedSlice(self.allocator),
                    },
                });
            } else if (self.match(.LBracket)) {
                const index = try self.expression();
                _ = try self.consume(.RBracket, "expected ']' after index");
                expr = try self.allocExpr(.{
                    .subscript = .{ .value = expr, .index = index },
                });
            } else if (self.match(.Dot)) {
                const attr = try self.consume(.Identifier, "expected attribute name after '.'");
                expr = try self.allocExpr(.{
                    .attribute = .{ .value = expr, .attr = try self.dupe(attr.lexeme) },
                });
            } else {
                break;
            }
        }
        return expr;
    }

    fn primary(self: *Parser) ParseError!*Expr {
        if (self.match(.Integer)) {
            const lexeme = self.previous().lexeme;
            const value = std.fmt.parseInt(i64, lexeme, 10) catch return error.InvalidSyntax;
            return try self.allocExpr(.{ .integer = value });
        }
        if (self.match(.Float)) {
            const lexeme = self.previous().lexeme;
            const value = std.fmt.parseFloat(f64, lexeme) catch return error.InvalidSyntax;
            return try self.allocExpr(.{ .float = value });
        }
        if (self.match(.String)) {
            const lexeme = self.previous().lexeme;
            // Strip quotes
            if (lexeme.len < 2) return error.InvalidSyntax;
            const content = lexeme[1 .. lexeme.len - 1];
            // Simple unescape (just \\ and \n for now)
            const unescaped = try self.unescapeString(content);
            return try self.allocExpr(.{ .string = unescaped });
        }
        if (self.match(.KwTrue)) return try self.allocExpr(.{ .boolean = true });
        if (self.match(.KwFalse)) return try self.allocExpr(.{ .boolean = false });
        if (self.match(.KwNone)) return try self.allocExpr(.{ .none = {} });
        if (self.match(.Identifier)) {
            const name = try self.dupe(self.previous().lexeme);
            return try self.allocExpr(.{ .identifier = name });
        }
        if (self.match(.LParen)) {
            const expr = try self.expression();
            _ = try self.consume(.RParen, "expected ')' after expression");
            return expr;
        }
        if (self.match(.LBracket)) {
            var elements: std.ArrayList(*Expr) = .empty;
            errdefer elements.deinit(self.allocator);
            if (!self.check(.RBracket)) {
                while (true) {
                    try elements.append(self.allocator, try self.expression());
                    if (!self.match(.Comma)) break;
                }
            }
            _ = try self.consume(.RBracket, "expected ']' after list");
            return try self.allocExpr(.{ .list = .{ .elements = try elements.toOwnedSlice(self.allocator) } });
        }

        return error.UnexpectedToken;
    }

    fn unescapeString(self: *Parser, content: []const u8) ParseError![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);
        var i: usize = 0;
        while (i < content.len) : (i += 1) {
            if (content[i] == '\\' and i + 1 < content.len) {
                i += 1;
                const escaped: u8 = switch (content[i]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    '\'' => '\'',
                    else => content[i],
                };
                try result.append(self.allocator, escaped);
            } else {
                try result.append(self.allocator, content[i]);
            }
        }
        return try result.toOwnedSlice(self.allocator);
    }

    // ── Helpers ──

    fn dupe(self: *Parser, s: []const u8) ParseError![]const u8 {
        return self.allocator.dupe(u8, s) catch return error.OutOfMemory;
    }

    fn allocExpr(self: *Parser, e: Expr) ParseError!*Expr {
        const ptr = self.allocator.create(Expr) catch return error.OutOfMemory;
        ptr.* = e;
        return ptr;
    }

    fn allocStmt(self: *Parser, s: Stmt) ParseError!*Stmt {
        const ptr = self.allocator.create(Stmt) catch return error.OutOfMemory;
        ptr.* = s;
        return ptr;
    }

    fn match(self: *Parser, typ: TokenType) bool {
        if (self.check(typ)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn check(self: *const Parser, typ: TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.peek().type == typ;
    }

    fn advance(self: *Parser) Token {
        if (!self.isAtEnd()) self.current += 1;
        return self.previous();
    }

    fn isAtEnd(self: *const Parser) bool {
        return self.peek().type == .Eof;
    }

    fn peek(self: *const Parser) Token {
        return self.tokens[self.current];
    }

    fn previous(self: *const Parser) Token {
        return self.tokens[self.current - 1];
    }

    fn consume(self: *Parser, typ: TokenType, msg: []const u8) ParseError!Token {
        _ = msg;
        if (self.check(typ)) return self.advance();
        return error.UnexpectedToken;
    }

    fn expectNewlineOrEof(self: *Parser) ParseError!void {
        if (self.match(.Newline) or self.isAtEnd() or self.check(.Dedent)) return;
        // Allow missing newline at end of input
        if (self.check(.Eof)) return;
        return error.UnexpectedToken;
    }
};

/// Convenience: lex + parse a source string
pub fn parseSource(allocator: std.mem.Allocator, source: []const u8) !Program {
    var lex = try lexer.Lexer.init(allocator, source);
    defer lex.deinit();

    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(allocator);

    while (true) {
        const tok = try lex.nextToken();
        try tokens.append(allocator, tok);
        if (tok.type == .Eof) break;
    }

    var parser = Parser.init(allocator, tokens.items);
    return try parser.parse();
}
