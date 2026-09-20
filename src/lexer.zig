//! Lexer: source bytes → tokens. No allocation; tokens reference the source
//! by position only.

const std = @import("std");

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize, // exclusive

    pub const Tag = enum {
        lparen,
        rparen,
        integer,
        invalid,
        eof,
    };
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src };
    }

    pub fn next(l: *Lexer) Token {
        while (l.pos < l.src.len and isWhitespace(l.src[l.pos])) l.pos += 1;
        const start = l.pos;
        if (l.pos >= l.src.len) return .{ .tag = .eof, .start = start, .end = start };

        switch (l.src[l.pos]) {
            '(' => return l.single(.lparen, start),
            ')' => return l.single(.rparen, start),
            '0'...'9' => return l.integer(start),
            '-' => {
                if (l.pos + 1 < l.src.len and isDigit(l.src[l.pos + 1])) {
                    l.pos += 1;
                    return l.integer(start);
                }
                return l.single(.invalid, start);
            },
            else => return l.single(.invalid, start),
        }
    }

    fn single(l: *Lexer, tag: Token.Tag, start: usize) Token {
        l.pos += 1;
        return .{ .tag = tag, .start = start, .end = l.pos };
    }

    fn integer(l: *Lexer, start: usize) Token {
        while (l.pos < l.src.len and isDigit(l.src[l.pos])) l.pos += 1;
        return .{ .tag = .integer, .start = start, .end = l.pos };
    }
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn expectTokens(src: []const u8, expected: []const Token.Tag) !void {
    var l = Lexer.init(src);
    for (expected) |tag| try std.testing.expectEqual(tag, l.next().tag);
    try std.testing.expectEqual(Token.Tag.eof, l.next().tag);
}

test "parens and integers" {
    try expectTokens("(1 23 (456))", &.{
        .lparen, .integer, .integer, .lparen, .integer, .rparen, .rparen,
    });
}

test "negative integers and lone minus" {
    try expectTokens("-42", &.{.integer});
    try expectTokens("-", &.{.invalid});
}

test "token positions slice the source" {
    var l = Lexer.init("  (42");
    try std.testing.expectEqualStrings("(", l.src[l.next().start..l.pos]);
    const t = l.next();
    try std.testing.expectEqualStrings("42", l.src[t.start..t.end]);
}

test "eof is stable" {
    var l = Lexer.init("");
    try std.testing.expectEqual(Token.Tag.eof, l.next().tag);
    try std.testing.expectEqual(Token.Tag.eof, l.next().tag);
}

test "unknown byte is invalid, lexing continues" {
    try expectTokens("@ 7", &.{ .invalid, .integer });
}
