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
    resource_ordered, // resource-key modeling arrives with resource effects
    globally_ordered,
    irreversible,
};

/// What a handler may signal. `HostError` surfaces to the guest as the
/// `host-error` kind (§3); OutOfMemory follows the usual limit path.
pub const HostError = error{ HostError, OutOfMemory };

pub const Handler = *const fn (
    ctx: *anyopaque,
    arena: std.mem.Allocator,
    args: []const Value,
) HostError!Value;

/// Host-owned; must outlive the session it is registered into.
pub const Capability = struct {
    name: []const u8,
    class: EffectClass,
    ctx: *anyopaque,
    handler: Handler,
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
