const std = @import("std");

pub const TokenType = enum {
    // Literals
    Integer,
    Float,
    String,
    Identifier,

    // Keywords
    KwTrue,
    KwFalse,
    KwNone,
    KwIf,
    KwElif,
    KwElse,
    KwWhile,
    KwFor,
    KwDef,
    KwReturn,
    KwPrint,
    KwAnd,
    KwOr,
    KwNot,
    KwIn,
    KwPass,
    KwBreak,
    KwContinue,

    // Operators
    Plus, // +
    Minus, // -
    Star, // *
    Slash, // /
    SlashSlash, // //
    Percent, // %
    StarStar, // **
    Equal, // ==
    NotEqual, // !=
    Less, // <
    Greater, // >
    LessEqual, // <=
    GreaterEqual, // >=
    Assign, // =
    PlusAssign, // +=
    MinusAssign, // -=

    // Delimiters
    LParen, // (
    RParen, // )
    LBracket, // [
    RBracket, // ]
    LBrace, // {
    RBrace, // }
    Comma, // ,
    Colon, // :
    Dot, // .
    Semicolon, // ;

    // Special
    Newline,
    Indent,
    Dedent,
    Eof,
    Invalid,
};

pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    line: u32,
    column: u32,

    pub fn format(self: Token, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("Token({s}, \"{s}\", {d}:{d})", .{
            @tagName(self.type),
            self.lexeme,
            self.line,
            self.column,
        });
    }
};

pub fn keywordOrIdentifier(lexeme: []const u8) TokenType {
    const keywords = std.StaticStringMap(TokenType).initComptime(.{
        .{ "True", .KwTrue },
        .{ "False", .KwFalse },
        .{ "None", .KwNone },
        .{ "if", .KwIf },
        .{ "elif", .KwElif },
        .{ "else", .KwElse },
        .{ "while", .KwWhile },
        .{ "for", .KwFor },
        .{ "def", .KwDef },
        .{ "return", .KwReturn },
        .{ "print", .KwPrint },
        .{ "and", .KwAnd },
        .{ "or", .KwOr },
        .{ "not", .KwNot },
        .{ "in", .KwIn },
        .{ "pass", .KwPass },
        .{ "break", .KwBreak },
        .{ "continue", .KwContinue },
    });
    return keywords.get(lexeme) orelse .Identifier;
}
