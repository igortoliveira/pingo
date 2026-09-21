//! Printer: Datum → external representation (`write` semantics: strings come
//! back quoted and escaped, so output is re-readable).

const std = @import("std");
const datum_mod = @import("datum.zig");
const reader_mod = @import("reader.zig");

const Datum = datum_mod.Datum;

pub fn write(d: Datum, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (d) {
        .integer => |n| try w.print("{d}", .{n}),
        .boolean => |b| try w.writeAll(if (b) "#t" else "#f"),
        .symbol => |s| try w.writeAll(s),
        .string => |s| try writeString(s, w),
        .empty_list => try w.writeAll("()"),
        .pair => |p| {
            try w.writeByte('(');
            try write(p.car, w);
            var rest = p.cdr;
            while (rest == .pair) : (rest = rest.pair.cdr) {
                try w.writeByte(' ');
                try write(rest.pair.car, w);
            }
            // The reader can't produce improper lists, but print them rather
            // than corrupt output if one is ever constructed programmatically.
            if (rest != .empty_list) {
                try w.writeAll(" . ");
                try write(rest, w);
            }
            try w.writeByte(')');
        },
    }
}

const value_mod = @import("value.zig");
const Value = value_mod.Value;

pub fn writeValue(v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (v) {
        .integer => |n| try w.print("{d}", .{n}),
        .boolean => |b| try w.writeAll(if (b) "#t" else "#f"),
        .symbol => |s| try w.writeAll(s),
        .string => |s| try writeString(s, w),
        .empty_list => try w.writeAll("()"),
        .unspecified => try w.writeAll("#<unspecified>"),
        .closure => try w.writeAll("#<procedure>"),
        .primitive => |p| try w.print("#<procedure {s}>", .{p.name}),
        .capability => |c| try w.print("#<capability {s}>", .{c.name}),
        .pair => |p| {
            try w.writeByte('(');
            try writeValue(p.car, w);
            var rest = p.cdr;
            while (rest == .pair) : (rest = rest.pair.cdr) {
                try w.writeByte(' ');
                try writeValue(rest.pair.car, w);
            }
            if (rest != .empty_list) {
                try w.writeAll(" . ");
                try writeValue(rest, w);
            }
            try w.writeByte(')');
        },
    }
}

fn writeString(s: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

// -- tests --------------------------------------------------------------

fn expectRoundtrip(src: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var r = reader_mod.Reader.init(arena_state.allocator(), src, 16);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var first = true;
    while (try r.read()) |d| {
        if (!first) try out.writer.writeByte(' ');
        first = false;
        try write(d, &out.writer);
    }
    try std.testing.expectEqualStrings(src, out.written());
}

test "read-write roundtrip" {
    try expectRoundtrip("42");
    try expectRoundtrip("-7 #t #f foo");
    try expectRoundtrip("(1 (2 3) () \"a\\nb\" sym)");
    try expectRoundtrip("(quote x)");
    try expectRoundtrip("\"quote\\\" and \\\\ backslash\"");
}

test "quote sugar prints in expanded form" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var r = reader_mod.Reader.init(arena_state.allocator(), "'x", 16);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try write((try r.read()).?, &out.writer);
    try std.testing.expectEqualStrings("(quote x)", out.written());
}

test "writeValue covers runtime-only values" {
    var s = eval_mod.TestSession.init();
    defer s.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try writeValue(try s.run("(cons 1 (cons 2 '()))"), &out.writer);
    try out.writer.writeByte(' ');
    try writeValue(try s.run("+"), &out.writer);
    try out.writer.writeByte(' ');
    try writeValue(try s.run("(lambda (x) x)"), &out.writer);
    try out.writer.writeByte(' ');
    try writeValue(try s.run("(if #f 1)"), &out.writer);
    try std.testing.expectEqualStrings(
        "(1 2) #<procedure +> #<procedure> #<unspecified>",
        out.written(),
    );
}

const eval_mod = @import("eval.zig");

test "improper list prints with dot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try datum_mod.cons(arena, .{ .integer = 1 }, .{ .integer = 2 });
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try write(d, &out.writer);
    try std.testing.expectEqualStrings("(1 . 2)", out.written());
}
