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
