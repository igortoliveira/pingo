//! Printer: Datum → external representation (`write` semantics: strings come
//! back quoted and escaped, so output is re-readable).

const std = @import("std");
const datum_mod = @import("datum.zig");
const reader_mod = @import("reader.zig");

const Datum = datum_mod.Datum;

pub fn write(d: Datum, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (d) {
        .integer => |n| try w.print("{d}", .{n}),
        .real => |x| try writeReal(x, w),
        .char => |c| try writeChar(c, w),
        .boolean => |b| try w.writeAll(if (b) "#t" else "#f"),
        .symbol => |s| try w.writeAll(s),
        .string => |s| try writeString(s, w),
        .empty_list => try w.writeAll("()"),
        .vector => |items| {
            try w.writeAll("#(");
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeByte(' ');
                try write(item, w);
            }
            try w.writeByte(')');
        },
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

const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;

/// Cycle-safe (§1): the spine is capped and the car side depth-capped; the
/// printer truncates with an ellipsis rather than diverging.
pub fn writeValue(v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
    return writeValueDepth(v, w, 0, false);
}

/// `display` semantics (§8J): strings print unquoted and chars raw; everything
/// else is as `write`. Recurses into aggregates in display mode.
pub fn displayValue(v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
    return writeValueDepth(v, w, 0, true);
}

fn writeValueDepth(v: Value, w: *std.Io.Writer, depth: usize, display: bool) std.Io.Writer.Error!void {
    if (depth > 200) return w.writeAll("...");
    switch (v) {
        .integer => |n| try w.print("{d}", .{n}),
        .real => |x| try writeReal(x, w),
        .char => |c| if (display) try w.writeByte(c) else try writeChar(c, w),
        .boolean => |b| try w.writeAll(if (b) "#t" else "#f"),
        .symbol => |s| try w.writeAll(s),
        .string => |s| if (display) try w.writeAll(s) else try writeString(s, w),
        .empty_list => try w.writeAll("()"),
        .unspecified => try w.writeAll("#<unspecified>"),
        .closure => try w.writeAll("#<procedure>"),
        .primitive => |p| try w.print("#<procedure {s}>", .{p.name}),
        .capability => |c| try w.print("#<capability {s}>", .{c.name}),
        .pending => |p| try w.print("#<pending {s}>", .{p.capability.name}),
        .continuation => try w.writeAll("#<continuation>"),
        .macro => try w.writeAll("#<macro>"),
        .vector => |items| {
            try w.writeAll("#(");
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeByte(' ');
                if (i > 10_000) return w.writeAll(" ...)");
                try writeValueDepth(item, w, depth + 1, display);
            }
            try w.writeByte(')');
        },
        .pair => |p| {
            try w.writeByte('(');
            try writeValueDepth(p.car, w, depth + 1, display);
            var rest = p.cdr;
            var spine: usize = 0;
            while (rest == .pair) : (rest = rest.pair.cdr) {
                spine += 1;
                if (spine > 10_000) return w.writeAll(" ...)");
                try w.writeByte(' ');
                try writeValueDepth(rest.pair.car, w, depth + 1, display);
            }
            if (rest != .empty_list) {
                try w.writeAll(" . ");
                try writeValueDepth(rest, w, depth + 1, display);
            }
            try w.writeByte(')');
        },
    }
}

/// Reals print re-readably: integral values keep a `.0`, non-finite values
/// use the conventional spellings (not readable by v0's reader — noted §1).
pub fn writeReal(x: f64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (std.math.isNan(x)) return w.writeAll("+nan.0");
    if (std.math.isInf(x)) return w.writeAll(if (x > 0) "+inf.0" else "-inf.0");
    if (@floor(x) == x and @abs(x) < 1e15)
        return w.print("{d}.0", .{@as(i64, @intFromFloat(x))});
    try w.print("{d}", .{x});
}

pub fn writeChar(c: u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (c) {
        ' ' => try w.writeAll("#\\space"),
        '\n' => try w.writeAll("#\\newline"),
        '\t' => try w.writeAll("#\\tab"),
        else => try w.print("#\\{c}", .{c}),
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
    try expectRoundtrip("(1 . 2) (1 2 . 3)");
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

const eval_mod = @import("../engine/eval.zig");

test "reals print re-readably" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeValue(.{ .real = 3.5 }, &out.writer);
    try out.writer.writeByte(' ');
    try writeValue(.{ .real = 4.0 }, &out.writer);
    try out.writer.writeByte(' ');
    try writeValue(.{ .real = -0.25 }, &out.writer);
    try std.testing.expectEqualStrings("3.5 4.0 -0.25", out.written());
}

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
