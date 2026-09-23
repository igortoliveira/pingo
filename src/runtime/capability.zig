//! Host capabilities (semantics §4): the only bridge between guest and world.
//! Without a registered capability the operation cannot even be expressed —
//! there is no ambient authority anywhere in the VM.

const std = @import("std");
const value_mod = @import("value.zig");
const env_mod = @import("env.zig");

const Value = value_mod.Value;

/// §4 effect classes. Registered from day one so the contract is stable;
/// the v0 sequential runtime treats every class as `globally_ordered`.
pub const EffectClass = enum {
    pure,
    external_independent,
    resource_ordered, // per-resource ordering via the resource-key projection (§18)
    globally_ordered,
    irreversible,
};

/// §18 how a `resource_ordered` capability's calls commute on the *same* key.
/// Anything other than `non_commutative` lets same-capability, same-key calls
/// overlap (they need not keep dispatch order among themselves).
pub const Commutativity = enum {
    non_commutative,
    read_only,
    commutative_monoid,
    idempotent,
};

/// What a handler may signal. `HostError` surfaces to the guest as the
/// `host-error` kind (§3); OutOfMemory follows the usual limit path.
pub const HostError = error{ HostError, OutOfMemory };

pub const Handler = *const fn (
    ctx: *anyopaque,
    arena: std.mem.Allocator,
    args: []const Value,
) HostError!Value;

/// §18 resource projection: maps a `resource_ordered` call's arguments to a
/// canonical resource key. Two such calls conflict (keep dispatch order) iff
/// their keys are equal; distinct keys are independent and may overlap.
/// Returning null means "no specific resource → treat as global" (the safe,
/// conservative default). Must be pure/idempotent: a drain barrier may call it
/// more than once for the same call while it retries.
pub const ResourceFn = *const fn (
    ctx: *anyopaque,
    arena: std.mem.Allocator,
    args: []const Value,
) std.mem.Allocator.Error!?[]const u8;

/// Host-owned; must outlive the session it is registered into.
pub const Capability = struct {
    name: []const u8,
    class: EffectClass,
    ctx: *anyopaque,
    handler: Handler,
    /// §18 resource key projection (only consulted for `resource_ordered`).
    /// Null → the class falls back to global ordering (the safe default).
    resource: ?ResourceFn = null,
    /// §18 commutativity of this capability's calls on the same resource key.
    /// Default `non_commutative` (same-key calls keep order — the safe default).
    commutativity: Commutativity = .non_commutative,
};

/// Makes the capability visible to the guest as a callable value.
pub fn register(scope: *env_mod.Env, cap: *const Capability) std.mem.Allocator.Error!void {
    try scope.define(cap.name, .{ .capability = cap });
}

// -- tests --------------------------------------------------------------

fn nopHandler(_: *anyopaque, _: std.mem.Allocator, _: []const Value) HostError!Value {
    return .unspecified;
}

test "registration makes the capability a first-class guest value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const scope = try env_mod.Env.init(arena_state.allocator(), null);

    var dummy: u8 = 0;
    const cap = Capability{
        .name = "read-file",
        .class = .external_independent,
        .ctx = &dummy,
        .handler = nopHandler,
    };
    try register(scope, &cap);

    const v = scope.lookup("read-file").?;
    try std.testing.expect(v == .capability);
    try std.testing.expectEqual(&cap, v.capability);
    try std.testing.expectEqual(EffectClass.external_independent, v.capability.class);
}
