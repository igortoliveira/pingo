//! Datum: the S-expression produced by the reader. Purely syntactic —
//! closures and other runtime-only values live in Value (Phase 3), not here.
//!
//! Ownership: data are allocated into an arena owned by the caller; there is
//! no per-node deinit. Symbol and string bytes are arena-owned copies too, so
//! a Datum never references the source text.

const std = @import("std");

pub const Datum = union(enum) {
    integer: i64,
    real: f64,
    boolean: bool,
    symbol: []const u8,
    string: []const u8, // decoded bytes (escapes already resolved)
    pair: *Pair,
    empty_list,

    pub const Pair = struct {
        car: Datum,
        cdr: Datum,
    };
};

pub fn cons(arena: std.mem.Allocator, car: Datum, cdr: Datum) !Datum {
    const p = try arena.create(Datum.Pair);
    p.* = .{ .car = car, .cdr = cdr };
    return .{ .pair = p };
}

pub fn symbol(arena: std.mem.Allocator, name: []const u8) !Datum {
    return .{ .symbol = try arena.dupe(u8, name) };
}

test "cons builds proper lists" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // (1 2) == (cons 1 (cons 2 '()))
    const two = try cons(arena, .{ .integer = 2 }, .empty_list);
    const list = try cons(arena, .{ .integer = 1 }, two);

    try std.testing.expectEqual(@as(i64, 1), list.pair.car.integer);
    try std.testing.expectEqual(@as(i64, 2), list.pair.cdr.pair.car.integer);
    try std.testing.expectEqual(Datum.empty_list, list.pair.cdr.pair.cdr);
}

test "empty list is not a pair" {
    const d: Datum = .empty_list;
    try std.testing.expect(d != .pair);
}

test "symbol bytes are copied, not aliased" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var buf = [_]u8{ 'f', 'o', 'o' };
    const s = try symbol(arena_state.allocator(), &buf);
    buf[0] = 'X';
    try std.testing.expectEqualStrings("foo", s.symbol);
}
