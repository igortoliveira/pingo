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
    .{ .name = "cons", .func = cons, .strict_args = false },
    .{ .name = "car", .func = car },
    .{ .name = "cdr", .func = cdr },
    .{ .name = "null?", .func = isNull },
    .{ .name = "pair?", .func = isPair },
    .{ .name = "eq?", .func = eq },
    // list stores like cons does, so it is equally non-strict (§4).
    .{ .name = "list", .func = list, .strict_args = false },
    .{ .name = "append", .func = append },
    .{ .name = "length", .func = length },
    .{ .name = "not", .func = not },
    .{ .name = "=", .func = numEq },
    .{ .name = "<", .func = lt },
    .{ .name = ">", .func = gt },
    .{ .name = "<=", .func = le },
    .{ .name = ">=", .func = ge },
    .{ .name = "eqv?", .func = eqv },
    .{ .name = "equal?", .func = equalPred },
};

fn compare(args: []const Value, comptime ok: fn (i64, i64) bool) PrimitiveError!Value {
    if (args.len < 2) return error.ArityMismatch;
    var prev = try asInt(args[0]);
    for (args[1..]) |a| {
        const cur = try asInt(a);
        if (!ok(prev, cur)) return .{ .boolean = false };
        prev = cur;
    }
    return .{ .boolean = true };
}

fn numEq(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return compare(args, struct {
        fn f(a: i64, b: i64) bool {
            return a == b;
        }
    }.f);
}

fn lt(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return compare(args, struct {
        fn f(a: i64, b: i64) bool {
            return a < b;
        }
    }.f);
}

fn gt(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return compare(args, struct {
        fn f(a: i64, b: i64) bool {
            return a > b;
        }
    }.f);
}

fn le(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return compare(args, struct {
        fn f(a: i64, b: i64) bool {
            return a <= b;
        }
    }.f);
}

fn ge(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return compare(args, struct {
        fn f(a: i64, b: i64) bool {
            return a >= b;
        }
    }.f);
}

/// §2 "Equivalence predicates": eqv? is identical to eq? in v0.
fn eqv(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    return .{ .boolean = eqValues(args[0], args[1]) };
}

/// §2: structural — pairs recursively, strings by content, else eqv?.
pub fn equalValues(a: Value, b: Value) bool {
    if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) return false;
    return switch (a) {
        .string => std.mem.eql(u8, a.string, b.string),
        .pair => equalValues(a.pair.car, b.pair.car) and equalValues(a.pair.cdr, b.pair.cdr),
        else => eqValues(a, b),
    };
}

fn equalPred(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    return .{ .boolean = equalValues(args[0], args[1]) };
}

fn list(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    var result: Value = .empty_list;
    var i = args.len;
    while (i > 0) {
        i -= 1;
        const p = try arena.create(Value.Pair);
        p.* = .{ .car = args[i], .cdr = result };
        result = .{ .pair = p };
    }
    return result;
}

fn append(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    if (args.len == 0) return .empty_list;
    var result = args[args.len - 1]; // tail is shared, per R5RS
    var i = args.len - 1;
    while (i > 0) {
        i -= 1;
        // copy the spine of args[i], splicing `result` as its tail
        var items: std.ArrayList(Value) = .empty;
        defer items.deinit(arena);
        var rest = args[i];
        while (rest == .pair) : (rest = rest.pair.cdr) try items.append(arena, rest.pair.car);
        if (rest != .empty_list) return error.TypeError; // proper lists only
        var j = items.items.len;
        while (j > 0) {
            j -= 1;
            const p = try arena.create(Value.Pair);
            p.* = .{ .car = items.items[j], .cdr = result };
            result = .{ .pair = p };
        }
    }
    return result;
}

fn length(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    var n: i64 = 0;
    var rest = args[0];
    while (rest == .pair) : (rest = rest.pair.cdr) n += 1;
    if (rest != .empty_list) return error.TypeError;
    return .{ .integer = n };
}

fn not(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = !value_mod.isTruthy(args[0]) };
}

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

/// Identity comparison: immediates by value, symbols by name (v0 does not
/// intern), heap objects (pairs, strings, closures, primitives) by identity.
pub fn eqValues(a: Value, b: Value) bool {
    if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) return false;
    return switch (a) {
        .integer => a.integer == b.integer,
        .boolean => a.boolean == b.boolean,
        .symbol => std.mem.eql(u8, a.symbol, b.symbol),
        .string => a.string.ptr == b.string.ptr and a.string.len == b.string.len,
        .pair => a.pair == b.pair,
        .empty_list, .unspecified => true,
        .closure => a.closure == b.closure,
        .primitive => a.primitive == b.primitive,
        .capability => a.capability == b.capability,
        .pending => a.pending == b.pending,
    };
}

fn eq(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    return .{ .boolean = eqValues(args[0], args[1]) };
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
