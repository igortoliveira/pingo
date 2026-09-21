//! Built-in VM primitives (semantics §1): safe, pure computation only.
//! Anything with authority lives behind host capabilities (Phase 5), never here.

const std = @import("std");
const value_mod = @import("value.zig");
const env_mod = @import("env.zig");

const Value = value_mod.Value;
const PrimitiveError = value_mod.PrimitiveError;

/// Installs all primitives into `scope` (normally the global environment).
pub fn install(scope: *env_mod.Env) std.mem.Allocator.Error!void {
    for (&table) |*p| try scope.define(p.name, .{ .primitive = p });
}

const table = [_]Value.Primitive{
    .{ .name = "+", .func = add },
    .{ .name = "-", .func = sub },
    .{ .name = "*", .func = mul },
    .{ .name = "/", .func = div },
    .{ .name = "cons", .func = cons },
    .{ .name = "car", .func = car },
    .{ .name = "cdr", .func = cdr },
    .{ .name = "null?", .func = isNull },
    .{ .name = "pair?", .func = isPair },
};

fn exactly(args: []const Value, n: usize) PrimitiveError!void {
    if (args.len != n) return error.ArityMismatch;
}

fn asInt(v: Value) PrimitiveError!i64 {
    return switch (v) {
        .integer => |n| n,
        else => error.TypeError,
    };
}

fn add(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    var acc: i64 = 0;
    for (args) |a| acc = std.math.add(i64, acc, try asInt(a)) catch return error.IntegerOverflow;
    return .{ .integer = acc };
}

fn sub(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    if (args.len == 0) return error.ArityMismatch;
    var acc = try asInt(args[0]);
    if (args.len == 1) // unary negation
        return .{ .integer = std.math.negate(acc) catch return error.IntegerOverflow };
    for (args[1..]) |a| acc = std.math.sub(i64, acc, try asInt(a)) catch return error.IntegerOverflow;
    return .{ .integer = acc };
}

fn mul(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    var acc: i64 = 1;
    for (args) |a| acc = std.math.mul(i64, acc, try asInt(a)) catch return error.IntegerOverflow;
    return .{ .integer = acc };
}

fn cons(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    const p = try arena.create(Value.Pair);
    p.* = .{ .car = args[0], .cdr = args[1] };
    return .{ .pair = p };
}

fn car(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return if (args[0] == .pair) args[0].pair.car else error.TypeError;
}

fn cdr(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return if (args[0] == .pair) args[0].pair.cdr else error.TypeError;
}

fn isNull(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = args[0] == .empty_list };
}

fn isPair(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = args[0] == .pair };
}

/// v0 `/` is truncating integer division (only integers exist, §1).
fn div(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    if (args.len < 2) return error.ArityMismatch;
    var acc = try asInt(args[0]);
    for (args[1..]) |a| {
        const d = try asInt(a);
        if (d == 0) return error.DivideByZero;
        acc = std.math.divTrunc(i64, acc, d) catch return error.IntegerOverflow;
    }
    return .{ .integer = acc };
}
