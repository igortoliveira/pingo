//! C ABI for embedding Pingo (Phase 10; design in docs/c-api.md). Values cross
//! the boundary as s-expression text — §4 already restricts the boundary to
//! pure data, and the printer/reader round-trip it losslessly (the property
//! record/replay relies on). The host protocol is blocked/resolve
//! (docs/host.md): feed a program, drive the capability loop with
//! `pingo_continue`, resolve outstanding calls by a stable token.
//!
//! Returned `const char*` strings are owned by the session and valid until the
//! next call on that session. A session is single-threaded: do not call into
//! one concurrently.

const std = @import("std");
const pingo = @import("root.zig");

const Machine = pingo.machine.Machine;
const Value = pingo.value.Value;
const Datum = pingo.datum.Datum;
const Capability = pingo.capability.Capability;

/// Mirrors `capability.EffectClass` for C callers. Kept in sync explicitly so
/// the ABI value is stable regardless of the Zig enum's layout.
pub const PINGO_PURE: c_int = 0;
pub const PINGO_INDEPENDENT: c_int = 1;
pub const PINGO_RESOURCE: c_int = 2;
pub const PINGO_ORDERED: c_int = 3;
pub const PINGO_IRREVERSIBLE: c_int = 4;

/// Result of `pingo_feed` / `pingo_continue`.
pub const PINGO_VALUE: c_int = 0; // the program finished; pingo_result() has the value
pub const PINGO_BLOCKED: c_int = 1; // capability calls are outstanding; resolve and continue
pub const PINGO_ERROR: c_int = 2; // evaluation failed; pingo_error() has the kind

const default_heap: usize = 256 * 1024 * 1024;
const max_depth: usize = 1024;

fn classFromInt(c: c_int) ?pingo.capability.EffectClass {
    return switch (c) {
        PINGO_PURE => .pure,
        PINGO_INDEPENDENT => .external_independent,
        PINGO_RESOURCE => .resource_ordered,
        PINGO_ORDERED => .globally_ordered,
        PINGO_IRREVERSIBLE => .irreversible,
        else => null,
    };
}

/// A capability handler is never invoked under the blocked/resolve protocol —
/// the machine suspends and the C host resolves — but a valid pointer is
/// required. Signalling here would be a bug.
fn stubHandler(_: *anyopaque, _: std.mem.Allocator, _: []const Value) pingo.capability.HostError!Value {
    return error.HostError;
}

const Session = struct {
    arena_state: std.heap.ArenaAllocator,
    heap: pingo.limits.LimitedAllocator,
    machine: Machine,

    reader: ?pingo.reader.Reader = null,
    state: enum { reading, awaiting } = .reading,
    status: c_int = PINGO_VALUE,
    last: Value = .unspecified,
    err_kind: []const u8 = "",

    // Session-owned scratch for returned C strings (valid until the next call).
    out: std.ArrayList(u8) = .empty,

    fn arena(s: *Session) std.mem.Allocator {
        return s.heap.allocator();
    }

    /// Renders `bytes` as a NUL-terminated C string in the scratch buffer.
    fn cstr(s: *Session, bytes: []const u8) [*:0]const u8 {
        s.out.clearRetainingCapacity();
        const a = s.arena();
        s.out.appendSlice(a, bytes) catch return "";
        s.out.append(a, 0) catch return "";
        return @ptrCast(s.out.items.ptr);
    }

    fn cprint(s: *Session, v: Value) [*:0]const u8 {
        var buf = std.Io.Writer.Allocating.init(s.arena());
        defer buf.deinit();
        pingo.printer.writeValue(v, &buf.writer) catch return "";
        return s.cstr(buf.written());
    }

    /// Drives forms until the program finishes, blocks, or errors.
    fn drive(s: *Session) c_int {
        while (true) {
            const outcome = if (s.state == .awaiting)
                s.machine.continueRun()
            else blk: {
                const d = (s.reader.?.read() catch |err| {
                    s.err_kind = @errorName(err);
                    s.machine.diagnostic = .{ .context = "read" };
                    s.status = PINGO_ERROR;
                    return PINGO_ERROR;
                }) orelse {
                    s.status = PINGO_VALUE;
                    return PINGO_VALUE; // EOF: last value stands
                };
                break :blk s.machine.evalToplevel(d);
            };
            const oc = outcome catch |err| {
                s.err_kind = pingo.eval.kindOf(err);
                s.status = PINGO_ERROR;
                return PINGO_ERROR;
            };
            switch (oc) {
                .blocked => {
                    s.state = .awaiting;
                    s.status = PINGO_BLOCKED;
                    return PINGO_BLOCKED;
                },
                .value => |v| {
                    s.last = v;
                    s.state = .reading; // advance to the next form
                },
            }
        }
    }

    fn pendingFromToken(s: *Session, token: u64) ?*pingo.machine.Pending {
        for (s.machine.outstanding()) |p|
            if (@intFromPtr(p) == token) return p;
        return null;
    }
};

/// Creates a session. `fuel`/`call_depth`/`heap_bytes` are the §5 limits; pass
/// 0 for heap_bytes to use the default. Returns null on allocation failure.
export fn pingo_new(fuel: u64, call_depth: usize, heap_bytes: usize) ?*Session {
    const s = std.heap.page_allocator.create(Session) catch return null;
    s.* = .{
        .arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .heap = undefined,
        .machine = undefined,
    };
    s.heap = pingo.limits.LimitedAllocator.init(s.arena_state.allocator(), if (heap_bytes == 0) default_heap else heap_bytes);
    s.machine = Machine.init(s.arena(), .{ .fuel = fuel, .call_depth = call_depth }) catch {
        s.arena_state.deinit();
        std.heap.page_allocator.destroy(s);
        return null;
    };
    return s;
}

export fn pingo_free(s: ?*Session) void {
    const sess = s orelse return;
    sess.arena_state.deinit();
    std.heap.page_allocator.destroy(sess);
}

/// Registers a capability the guest can call. `name` is NUL-terminated; `class`
/// is one of the PINGO_* class constants. Returns 0 on success, -1 on error.
export fn pingo_register(s: ?*Session, name: [*:0]const u8, class: c_int) c_int {
    const sess = s orelse return -1;
    const cls = classFromInt(class) orelse return -1;
    const a = sess.arena();
    const cap = a.create(Capability) catch return -1;
    cap.* = .{
        .name = a.dupe(u8, std.mem.span(name)) catch return -1,
        .class = cls,
        .ctx = sess,
        .handler = stubHandler,
    };
    pingo.capability.register(sess.machine.global, cap) catch return -1;
    return 0;
}

/// Feeds a program (`src`, NUL-terminated) and drives it to the first stop.
/// Returns a PINGO_* status.
export fn pingo_feed(s: ?*Session, src: [*:0]const u8) c_int {
    const sess = s orelse return PINGO_ERROR;
    const copy = sess.arena().dupe(u8, std.mem.span(src)) catch return PINGO_ERROR;
    sess.reader = pingo.reader.Reader.init(sess.arena(), copy, max_depth);
    sess.state = .reading;
    sess.last = .unspecified;
    return sess.drive();
}

/// Resumes after resolving outstanding calls. Returns a PINGO_* status.
export fn pingo_continue(s: ?*Session) c_int {
    const sess = s orelse return PINGO_ERROR;
    return sess.drive();
}

/// The finished program's value as re-readable s-expression text (valid until
/// the next call). Empty for a non-VALUE status.
export fn pingo_result(s: ?*Session) [*:0]const u8 {
    const sess = s orelse return "";
    if (sess.status != PINGO_VALUE) return "";
    return sess.cprint(sess.last);
}

/// The error kind (and context, if any) for a PINGO_ERROR status (valid until
/// the next call).
export fn pingo_error(s: ?*Session) [*:0]const u8 {
    const sess = s orelse return "";
    if (sess.status != PINGO_ERROR) return "";
    if (sess.machine.diagnostic) |d| {
        var buf = std.Io.Writer.Allocating.init(sess.arena());
        defer buf.deinit();
        buf.writer.print("{s} ({s})", .{ sess.err_kind, d.context }) catch return sess.cstr(sess.err_kind);
        return sess.cstr(buf.written());
    }
    return sess.cstr(sess.err_kind);
}

/// Number of capability calls currently outstanding (only meaningful after a
/// PINGO_BLOCKED status).
export fn pingo_outstanding_count(s: ?*Session) usize {
    const sess = s orelse return 0;
    return sess.machine.outstanding().len;
}

/// A stable token identifying the i-th outstanding call (0-based). Use it with
/// `pingo_resolve`/`pingo_resolve_failure`; it stays valid until that call is
/// resolved.
export fn pingo_call_token(s: ?*Session, i: usize) u64 {
    const sess = s orelse return 0;
    const calls = sess.machine.outstanding();
    if (i >= calls.len) return 0;
    return @intFromPtr(calls[i]);
}

/// The capability name of an outstanding call, by token (valid until the next call).
export fn pingo_call_name(s: ?*Session, token: u64) [*:0]const u8 {
    const sess = s orelse return "";
    const p = sess.pendingFromToken(token) orelse return "";
    return sess.cstr(p.capability.name);
}

/// The arguments of an outstanding call as an s-expression list (valid until
/// the next call).
export fn pingo_call_args(s: ?*Session, token: u64) [*:0]const u8 {
    const sess = s orelse return "";
    const p = sess.pendingFromToken(token) orelse return "";
    var buf = std.Io.Writer.Allocating.init(sess.arena());
    defer buf.deinit();
    buf.writer.writeByte('(') catch return "";
    for (p.args, 0..) |arg, i| {
        if (i > 0) buf.writer.writeByte(' ') catch return "";
        pingo.printer.writeValue(arg, &buf.writer) catch return "";
    }
    buf.writer.writeByte(')') catch return "";
    return sess.cstr(buf.written());
}

/// Resolves an outstanding call with `result_src` (NUL-terminated s-expression,
/// must be pure data). Returns 0 on success, -1 on a bad token or parse error.
export fn pingo_resolve(s: ?*Session, token: u64, result_src: [*:0]const u8) c_int {
    const sess = s orelse return -1;
    const p = sess.pendingFromToken(token) orelse return -1;
    var r = pingo.reader.Reader.init(sess.arena(), std.mem.span(result_src), max_depth);
    const d = (r.read() catch return -1) orelse return -1;
    const v = pingo.value.fromDatum(sess.arena(), d) catch return -1;
    sess.machine.resolve(p, v);
    return 0;
}

/// Resolves an outstanding call as a failure (surfaces as host-error).
export fn pingo_resolve_failure(s: ?*Session, token: u64) c_int {
    const sess = s orelse return -1;
    const p = sess.pendingFromToken(token) orelse return -1;
    sess.machine.resolveFailure(p);
    return 0;
}

// -- synchronous convenience layer ----------------------------------------
//
// Matches the ergonomics of handle-based Schemes (Chibi's sexp_define_foreign
// + sexp_eval_string, s7_define_function + s7_eval_c_string) but without their
// GC-rooting burden, since only pure-data text crosses the boundary (§4).

/// A C capability handler: receives the call's arguments as an s-expression
/// list, returns the result as an s-expression (pure data), or NULL to signal
/// a host failure (surfaces as host-error). The returned string need only be
/// valid until the handler returns.
pub const PingoHandler = *const fn (user: ?*anyopaque, args: [*:0]const u8) callconv(.c) ?[*:0]const u8;

/// Bridges a registered C handler to the machine's capability handler. Runs
/// synchronously under `runToCompletion` (never in the blocked/resolve path).
const CFnCap = struct {
    handler: PingoHandler,
    user: ?*anyopaque,

    fn bridge(ctx: *anyopaque, arena: std.mem.Allocator, args: []const Value) pingo.capability.HostError!Value {
        const cc: *CFnCap = @ptrCast(@alignCast(ctx));
        var buf = std.Io.Writer.Allocating.init(arena);
        defer buf.deinit();
        buf.writer.writeByte('(') catch return error.OutOfMemory;
        for (args, 0..) |arg, i| {
            if (i > 0) buf.writer.writeByte(' ') catch return error.OutOfMemory;
            pingo.printer.writeValue(arg, &buf.writer) catch return error.OutOfMemory;
        }
        buf.writer.writeByte(')') catch return error.OutOfMemory;
        buf.writer.writeByte(0) catch return error.OutOfMemory;
        const args_c: [*:0]const u8 = @ptrCast(buf.written().ptr);

        const res = cc.handler(cc.user, args_c) orelse return error.HostError;
        var r = pingo.reader.Reader.init(arena, std.mem.span(res), max_depth);
        const d = (r.read() catch return error.HostError) orelse return error.HostError;
        return pingo.value.fromDatum(arena, d) catch return error.HostError;
    }
};

/// Registers a capability backed by a synchronous C handler. Use with
/// `pingo_eval`. Returns 0 on success, -1 on error.
export fn pingo_register_fn(s: ?*Session, name: [*:0]const u8, class: c_int, handler: PingoHandler, user: ?*anyopaque) c_int {
    const sess = s orelse return -1;
    const cls = classFromInt(class) orelse return -1;
    const a = sess.arena();
    const cc = a.create(CFnCap) catch return -1;
    cc.* = .{ .handler = handler, .user = user };
    const cap = a.create(Capability) catch return -1;
    cap.* = .{
        .name = a.dupe(u8, std.mem.span(name)) catch return -1,
        .class = cls,
        .ctx = cc,
        .handler = CFnCap.bridge,
    };
    pingo.capability.register(sess.machine.global, cap) catch return -1;
    return 0;
}

/// Evaluates a program (`src`) to completion, servicing capability calls
/// through their registered C handlers (see `pingo_register_fn`). Returns the
/// last form's value as s-expression text (valid until the next call), or NULL
/// on error — then `pingo_error` has the kind.
export fn pingo_eval(s: ?*Session, src: [*:0]const u8) ?[*:0]const u8 {
    const sess = s orelse return null;
    const copy = sess.arena().dupe(u8, std.mem.span(src)) catch return null;
    var r = pingo.reader.Reader.init(sess.arena(), copy, max_depth);
    var last: Value = .unspecified;
    while (true) {
        const d = (r.read() catch |err| {
            sess.err_kind = @errorName(err);
            sess.machine.diagnostic = .{ .context = "read" };
            sess.status = PINGO_ERROR;
            return null;
        }) orelse break;
        last = sess.machine.runToCompletion(d) catch |err| {
            sess.err_kind = pingo.eval.kindOf(err);
            sess.status = PINGO_ERROR;
            return null;
        };
    }
    sess.status = PINGO_VALUE;
    sess.last = last;
    return sess.cprint(last);
}

/// The library version string.
export fn pingo_version() [*:0]const u8 {
    return pingo.version;
}

// -- tests ----------------------------------------------------------------

test "capi: pure program feeds to a value" {
    const s = pingo_new(1_000_000, 500, 0).?;
    defer pingo_free(s);
    try std.testing.expectEqual(PINGO_VALUE, pingo_feed(s, "(+ 1 2 3)"));
    try std.testing.expectEqualStrings("6", std.mem.span(pingo_result(s)));
}

test "capi: capability round-trip via blocked/resolve" {
    const s = pingo_new(1_000_000, 500, 0).?;
    defer pingo_free(s);
    try std.testing.expectEqual(@as(c_int, 0), pingo_register(s, "ask", PINGO_INDEPENDENT));

    // (+ 1 (ask 41)) blocks on ask, resolves to 41, yields 42
    try std.testing.expectEqual(PINGO_BLOCKED, pingo_feed(s, "(+ 1 (ask 41))"));
    try std.testing.expectEqual(@as(usize, 1), pingo_outstanding_count(s));
    const tok = pingo_call_token(s, 0);
    try std.testing.expectEqualStrings("ask", std.mem.span(pingo_call_name(s, tok)));
    try std.testing.expectEqualStrings("(41)", std.mem.span(pingo_call_args(s, tok)));
    try std.testing.expectEqual(@as(c_int, 0), pingo_resolve(s, tok, "41"));
    try std.testing.expectEqual(PINGO_VALUE, pingo_continue(s));
    try std.testing.expectEqualStrings("42", std.mem.span(pingo_result(s)));
}

fn testDouble(_: ?*anyopaque, args: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    // args is "(n)"; return "2n" without parsing — the corpus only calls (dbl 21)
    _ = args;
    return "42";
}

test "capi: synchronous eval with a C handler" {
    const s = pingo_new(1_000_000, 500, 0).?;
    defer pingo_free(s);
    try std.testing.expectEqual(@as(c_int, 0), pingo_register_fn(s, "dbl", PINGO_INDEPENDENT, testDouble, null));
    const res = pingo_eval(s, "(+ 0 (dbl 21))") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("42", std.mem.span(res));
}

test "capi: synchronous eval surfaces errors as NULL" {
    const s = pingo_new(1_000_000, 500, 0).?;
    defer pingo_free(s);
    try std.testing.expectEqual(@as(?[*:0]const u8, null), pingo_eval(s, "(car '())"));
    try std.testing.expectEqual(PINGO_ERROR, s.status);
}

test "capi: multi-form program and error status" {
    const s = pingo_new(1_000_000, 500, 0).?;
    defer pingo_free(s);
    try std.testing.expectEqual(PINGO_VALUE, pingo_feed(s, "(define x 10) (* x x)"));
    try std.testing.expectEqualStrings("100", std.mem.span(pingo_result(s)));
    try std.testing.expectEqual(PINGO_ERROR, pingo_feed(s, "(car '())"));
}
