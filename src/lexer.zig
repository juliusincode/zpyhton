const std = @import("std");
const token = @import("token.zig");
const Token = token.Token;
const TokenType = token.TokenType;

pub const Lexer = struct {
    source: []const u8,
    start: usize = 0,
    current: usize = 0,
    line: u32 = 1,
    column: u32 = 1,
    indent_stack: std.ArrayList(u32),
    pending_dedents: u32 = 0,
    at_line_start: bool = true,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Lexer {
        var indent_stack: std.ArrayList(u32) = .empty;
        try indent_stack.append(allocator, 0);
        return .{
            .source = source,
            .indent_stack = indent_stack,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Lexer) void {
        self.indent_stack.deinit(self.allocator);
    }

    pub fn nextToken(self: *Lexer) !Token {
        // Emit pending dedents first
        if (self.pending_dedents > 0) {
            self.pending_dedents -= 1;
            return self.makeToken(.Dedent, "");
        }

        if (self.isAtEnd()) {
            if (self.indent_stack.items.len > 1) {
                _ = self.indent_stack.pop();
                return self.makeToken(.Dedent, "");
            }
            return self.makeToken(.Eof, "");
        }

        // At start of a logical line: compute indentation
        if (self.at_line_start) {
            return try self.handleLineStart();
        }

        // Skip intra-line whitespace and comments
        self.skipInlineWhitespaceAndComments();
        self.start = self.current;

        if (self.isAtEnd()) {
            if (self.indent_stack.items.len > 1) {
                _ = self.indent_stack.pop();
                return self.makeToken(.Dedent, "");
            }
            return self.makeToken(.Eof, "");
        }

        const c = self.advance();

        if (c == '\n') {
            self.line += 1;
            self.column = 1;
            self.at_line_start = true;
            return self.makeToken(.Newline, "\n");
        }

        if (isAlpha(c) or c == '_') return self.identifier();
        if (isDigit(c)) return self.number();
        if (c == '"' or c == '\'') return self.string(c);

        return switch (c) {
            '(' => self.makeToken(.LParen, "("),
            ')' => self.makeToken(.RParen, ")"),
            '[' => self.makeToken(.LBracket, "["),
            ']' => self.makeToken(.RBracket, "]"),
            '{' => self.makeToken(.LBrace, "{"),
            '}' => self.makeToken(.RBrace, "}"),
            ',' => self.makeToken(.Comma, ","),
            ':' => self.makeToken(.Colon, ":"),
            '.' => self.makeToken(.Dot, "."),
            ';' => self.makeToken(.Semicolon, ";"),
            '+' => if (self.match('=')) self.makeToken(.PlusAssign, "+=") else self.makeToken(.Plus, "+"),
            '-' => if (self.match('=')) self.makeToken(.MinusAssign, "-=") else self.makeToken(.Minus, "-"),
            '*' => if (self.match('*')) self.makeToken(.StarStar, "**") else self.makeToken(.Star, "*"),
            '/' => if (self.match('/')) self.makeToken(.SlashSlash, "//") else self.makeToken(.Slash, "/"),
            '%' => self.makeToken(.Percent, "%"),
            '=' => if (self.match('=')) self.makeToken(.Equal, "==") else self.makeToken(.Assign, "="),
            '!' => if (self.match('=')) self.makeToken(.NotEqual, "!=") else self.makeToken(.Invalid, "!"),
            '<' => if (self.match('=')) self.makeToken(.LessEqual, "<=") else self.makeToken(.Less, "<"),
            '>' => if (self.match('=')) self.makeToken(.GreaterEqual, ">=") else self.makeToken(.Greater, ">"),
            else => self.makeToken(.Invalid, self.source[self.start..self.current]),
        };
    }

    /// Handle indentation / blank lines / comment-only lines at the beginning of a line.
    fn handleLineStart(self: *Lexer) anyerror!Token {
        // Count leading spaces/tabs
        var indent: u32 = 0;
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == ' ') {
                indent += 1;
                _ = self.advance();
            } else if (c == '\t') {
                indent += 4;
                _ = self.advance();
            } else {
                break;
            }
        }

        // Blank line or comment-only line → skip (emit newline semantics without changing indent)
        if (self.isAtEnd() or self.peek() == '\n' or self.peek() == '#') {
            // Consume comment if present
            if (!self.isAtEnd() and self.peek() == '#') {
                while (!self.isAtEnd() and self.peek() != '\n') _ = self.advance();
            }
            if (!self.isAtEnd() and self.peek() == '\n') {
                _ = self.advance();
                self.line += 1;
                self.column = 1;
                // stay at_line_start = true
                return self.nextToken(); // recurse for next real line
            }
            // EOF after blank/comment
            self.at_line_start = false;
            if (self.indent_stack.items.len > 1) {
                _ = self.indent_stack.pop();
                return self.makeToken(.Dedent, "");
            }
            return self.makeToken(.Eof, "");
        }

        // Real content line
        self.at_line_start = false;
        const current_indent = self.indent_stack.items[self.indent_stack.items.len - 1];

        if (indent > current_indent) {
            try self.indent_stack.append(self.allocator, indent);
            self.start = self.current;
            return self.makeToken(.Indent, "");
        } else if (indent < current_indent) {
            while (self.indent_stack.items.len > 1 and
                self.indent_stack.items[self.indent_stack.items.len - 1] > indent)
            {
                _ = self.indent_stack.pop();
                self.pending_dedents += 1;
            }
            if (self.indent_stack.items[self.indent_stack.items.len - 1] != indent) {
                return self.makeToken(.Invalid, "inconsistent indent");
            }
            if (self.pending_dedents > 0) {
                self.pending_dedents -= 1;
                self.start = self.current;
                return self.makeToken(.Dedent, "");
            }
        }

        // Same indent — continue with normal token
        self.start = self.current;
        // Re-enter nextToken but now at_line_start is false
        return self.nextToken();
    }

    fn skipInlineWhitespaceAndComments(self: *Lexer) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\t', '\r' => _ = self.advance(),
                '#' => {
                    while (!self.isAtEnd() and self.peek() != '\n') _ = self.advance();
                },
                else => return,
            }
        }
    }

    fn identifier(self: *Lexer) Token {
        while (!self.isAtEnd() and (isAlphaNumeric(self.peek()) or self.peek() == '_')) {
            _ = self.advance();
        }
        const lexeme = self.source[self.start..self.current];
        const typ = token.keywordOrIdentifier(lexeme);
        return self.makeToken(typ, lexeme);
    }

    fn number(self: *Lexer) Token {
        while (!self.isAtEnd() and isDigit(self.peek())) _ = self.advance();

        var is_float = false;
        if (!self.isAtEnd() and self.peek() == '.' and self.peekNext() != null and isDigit(self.peekNext().?)) {
            is_float = true;
            _ = self.advance();
            while (!self.isAtEnd() and isDigit(self.peek())) _ = self.advance();
        }

        if (!self.isAtEnd() and (self.peek() == 'e' or self.peek() == 'E')) {
            is_float = true;
            _ = self.advance();
            if (!self.isAtEnd() and (self.peek() == '+' or self.peek() == '-')) _ = self.advance();
            while (!self.isAtEnd() and isDigit(self.peek())) _ = self.advance();
        }

        const lexeme = self.source[self.start..self.current];
        return self.makeToken(if (is_float) .Float else .Integer, lexeme);
    }

    fn string(self: *Lexer, quote: u8) Token {
        while (!self.isAtEnd() and self.peek() != quote) {
            if (self.peek() == '\n') {
                self.line += 1;
                self.column = 1;
            }
            if (self.peek() == '\\') {
                _ = self.advance();
                if (!self.isAtEnd()) _ = self.advance();
            } else {
                _ = self.advance();
            }
        }
        if (self.isAtEnd()) return self.makeToken(.Invalid, "unterminated string");
        _ = self.advance(); // closing quote
        return self.makeToken(.String, self.source[self.start..self.current]);
    }

    fn makeToken(self: *Lexer, typ: TokenType, lexeme: []const u8) Token {
        return .{
            .type = typ,
            .lexeme = lexeme,
            .line = self.line,
            .column = self.column,
        };
    }

    fn isAtEnd(self: *const Lexer) bool {
        return self.current >= self.source.len;
    }

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.current];
        self.current += 1;
        self.column += 1;
        return c;
    }

    fn peek(self: *const Lexer) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    fn peekNext(self: *const Lexer) ?u8 {
        if (self.current + 1 >= self.source.len) return null;
        return self.source[self.current + 1];
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.isAtEnd() or self.source[self.current] != expected) return false;
        self.current += 1;
        self.column += 1;
        return true;
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
fn isAlphaNumeric(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}
