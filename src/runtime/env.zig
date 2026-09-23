//! Environment: chained lexical scopes mapping names to values. Lookup walks
//! toward the root; define always binds in the receiving scope (semantics §2:
//! v0 `define` is used only on the global environment, but closures will
//! create child scopes in plan 3.6).

const std = @import("std");
const value_mod = @import("value.zig");

const Value = value_mod.Value;

/// A hygienic rename introduced by a macro expansion (tier 8I.4): the alias
/// symbol resolves to `original` in the macro's definition scope `def_env`.
/// Keeps template-introduced identifiers referentially transparent and their
/// binders capture-free. `docs/syntax-rules.md`.
pub const AliasInfo = struct { original: []const u8, def_env: *Env };

pub const Env = struct {
    parent: ?*Env,
    bindings: std.StringHashMapUnmanaged(Value) = .empty,
    arena: std.mem.Allocator,
    /// Session-wide macro-rename table, shared by every env in the session
    /// (children inherit the parent's pointer).
    aliases: *std.StringHashMapUnmanaged(AliasInfo),

    pub fn init(arena: std.mem.Allocator, parent: ?*Env) std.mem.Allocator.Error!*Env {
        const aliases = if (parent) |p| p.aliases else blk: {
            const a = try arena.create(std.StringHashMapUnmanaged(AliasInfo));
            a.* = .empty;
            break :blk a;
        };
        const e = try arena.create(Env);
        e.* = .{ .parent = parent, .arena = arena, .aliases = aliases };
        return e;
    }

    /// Records `alias → (original, def_env)` (§8I.4). Names are copied.
    pub fn registerAlias(env: *Env, alias: []const u8, original: []const u8, def_env: *Env) std.mem.Allocator.Error!void {
        const gop = try env.aliases.getOrPut(env.arena, alias);
        if (!gop.found_existing) gop.key_ptr.* = try env.arena.dupe(u8, alias);
        gop.value_ptr.* = .{ .original = try env.arena.dupe(u8, original), .def_env = def_env };
    }

    /// The alias record for `name`, if it is a macro-introduced rename.
    pub fn aliasOf(env: *const Env, name: []const u8) ?AliasInfo {
        return env.aliases.get(name);
    }

    /// Binds `name` in this scope, copying the name. Rebinding replaces.
    pub fn define(env: *Env, name: []const u8, v: Value) std.mem.Allocator.Error!void {
        const gop = try env.bindings.getOrPut(env.arena, name);
        if (!gop.found_existing) gop.key_ptr.* = try env.arena.dupe(u8, name);
        gop.value_ptr.* = v;
    }

    /// Assigns the nearest binding of `name` (§2 set!); false if unbound.
    pub fn set(env: *Env, name: []const u8, v: Value) bool {
        var cur: ?*Env = env;
        while (cur) |c| : (cur = c.parent) {
            if (c.bindings.getPtr(name)) |slot| {
                slot.* = v;
                return true;
            }
        }
        return false;
    }

    pub fn lookup(env: *const Env, name: []const u8) ?Value {
        var cur: ?*const Env = env;
        while (cur) |c| : (cur = c.parent) {
            if (c.bindings.get(name)) |v| return v;
        }
        // Hygiene fallback (§8I.4): a macro-introduced alias with no lexical
        // binding resolves to its original name in the definition scope, so a
        // template's free references stay transparent (incl. forward refs,
        // resolved at use time).
        if (env.aliases.get(name)) |ai| return ai.def_env.lookup(ai.original);
        return null;
    }
};

// -- tests --------------------------------------------------------------

test "define and lookup" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const env = try Env.init(arena_state.allocator(), null);

    try std.testing.expectEqual(@as(?Value, null), env.lookup("x"));
    try env.define("x", .{ .integer = 1 });
    try std.testing.expectEqual(@as(i64, 1), env.lookup("x").?.integer);

    try env.define("x", .{ .integer = 2 }); // redefinition replaces (§2)
    try std.testing.expectEqual(@as(i64, 2), env.lookup("x").?.integer);
}

test "child scopes shadow and fall through" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const global = try Env.init(arena, null);
    try global.define("x", .{ .integer = 1 });
    try global.define("y", .{ .integer = 10 });

    const child = try Env.init(arena, global);
    try child.define("x", .{ .integer = 2 });

    try std.testing.expectEqual(@as(i64, 2), child.lookup("x").?.integer);
    try std.testing.expectEqual(@as(i64, 10), child.lookup("y").?.integer);
    try std.testing.expectEqual(@as(i64, 1), global.lookup("x").?.integer);
}

test "binding names are copied" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const env = try Env.init(arena_state.allocator(), null);

    var buf = [_]u8{ 'f', 'o', 'o' };
    try env.define(&buf, .{ .integer = 7 });
    buf[0] = 'X';
    try std.testing.expectEqual(@as(i64, 7), env.lookup("foo").?.integer);
}
