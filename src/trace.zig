//! Record/replay trace (docs/host.md "Record/replay"): one s-expression per
//! line — `(tool name class latency)` headers, then one `(call ...)` line per
//! settle, in settle order. Written with the ordinary printer so the ordinary
//! reader reads it back — lossless because only pure data crosses the host
//! boundary (§4).

const std = @import("std");
const capability = @import("capability.zig");
const printer = @import("printer.zig");
const value_mod = @import("value.zig");

const Value = value_mod.Value;
const EffectClass = capability.EffectClass;

/// The CLI/trace spelling of an effect class (`--tool name:class` uses the
/// same names, so a header line round-trips through `classFromSpelling`).
pub fn classSpelling(class: EffectClass) []const u8 {
    return switch (class) {
        .pure => "pure",
        .external_independent => "independent",
        .resource_ordered => "resource",
        .globally_ordered => "ordered",
        .irreversible => "irreversible",
    };
}

pub fn classFromSpelling(s: []const u8) ?EffectClass {
    inline for (@typeInfo(EffectClass).@"enum".fields) |f| {
        const class: EffectClass = @enumFromInt(f.value);
        if (std.mem.eql(u8, s, classSpelling(class))) return class;
    }
    return null;
}

pub fn writeTool(w: *std.Io.Writer, name: []const u8, class: EffectClass, latency_ms: u64) std.Io.Writer.Error!void {
    try w.print("(tool {s} {s} {d})\n", .{ name, classSpelling(class), latency_ms });
}

/// One settled call. `result == null` records a failure (`host-error`). An
/// `unspecified` result is recorded as `ok` with no result datum: its printed
/// form (`#<unspecified>`) would not read back.
pub fn writeCall(w: *std.Io.Writer, name: []const u8, args: []const Value, result: ?Value) std.Io.Writer.Error!void {
    try w.print("(call {s} (", .{name});
    for (args, 0..) |a, i| {
        if (i > 0) try w.writeByte(' ');
        try printer.writeValue(a, w);
    }
    try w.writeByte(')');
    if (result) |r| {
        try w.writeAll(" ok");
        if (r != .unspecified) {
            try w.writeByte(' ');
            try printer.writeValue(r, w);
        }
    } else {
        try w.writeAll(" error");
    }
    try w.writeAll(")\n");
}

// -- replay ----------------------------------------------------------------

const datum_mod = @import("datum.zig");
const reader_mod = @import("reader.zig");
const Datum = datum_mod.Datum;

pub const ToolSpec = struct { name: []const u8, class: EffectClass, latency_ms: u64 };

const Entry = struct { key: []const u8, result: ?Value, consumed: bool = false };

pub const ParseError = error{InvalidTrace} || reader_mod.Error;

/// A parsed trace serving recorded results back: FIFO per (name, printed
/// args) key — temporal identity, never a semantic cache (docs/host.md).
pub const Replay = struct {
    tools: []const ToolSpec,
    entries: []Entry,

    pub const Served = union(enum) { ok: Value, failure };

    /// Serve the next recorded occurrence of this call; null = nothing left
    /// for this key (the caller turns that into host-error).
    pub fn next(self: *Replay, scratch: std.mem.Allocator, name: []const u8, args: []const Value) std.mem.Allocator.Error!?Served {
        var buf = std.Io.Writer.Allocating.init(scratch);
        defer buf.deinit();
        keyTo(&buf.writer, name, args) catch return error.OutOfMemory;
        for (self.entries) |*e| {
            if (e.consumed or !std.mem.eql(u8, e.key, buf.written())) continue;
            e.consumed = true;
            return if (e.result) |v| .{ .ok = v } else .failure;
        }
        return null;
    }
};

/// Serve-side key: identical to the parse-side key because `writeValue` and
/// the datum printer share one external representation for pure data.
fn keyTo(w: *std.Io.Writer, name: []const u8, args: []const Value) std.Io.Writer.Error!void {
    try w.print("{s} (", .{name});
    for (args, 0..) |a, i| {
        if (i > 0) try w.writeByte(' ');
        try printer.writeValue(a, w);
    }
    try w.writeByte(')');
}

pub fn parse(arena: std.mem.Allocator, src: []const u8) ParseError!Replay {
    var tools: std.ArrayList(ToolSpec) = .empty;
    var entries: std.ArrayList(Entry) = .empty;
    var r = reader_mod.Reader.init(arena, src, 64);
    while (try r.read()) |d| {
        var items: [5]Datum = undefined;
        var n: usize = 0;
        var rest = d;
        while (rest == .pair) : (rest = rest.pair.cdr) {
            if (n == items.len) return error.InvalidTrace;
            items[n] = rest.pair.car;
            n += 1;
        }
        if (rest != .empty_list or n < 4 or items[0] != .symbol) return error.InvalidTrace;
        if (items[1] != .symbol) return error.InvalidTrace;
        const name = items[1].symbol;

        if (std.mem.eql(u8, items[0].symbol, "tool")) {
            if (n != 4 or items[2] != .symbol or items[3] != .integer) return error.InvalidTrace;
            const class = classFromSpelling(items[2].symbol) orelse return error.InvalidTrace;
            if (items[3].integer < 0) return error.InvalidTrace;
            try tools.append(arena, .{ .name = name, .class = class, .latency_ms = @intCast(items[3].integer) });
        } else if (std.mem.eql(u8, items[0].symbol, "call")) {
            if (items[2] != .pair and items[2] != .empty_list) return error.InvalidTrace;
            if (items[3] != .symbol) return error.InvalidTrace;
            const result: ?Value = if (std.mem.eql(u8, items[3].symbol, "ok"))
                if (n == 5) try value_mod.fromDatum(arena, items[4]) else Value.unspecified
            else if (std.mem.eql(u8, items[3].symbol, "error") and n == 4)
                null
            else
                return error.InvalidTrace;

            var buf = std.Io.Writer.Allocating.init(arena);
            buf.writer.print("{s} ", .{name}) catch return error.OutOfMemory;
            printer.write(items[2], &buf.writer) catch return error.OutOfMemory;
            try entries.append(arena, .{ .key = try buf.toOwnedSlice(), .result = result });
        } else return error.InvalidTrace;
    }
    return .{ .tools = try tools.toOwnedSlice(arena), .entries = try entries.toOwnedSlice(arena) };
}

// -- tests ----------------------------------------------------------------

test "class spellings roundtrip" {
    inline for (@typeInfo(EffectClass).@"enum".fields) |f| {
        const class: EffectClass = @enumFromInt(f.value);
        try std.testing.expectEqual(class, classFromSpelling(classSpelling(class)).?);
    }
    try std.testing.expectEqual(@as(?EffectClass, null), classFromSpelling("bogus"));
}

test "trace lines" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var arg_bytes = "a\nb".*;
    var result_bytes = "search-result".*;
    try writeTool(&out.writer, "search", .external_independent, 150);
    try writeCall(&out.writer, "search", &.{
        .{ .string = &arg_bytes },
        .{ .integer = 7 },
    }, .{ .string = &result_bytes });
    try writeCall(&out.writer, "print", &.{.{ .boolean = true }}, .unspecified);
    try writeCall(&out.writer, "commit", &.{}, null);

    try std.testing.expectEqualStrings(
        \\(tool search independent 150)
        \\(call search ("a\nb" 7) ok "search-result")
        \\(call print (#t) ok)
        \\(call commit () error)
        \\
    , out.written());
}

test "parse and FIFO serve" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var replay = try parse(arena,
        \\(tool f independent 100)
        \\(tool g ordered 50)
        \\(call f (1) ok "first")
        \\(call f (1) ok "second")
        \\(call g () error)
        \\(call print (#t) ok)
    );
    try std.testing.expectEqual(@as(usize, 2), replay.tools.len);
    try std.testing.expectEqual(EffectClass.external_independent, replay.tools[0].class);
    try std.testing.expectEqual(@as(u64, 50), replay.tools[1].latency_ms);

    // same key served in recorded order, never merged (temporal identity)
    const one = [_]Value{.{ .integer = 1 }};
    const a = (try replay.next(arena, "f", &one)).?;
    const b = (try replay.next(arena, "f", &one)).?;
    try std.testing.expectEqualStrings("first", a.ok.string);
    try std.testing.expectEqualStrings("second", b.ok.string);
    try std.testing.expectEqual(@as(?Replay.Served, null), try replay.next(arena, "f", &one));

    // recorded failure and bare-ok unspecified
    try std.testing.expect((try replay.next(arena, "g", &.{})).? == .failure);
    const p = (try replay.next(arena, "print", &.{.{ .boolean = true }})).?;
    try std.testing.expect(p.ok == .unspecified);

    // different args = different key
    try std.testing.expectEqual(@as(?Replay.Served, null), try replay.next(arena, "f", &.{.{ .integer = 2 }}));
}

test "malformed traces are rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "(tool f bogus-class 1)",
        "(tool f independent -1)",
        "(call f (1) maybe)",
        "(call f (1) error 2)",
        "(frob)",
        "42",
    }) |src| try std.testing.expectError(error.InvalidTrace, parse(arena, src));
}
