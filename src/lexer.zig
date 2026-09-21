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
        quote, // '
        integer,
        real, // has a fraction and/or exponent part
        symbol,
        boolean, // #t or #f; which one is in the source text
        character, // #\x, #\space, #\newline — decoded by the reader
        vector_open, // #(
        string, // includes the surrounding quotes; escapes are decoded by the reader
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
        while (l.pos < l.src.len) {
            if (isWhitespace(l.src[l.pos])) {
                l.pos += 1;
            } else if (l.src[l.pos] == ';') {
                while (l.pos < l.src.len and l.src[l.pos] != '\n') l.pos += 1;
            } else break;
        }
        const start = l.pos;
        if (l.pos >= l.src.len) return .{ .tag = .eof, .start = start, .end = start };

        switch (l.src[l.pos]) {
            '(' => return l.single(.lparen, start),
            ')' => return l.single(.rparen, start),
            '\'' => return l.single(.quote, start),
            '0'...'9' => return l.integer(start),
            '-', '+' => {
                if (l.pos + 1 < l.src.len and isDigit(l.src[l.pos + 1])) {
                    l.pos += 1;
                    return l.integer(start);
                }
                return l.symbol(start);
            },
            '#' => return l.boolean(start),
            '"' => return l.string(start),
            '.' => {
                if (l.pos + 1 < l.src.len and isDigit(l.src[l.pos + 1]))
                    return l.dotReal(start);
                return l.symbol(start); // `.` in dotted pairs, or a symbol
            },
            else => {
                if (isSymbolInitial(l.src[l.pos])) return l.symbol(start);
                return l.single(.invalid, start);
            },
        }
    }

    fn single(l: *Lexer, tag: Token.Tag, start: usize) Token {
        l.pos += 1;
        return .{ .tag = tag, .start = start, .end = l.pos };
    }

    fn integer(l: *Lexer, start: usize) Token {
        while (l.pos < l.src.len and isDigit(l.src[l.pos])) l.pos += 1;
        var is_real = false;
        // fraction: `.` must be followed by a digit (a bare dot belongs to
        // dotted-pair syntax)
        if (l.pos + 1 < l.src.len and l.src[l.pos] == '.' and isDigit(l.src[l.pos + 1])) {
            is_real = true;
            l.pos += 1;
            while (l.pos < l.src.len and isDigit(l.src[l.pos])) l.pos += 1;
        }
        if (l.consumeExponent()) is_real = true;
        return .{ .tag = if (is_real) .real else .integer, .start = start, .end = l.pos };
    }

    /// `.5`-style real (no integer part); `start` is at the dot.
    fn dotReal(l: *Lexer, start: usize) Token {
        l.pos += 1; // consume '.'
        while (l.pos < l.src.len and isDigit(l.src[l.pos])) l.pos += 1;
        _ = l.consumeExponent();
        return .{ .tag = .real, .start = start, .end = l.pos };
    }

    /// Consumes `e[+-]?digits` only when fully present.
    fn consumeExponent(l: *Lexer) bool {
        if (l.pos >= l.src.len or (l.src[l.pos] != 'e' and l.src[l.pos] != 'E')) return false;
        var probe = l.pos + 1;
        if (probe < l.src.len and (l.src[probe] == '+' or l.src[probe] == '-')) probe += 1;
        if (probe >= l.src.len or !isDigit(l.src[probe])) return false;
        l.pos = probe;
        while (l.pos < l.src.len and isDigit(l.src[l.pos])) l.pos += 1;
        return true;
    }

    fn symbol(l: *Lexer, start: usize) Token {
        while (l.pos < l.src.len and isSymbolChar(l.src[l.pos])) l.pos += 1;
        return .{ .tag = .symbol, .start = start, .end = l.pos };
    }

    fn boolean(l: *Lexer, start: usize) Token {
        l.pos += 1; // consume '#'
        if (l.pos < l.src.len and l.src[l.pos] == '(') {
            l.pos += 1;
            return .{ .tag = .vector_open, .start = start, .end = l.pos };
        }
        if (l.pos < l.src.len and l.src[l.pos] == '\\') {
            l.pos += 1; // consume the backslash
            if (l.pos >= l.src.len) return .{ .tag = .invalid, .start = start, .end = l.pos };
            l.pos += 1; // the named/literal char's first byte
            // a letter may start a char name (space, newline)
            while (l.pos < l.src.len and isSymbolChar(l.src[l.pos])) l.pos += 1;
            return .{ .tag = .character, .start = start, .end = l.pos };
        }
        if (l.pos < l.src.len and (l.src[l.pos] == 't' or l.src[l.pos] == 'f')) {
            l.pos += 1;
            if (l.pos >= l.src.len or isDelimiter(l.src[l.pos]))
                return .{ .tag = .boolean, .start = start, .end = l.pos };
        }
        // Not #t/#f followed by a delimiter: consume the run so lexing resumes cleanly.
        while (l.pos < l.src.len and isSymbolChar(l.src[l.pos])) l.pos += 1;
        return .{ .tag = .invalid, .start = start, .end = l.pos };
    }

    fn string(l: *Lexer, start: usize) Token {
        l.pos += 1; // consume opening '"'
        var valid = true;
        while (l.pos < l.src.len) {
            switch (l.src[l.pos]) {
                '"' => {
                    l.pos += 1;
                    const tag: Token.Tag = if (valid) .string else .invalid;
                    return .{ .tag = tag, .start = start, .end = l.pos };
                },
                '\\' => {
                    l.pos += 1;
                    if (l.pos >= l.src.len) break;
                    switch (l.src[l.pos]) {
                        '"', '\\', 'n' => l.pos += 1,
                        else => {
                            valid = false; // unknown escape; keep scanning to the closing quote
                            l.pos += 1;
                        },
                    }
                },
                else => l.pos += 1,
            }
        }
        // Unterminated: consume the rest so lexing terminates.
        return .{ .tag = .invalid, .start = start, .end = l.pos };
    }
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isDelimiter(c: u8) bool {
    return isWhitespace(c) or c == '(' or c == ')';
}

fn isSymbolInitial(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z' => true,
        '!', '$', '%', '&', '*', '+', '-', '.', '/', ':', '<', '=', '>', '?', '^', '_', '~' => true,
        else => false,
    };
}

fn isSymbolChar(c: u8) bool {
    return isSymbolInitial(c) or isDigit(c);
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

test "negative integers" {
    try expectTokens("-42", &.{.integer});
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

test "symbols" {
    try expectTokens("(+ foo bar-baz list->vector <=?)", &.{
        .lparen, .symbol, .symbol, .symbol, .symbol, .symbol, .rparen,
    });
}

test "plus and minus: symbol alone, sign before digits" {
    try expectTokens("+ -", &.{ .symbol, .symbol });
    try expectTokens("+1 -1", &.{ .integer, .integer });
}

test "booleans" {
    try expectTokens("#t #f (#t)", &.{ .boolean, .boolean, .lparen, .boolean, .rparen });
}

test "malformed hash forms are invalid" {
    try expectTokens("#true", &.{.invalid});
    try expectTokens("#x #", &.{ .invalid, .invalid });
}

test "strings" {
    try expectTokens("\"hello\" \"\"", &.{ .string, .string });
    try expectTokens("(\"a\" 1)", &.{ .lparen, .string, .integer, .rparen });
}

test "string escapes" {
    try expectTokens("\"a\\\"b\" \"a\\\\b\" \"a\\nb\"", &.{ .string, .string, .string });
    try expectTokens("\"bad\\qesc\"", &.{.invalid});
}

test "unterminated string is invalid, not a hang" {
    try expectTokens("\"abc", &.{.invalid});
    try expectTokens("\"abc\\", &.{.invalid});
}

test "reals" {
    try expectTokens("3.14 -2.5 .5 1e3 1.5e-2 2E+4", &.{ .real, .real, .real, .real, .real, .real });
    // a bare dot stays a symbol (dotted pairs); incomplete exponents split
    try expectTokens("1 . 2", &.{ .integer, .symbol, .integer });
    try expectTokens("1e", &.{ .integer, .symbol });
    try expectTokens("1.e3", &.{ .integer, .symbol });
}

test "quote" {
    try expectTokens("'x '(1 2)", &.{ .quote, .symbol, .quote, .lparen, .integer, .integer, .rparen });
}

test "comments run to end of line" {
    try expectTokens("1 ; two 3 four\n5", &.{ .integer, .integer });
    try expectTokens("; only a comment", &.{});
    try expectTokens("(a ;)\n)", &.{ .lparen, .symbol, .rparen });
}

test "semicolon inside a string is not a comment" {
    try expectTokens("\"a;b\" 1", &.{ .string, .integer });
}

test "symbols cannot start with a digit run" {
    // "1abc" lexes as integer then symbol; the reader will reject the sequence later.
    try expectTokens("1abc", &.{ .integer, .symbol });
}
