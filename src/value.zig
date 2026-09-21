//! Value: runtime values (semantics §1). Distinct from Datum, which is what
//! the reader produces: closures and primitives exist only at runtime, and a
//! quoted datum must be converted before the evaluator can touch it.
//!
//! Ownership: values live in an arena owned by the evaluation session, which
//! outlives any single read (a `define`d value must survive the line that
//! created it). `fromDatum` therefore copies bytes instead of aliasing.

const std = @import("std");
const datum_mod = @import("datum.zig");
const env_mod = @import("env.zig");
const capability_mod = @import("capability.zig");

/// Errors a primitive may raise; a subset of the evaluator's error set
/// (defined here so value.zig doesn't depend on eval.zig).
pub const PrimitiveError = error{
    TypeError,
    DivideByZero,
    IntegerOverflow,
    ArityMismatch,
    OutOfMemory,
};

pub const Value = union(enum) {
    integer: i64,
    real: f64,
    boolean: bool,
    symbol: []const u8,
    string: []const u8,
    pair: *Pair,
    empty_list,
    unspecified,
    closure: *Closure,
    primitive: *const Primitive,
    /// Host capability (§4): kept distinct from primitive so the external
    /// boundary stays semantically visible to the runtime and scheduler.
    capability: *const capability_mod.Capability,
    /// Internal placeholder for an outstanding external call (§4 "Pending
    /// values"). Never guest-detectable; forced at strictness points.
    pending: *Pending,

    pub const Pair = struct { car: Value, cdr: Value };

    pub const Primitive = struct {
        name: []const u8,
        func: *const fn (arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value,
        /// §4 strictness: primitives compute on real values, so their
        /// arguments force pendings — except `cons`, which only stores and is
        /// how pendings flow into lists.
        strict_args: bool = true,
    };

    /// One outstanding/settled external call. Resolves in place: every Value
    /// holding this pointer observes the settlement.
    pub const Pending = struct {
        capability: *const capability_mod.Capability,
        args: []const Value,
        state: State = .outstanding,

        pub const State = union(enum) {
            outstanding,
            resolved: Value,
            failed,
        };
    };

    pub const Closure = struct {
        params: []const []const u8,
        /// §2 formals: `(p ... . rest)` or a bare symbol bind extra arguments
        /// as a list under this name.
        rest: ?[]const u8 = null,
        /// Non-empty body, evaluated like `begin`. The datums must live in
        /// the session arena (they outlive the line that read them).
        body: []const datum_mod.Datum,
        env: *env_mod.Env,
    };
};

/// Semantics §2: only #f is false.
pub fn isTruthy(v: Value) bool {
    return !(v == .boolean and !v.boolean);
}

/// §4: pure data — no procedures or capabilities anywhere in the tree.
pub fn isPureData(v: Value) bool {
    return switch (v) {
        .integer, .real, .boolean, .symbol, .string, .empty_list, .unspecified => true,
        .pair => |p| isPureData(p.car) and isPureData(p.cdr),
        .closure, .primitive, .capability => false,
        // Deep force substitutes resolved pendings before this check runs.
        .pending => false,
    };
}

/// Parses `(lambda (p ...) body1 ... bodyn)` given `form` = the datum after
/// the `lambda` symbol. Shared by the reference evaluator and the machine so
/// the shape rules can't drift apart. n >= 1; params are distinct symbols.
pub fn makeClosure(
    arena: std.mem.Allocator,
    form: datum_mod.Datum,
    scope: *env_mod.Env,
) error{ BadSyntax, OutOfMemory }!Value {
    if (form != .pair) return error.BadSyntax;
    var params: std.ArrayList([]const u8) = .empty;
    defer params.deinit(arena);
    var rest_name: ?[]const u8 = null;

    var rest = form.pair.car;
    if (rest == .symbol) {
        rest_name = rest.symbol; // (lambda args body ...): everything as a list
    } else {
        while (rest == .pair) : (rest = rest.pair.cdr) {
            if (rest.pair.car != .symbol) return error.BadSyntax;
            const name = rest.pair.car.symbol;
            for (params.items) |seen|
                if (std.mem.eql(u8, seen, name)) return error.BadSyntax;
            try params.append(arena, name);
        }
        switch (rest) {
            .empty_list => {},
            .symbol => |r| rest_name = r, // (p ... . rest)
            else => return error.BadSyntax,
        }
    }
    if (rest_name) |r| for (params.items) |seen|
        if (std.mem.eql(u8, seen, r)) return error.BadSyntax;

    var body: std.ArrayList(datum_mod.Datum) = .empty;
    defer body.deinit(arena);
    var b = form.pair.cdr;
    while (b == .pair) : (b = b.pair.cdr) try body.append(arena, b.pair.car);
    if (b != .empty_list or body.items.len == 0) return error.BadSyntax;

    const c = try arena.create(Value.Closure);
    c.* = .{
        .params = try arena.dupe([]const u8, params.items),
        .rest = rest_name,
        .body = try arena.dupe(datum_mod.Datum, body.items),
        .env = scope,
    };
    return .{ .closure = c };
}

/// Binds a closure's formals to `args` in `child` (§2): fixed params
/// positionally, extras as a list under the rest name.
pub fn bindArgs(
    arena: std.mem.Allocator,
    c: *const Value.Closure,
    args: []const Value,
    child: *env_mod.Env,
) error{ ArityMismatch, OutOfMemory }!void {
    if (args.len < c.params.len) return error.ArityMismatch;
    if (c.rest == null and args.len != c.params.len) return error.ArityMismatch;
    for (c.params, args[0..c.params.len]) |name, v| try child.define(name, v);
    if (c.rest) |rname| {
        var list: Value = .empty_list;
        var i = args.len;
        while (i > c.params.len) {
            i -= 1;
            const p = try arena.create(Value.Pair);
            p.* = .{ .car = args[i], .cdr = list };
            list = .{ .pair = p };
        }
        try child.define(rname, list);
    }
}

/// Deep-converts a reader Datum into a Value, copying bytes so the Value's
/// lifetime is independent of the Datum's arena.
pub fn fromDatum(arena: std.mem.Allocator, d: datum_mod.Datum) std.mem.Allocator.Error!Value {
    return switch (d) {
        .integer => |n| .{ .integer = n },
        .real => |x| .{ .real = x },
        .boolean => |b| .{ .boolean = b },
        .symbol => |s| .{ .symbol = try arena.dupe(u8, s) },
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .empty_list => .empty_list,
        .pair => |p| blk: {
            const out = try arena.create(Value.Pair);
            out.* = .{
                .car = try fromDatum(arena, p.car),
                .cdr = try fromDatum(arena, p.cdr),
            };
            break :blk .{ .pair = out };
        },
    };
}

// -- tests --------------------------------------------------------------

const reader_mod = @import("reader.zig");

test "fromDatum converts structure and copies bytes" {
    var datum_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var value_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer value_arena.deinit();

    var r = reader_mod.Reader.init(datum_arena.allocator(), "(1 #t \"s\" foo ())", 8);
    const v = try fromDatum(value_arena.allocator(), (try r.read()).?);

    // Free the datum arena: the Value must not reference it.
    datum_arena.deinit();

    try std.testing.expectEqual(@as(i64, 1), v.pair.car.integer);
    const rest = v.pair.cdr;
    try std.testing.expectEqual(true, rest.pair.car.boolean);
    try std.testing.expectEqualStrings("s", rest.pair.cdr.pair.car.string);
    try std.testing.expectEqualStrings("foo", rest.pair.cdr.pair.cdr.pair.car.symbol);
    try std.testing.expectEqual(Value.empty_list, rest.pair.cdr.pair.cdr.pair.cdr.pair.car);
}

test "unspecified exists only as a Value" {
    const v: Value = .unspecified;
    try std.testing.expect(v == .unspecified);
}
