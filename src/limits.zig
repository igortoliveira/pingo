//! LimitedAllocator: a byte-budgeted allocator wrapper (semantics §5,
//! `heap_bytes`). The host wraps the session arena with it; when the guest's
//! live allocations would exceed the budget, allocation fails and the
//! evaluator surfaces it as `limit-exceeded` (see `eval.kindOf`).

const std = @import("std");
const Alignment = std.mem.Alignment;

pub const LimitedAllocator = struct {
    child: std.mem.Allocator,
    budget: usize,
    used: usize = 0,

    pub fn init(child: std.mem.Allocator, budget: usize) LimitedAllocator {
        return .{ .child = child, .budget = budget };
    }

    pub fn allocator(l: *LimitedAllocator) std.mem.Allocator {
        return .{ .ptr = l, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const l: *LimitedAllocator = @ptrCast(@alignCast(ctx));
        if (len > l.budget - l.used) return null;
        const p = l.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        l.used += len;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const l: *LimitedAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and new_len - memory.len > l.budget - l.used) return false;
        if (!l.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        l.charge(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const l: *LimitedAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and new_len - memory.len > l.budget - l.used) return null;
        const p = l.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        l.charge(memory.len, new_len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const l: *LimitedAllocator = @ptrCast(@alignCast(ctx));
        l.child.rawFree(memory, alignment, ret_addr);
        l.used -= memory.len;
    }

    fn charge(l: *LimitedAllocator, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) l.used += new_len - old_len else l.used -= old_len - new_len;
    }
};

// -- tests --------------------------------------------------------------

test "budget is enforced and freed bytes come back" {
    var l = LimitedAllocator.init(std.testing.allocator, 100);
    const a = l.allocator();

    const first = try a.alloc(u8, 60);
    try std.testing.expectEqual(@as(usize, 60), l.used);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 41));

    a.free(first);
    try std.testing.expectEqual(@as(usize, 0), l.used);
    const second = try a.alloc(u8, 100); // exactly the budget is fine
    a.free(second);
}

test "accounting follows realloc" {
    var l = LimitedAllocator.init(std.testing.allocator, 100);
    const a = l.allocator();

    var buf = try a.alloc(u8, 60);
    buf = try a.realloc(buf, 30); // shrink: 30 stays charged, whatever the path
    try std.testing.expectEqual(@as(usize, 30), l.used);
    buf = try a.realloc(buf, 70); // grow: in place or copy, ends charged at 70
    try std.testing.expectEqual(@as(usize, 70), l.used);
    // Whether a grow-realloc beyond budget fails depends on the copy path, so
    // assert the deterministic case instead: a fresh alloc over the remainder.
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 31));
    a.free(buf);
    try std.testing.expectEqual(@as(usize, 0), l.used);
}
