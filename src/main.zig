const std = @import("std");
const pingo = @import("pingo");
const xev = @import("xev");

const max_line_bytes = 4096;
const max_read_depth = 64;
const max_file_bytes = 16 * 1024 * 1024;

// The CLI is the host here (§5): limits and capabilities are its choices.
const repl_limits: pingo.machine.Limits = .{ .fuel = 10_000_000, .call_depth = 1_000 };
const repl_heap_bytes = 256 * 1024 * 1024; // per session (the v0 arena never frees)

/// `(print v ...)` writes through the host's stdout. The guest has no I/O of
/// its own (§4) — effects only exist where the host grants them.
const PrintHost = struct {
    out: *std.Io.Writer,

    fn print(ctx: *anyopaque, _: std.mem.Allocator, args: []const pingo.value.Value) pingo.capability.HostError!pingo.value.Value {
        const h: *PrintHost = @ptrCast(@alignCast(ctx));
        for (args, 0..) |a, i| {
            if (i > 0) h.out.writeByte(' ') catch return error.HostError;
            pingo.printer.writeValue(a, h.out) catch return error.HostError;
        }
        h.out.writeByte('\n') catch return error.HostError;
        return .unspecified;
    }
};

/// A stub capability with a declared class and virtual latency (§4 host
/// side): its result is "<name>-result", and the runner's virtual clock
/// decides when it completes. This is how lambda-O behavior is tested from
/// pure Scheme: the trace shows dispatch overlap, the report shows the
/// achieved speedup over a blocking host.
const SimTool = struct {
    cap: pingo.capability.Capability,
    latency_ms: u64,

    fn handle(ctx: *anyopaque, arena: std.mem.Allocator, _: []const pingo.value.Value) pingo.capability.HostError!pingo.value.Value {
        const tool: *SimTool = @ptrCast(@alignCast(ctx));
        const text = std.fmt.allocPrint(arena, "{s}-result", .{tool.cap.name}) catch
            return error.OutOfMemory;
        return .{ .string = text };
    }
};

fn parseTool(spec: []const u8) ?SimTool {
    var parts = std.mem.splitScalar(u8, spec, ':');
    const name = parts.next() orelse return null;
    if (name.len == 0) return null;
    const class_name = parts.next() orelse "independent";
    const class = pingo.trace.classFromSpelling(class_name) orelse return null;
    const latency: u64 = if (parts.next()) |l| std.fmt.parseInt(u64, l, 10) catch return null else 100;
    return .{
        .cap = .{ .name = name, .class = class, .ctx = undefined, .handler = SimTool.handle },
        .latency_ms = latency,
    };
}

/// Serves recorded results (docs/host.md): FIFO per (name, args) key via the
/// replay table; an exhausted or unrecorded key is a host-error. No real
/// handler runs on replay.
const ReplayTool = struct {
    cap: pingo.capability.Capability,
    latency_ms: u64,
    replay: *pingo.trace.Replay,

    fn handle(ctx: *anyopaque, arena: std.mem.Allocator, args: []const pingo.value.Value) pingo.capability.HostError!pingo.value.Value {
        const tool: *ReplayTool = @ptrCast(@alignCast(ctx));
        const served = (try tool.replay.next(arena, tool.cap.name, args)) orelse return error.HostError;
        return switch (served) {
            .ok => |v| v,
            .failure => error.HostError,
        };
    }
};

const usage =
    \\usage: pingo [file.scm] [--tool name[:class[:latency_ms]]]... [--trace] [--record file] [--replay file]
    \\  classes: pure | independent | resource | ordered | irreversible
    \\  --replay reconstructs the tools from the trace; it excludes --tool
    \\
;

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const arena0 = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena0);
    var file_path: ?[]const u8 = null;
    var tools: std.ArrayList(SimTool) = .empty;
    var trace = false;
    var async_mode = false;
    var record_path: ?[]const u8 = null;
    var replay_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--trace")) {
            trace = true;
        } else if (std.mem.eql(u8, args[i], "--async")) {
            async_mode = true;
        } else if (std.mem.eql(u8, args[i], "--record")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll(usage);
                try out.flush();
                return;
            }
            record_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--replay")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll(usage);
                try out.flush();
                return;
            }
            replay_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--tool")) {
            i += 1;
            const tool = if (i < args.len) parseTool(args[i]) else null;
            if (tool) |t| {
                try tools.append(arena0, t);
            } else {
                try out.writeAll(usage);
                try out.flush();
                return;
            }
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            try out.print("unknown option: {s}\n{s}", .{ args[i], usage });
            try out.flush();
            return;
        } else {
            file_path = args[i];
        }
    }

    if (replay_path != null and tools.items.len > 0) {
        try out.writeAll(usage);
        try out.flush();
        return;
    }
    if (async_mode and (record_path != null or replay_path != null)) {
        try out.writeAll("--async cannot be combined with --record/--replay\n");
        try out.flush();
        return;
    }
    if (async_mode) {
        if (file_path) |path| return runFileAsync(init, out, path, tools.items, trace);
        try out.writeAll(usage);
        try out.flush();
        return;
    }
    if (file_path) |path| return runFile(init, out, path, tools.items, trace, record_path, replay_path);
    return repl(init, out);
}

/// File mode: evaluate every form; the first error aborts with exit code 1.
/// Simulated tools complete on a virtual clock — the call with the earliest
/// completion settles first — so the trace and the final report show real
/// dispatch overlap without any real waiting.
fn runFile(init: std.process.Init, out: *std.Io.Writer, path: []const u8, tools: []SimTool, trace: bool, record_path: ?[]const u8, replay_path: ?[]const u8) !void {
    var session_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer session_arena_state.deinit();
    var session_heap = pingo.limits.LimitedAllocator.init(session_arena_state.allocator(), repl_heap_bytes);
    const session_arena = session_heap.allocator();

    var machine = try pingo.machine.Machine.init(session_arena, repl_limits);
    var print_host = PrintHost{ .out = out };
    const print_cap = pingo.capability.Capability{
        .name = "print",
        .class = .globally_ordered,
        .ctx = &print_host,
        .handler = PrintHost.print,
    };
    try pingo.capability.register(machine.global, &print_cap);
    for (tools) |*tool| {
        tool.cap.ctx = tool; // final address: safe to register now
        try pingo.capability.register(machine.global, &tool.cap);
    }

    // Replay reconstructs the tools from the trace headers (docs/host.md):
    // no --tool flags, no real handlers, results served from the table.
    var replay_storage: pingo.trace.Replay = undefined;
    var replay_tools: []ReplayTool = &.{};
    if (replay_path) |rp| {
        const trace_src = try readWholeFile(init, out, rp, session_arena);
        replay_storage = pingo.trace.parse(session_arena, trace_src) catch |err| {
            try out.print("invalid trace {s}: {s}\n", .{ rp, @errorName(err) });
            try out.flush();
            std.process.exit(1);
        };
        replay_tools = try session_arena.alloc(ReplayTool, replay_storage.tools.len);
        for (replay_storage.tools, replay_tools) |spec, *rt| {
            rt.* = .{
                .cap = .{ .name = spec.name, .class = spec.class, .ctx = undefined, .handler = ReplayTool.handle },
                .latency_ms = spec.latency_ms,
                .replay = &replay_storage,
            };
            rt.cap.ctx = rt;
            try pingo.capability.register(machine.global, &rt.cap);
        }
    }

    // Recording taps the settle funnel (docs/host.md): headers now, one
    // `(call ...)` line per settle below.
    var record_buffer: [4096]u8 = undefined;
    var record_writer: ?std.Io.File.Writer = null;
    if (record_path) |rp| {
        const f = std.Io.Dir.cwd().createFile(init.io, rp, .{}) catch |err| {
            try out.print("cannot create {s}: {s}\n", .{ rp, @errorName(err) });
            try out.flush();
            std.process.exit(1);
        };
        record_writer = .init(f, init.io, &record_buffer);
        for (tools) |*tool|
            try pingo.trace.writeTool(&record_writer.?.interface, tool.cap.name, tool.cap.class, tool.latency_ms);
        for (replay_tools) |*tool|
            try pingo.trace.writeTool(&record_writer.?.interface, tool.cap.name, tool.cap.class, tool.latency_ms);
    }
    defer if (record_writer) |*rw| rw.file.close(init.io);

    const src = try readWholeFile(init, out, path, session_arena);
    var reader = pingo.reader.Reader.init(session_arena, src, max_read_depth);

    // virtual clock state
    var clock: u64 = 0;
    var seq_sum: u64 = 0;
    const InFlight = struct { p: *pingo.machine.Pending, done_at: u64 };
    var in_flight: std.ArrayList(InFlight) = .empty;

    var last: pingo.value.Value = .unspecified;
    var failed = false;
    read_loop: while (true) {
        const d = reader.read() catch |err| {
            try out.print("read error: {s}\n", .{@errorName(err)});
            try out.flush();
            std.process.exit(1);
        } orelse break;

        var outcome = machine.evalToplevel(d) catch |err| {
            try reportError(out, &machine, err);
            failed = true;
            break :read_loop;
        };
        while (outcome == .blocked) {
            // record calls that entered flight since the last block
            for (machine.outstanding()) |p| {
                var known = false;
                for (in_flight.items) |f| known = known or f.p == p;
                if (known) continue;
                const latency = latencyOf(tools, replay_tools, p.capability);
                seq_sum += latency;
                try in_flight.append(session_arena, .{ .p = p, .done_at = clock + latency });
                if (trace) {
                    try out.print("[t={d:>5}ms] dispatch {s}", .{ clock, p.capability.name });
                    try writeArgs(out, p.args);
                    try out.writeByte('\n');
                }
            }
            // settle whichever completes earliest in virtual time
            var best: usize = 0;
            for (in_flight.items, 0..) |f, k|
                if (f.done_at < in_flight.items[best].done_at) {
                    best = k;
                };
            const chosen = in_flight.swapRemove(best);
            clock = @max(clock, chosen.done_at);
            const cap = chosen.p.capability;
            if (cap.handler(cap.ctx, session_arena, chosen.p.args)) |result| {
                if (trace) {
                    try out.print("[t={d:>5}ms] settle   {s} -> ", .{ clock, cap.name });
                    try pingo.printer.writeValue(result, out);
                    try out.writeByte('\n');
                }
                if (record_writer) |*rw|
                    try pingo.trace.writeCall(&rw.interface, cap.name, chosen.p.args, result);
                machine.resolve(chosen.p, result);
            } else |err| switch (err) {
                error.HostError => {
                    if (trace) try out.print("[t={d:>5}ms] settle   {s} -> FAILED\n", .{ clock, cap.name });
                    if (record_writer) |*rw|
                        try pingo.trace.writeCall(&rw.interface, cap.name, chosen.p.args, null);
                    machine.resolveFailure(chosen.p);
                },
                error.OutOfMemory => return error.OutOfMemory,
            }
            outcome = machine.continueRun() catch |err| {
                try reportError(out, &machine, err);
                failed = true;
                break :read_loop;
            };
        }
        last = outcome.value;
    }

    if (!failed and last != .unspecified) {
        try pingo.printer.writeValue(last, out);
        try out.writeByte('\n');
    }
    if (seq_sum > 0) {
        const speedup = if (clock > 0)
            @as(f64, @floatFromInt(seq_sum)) / @as(f64, @floatFromInt(clock))
        else
            1.0;
        try out.print("virtual time: {d}ms | sequential sum: {d}ms | speedup: {d:.2}x\n", .{ clock, seq_sum, speedup });
    }
    if (record_writer) |*rw| try rw.interface.flush();
    try out.flush();
    if (failed) std.process.exit(1);
}

fn latencyOf(tools: []const SimTool, replay_tools: []const ReplayTool, cap: *const pingo.capability.Capability) u64 {
    for (tools) |*tool| if (&tool.cap == cap) return tool.latency_ms;
    for (replay_tools) |*tool| if (&tool.cap == cap) return tool.latency_ms;
    return 0; // e.g. print
}

/// Native async host (docs/host.md): the real completion source is a libxev
/// event loop. Each simulated tool call arms an `xev.Timer` for its latency in
/// **wall-clock** time; a batch of independent calls arms concurrent timers, so
/// the run finishes in about the slowest latency, not their sum — real overlap,
/// on kqueue/io_uring, from plain sequential Scheme. This is the adapter the
/// design doc names; the machine (sans-I/O) is unchanged.
const AsyncHost = struct {
    machine: *pingo.machine.Machine,
    tools: []SimTool,
    out: *std.Io.Writer,
    trace: bool,
    arena: std.mem.Allocator,
    io: std.Io,
    start_ns: i96,
    seq_sum: u64 = 0,

    fn elapsedMs(h: *const AsyncHost) u64 {
        const now = std.Io.Clock.now(.awake, h.io).nanoseconds;
        const d = now - h.start_ns;
        return if (d <= 0) 0 else @intCast(@divTrunc(d, std.time.ns_per_ms));
    }

    const Call = struct {
        host: *AsyncHost,
        pending: *pingo.machine.Pending,
        timer: xev.Timer,
        completion: xev.Completion = undefined,
    };

    fn dispatch(h: *AsyncHost, loop: *xev.Loop, p: *pingo.machine.Pending) !void {
        const latency = latencyOf(h.tools, &[_]ReplayTool{}, p.capability);
        h.seq_sum += latency;
        if (h.trace) {
            h.out.print("[t={d:>5}ms] dispatch {s}", .{ h.elapsedMs(), p.capability.name }) catch {};
            writeArgs(h.out, p.args) catch {};
            h.out.writeByte('\n') catch {};
        }
        const call = try h.arena.create(Call);
        call.* = .{ .host = h, .pending = p, .timer = try xev.Timer.init() };
        call.timer.run(loop, &call.completion, latency, Call, call, onTimer);
    }

    fn onTimer(ud: ?*Call, _: *xev.Loop, _: *xev.Completion, r: xev.Timer.RunError!void) xev.CallbackAction {
        const call = ud.?;
        const h = call.host;
        _ = r catch {};
        const cap = call.pending.capability;
        if (cap.handler(cap.ctx, h.arena, call.pending.args)) |result| {
            if (h.trace) {
                h.out.print("[t={d:>5}ms] settle   {s} -> ", .{ h.elapsedMs(), cap.name }) catch {};
                pingo.printer.writeValue(result, h.out) catch {};
                h.out.writeByte('\n') catch {};
            }
            h.machine.resolve(call.pending, result);
        } else |_| {
            if (h.trace) h.out.print("[t={d:>5}ms] settle   {s} -> FAILED\n", .{ h.elapsedMs(), cap.name }) catch {};
            h.machine.resolveFailure(call.pending);
        }
        return .disarm;
    }
};

fn runFileAsync(init: std.process.Init, out: *std.Io.Writer, path: []const u8, tools: []SimTool, trace: bool) !void {
    var session_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer session_arena_state.deinit();
    var session_heap = pingo.limits.LimitedAllocator.init(session_arena_state.allocator(), repl_heap_bytes);
    const session_arena = session_heap.allocator();

    var machine = try pingo.machine.Machine.init(session_arena, repl_limits);
    var print_host = PrintHost{ .out = out };
    const print_cap = pingo.capability.Capability{
        .name = "print",
        .class = .globally_ordered,
        .ctx = &print_host,
        .handler = PrintHost.print,
    };
    try pingo.capability.register(machine.global, &print_cap);
    for (tools) |*tool| {
        tool.cap.ctx = tool;
        try pingo.capability.register(machine.global, &tool.cap);
    }

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var host = AsyncHost{
        .machine = &machine,
        .tools = tools,
        .out = out,
        .trace = trace,
        .arena = session_arena,
        .io = init.io,
        .start_ns = std.Io.Clock.now(.awake, init.io).nanoseconds,
    };

    const src = try readWholeFile(init, out, path, session_arena);
    var reader = pingo.reader.Reader.init(session_arena, src, max_read_depth);

    var last: pingo.value.Value = .unspecified;
    var failed = false;
    read_loop: while (true) {
        const d = reader.read() catch |err| {
            try out.print("read error: {s}\n", .{@errorName(err)});
            try out.flush();
            std.process.exit(1);
        } orelse break;

        var outcome = machine.evalToplevel(d) catch |err| {
            try reportError(out, &machine, err);
            failed = true;
            break :read_loop;
        };
        while (outcome == .blocked) {
            // Arm a real timer per outstanding call, then let libxev run the
            // whole batch — the timers overlap in wall-clock time.
            for (machine.outstanding()) |p| try host.dispatch(&loop, p);
            try loop.run(.until_done);
            outcome = machine.continueRun() catch |err| {
                try reportError(out, &machine, err);
                failed = true;
                break :read_loop;
            };
        }
        last = outcome.value;
    }

    if (!failed and last != .unspecified) {
        try pingo.printer.writeValue(last, out);
        try out.writeByte('\n');
    }
    if (host.seq_sum > 0) {
        const real_ms = host.elapsedMs();
        const speedup = if (real_ms > 0)
            @as(f64, @floatFromInt(host.seq_sum)) / @as(f64, @floatFromInt(real_ms))
        else
            1.0;
        try out.print("real time: {d}ms | sequential sum: {d}ms | speedup: {d:.2}x\n", .{ real_ms, host.seq_sum, speedup });
    }
    try out.flush();
    if (failed) std.process.exit(1);
}

fn readWholeFile(init: std.process.Init, out: *std.Io.Writer, path: []const u8, arena: std.mem.Allocator) ![]u8 {
    const file = std.Io.Dir.cwd().openFile(init.io, path, .{}) catch |err| {
        try out.print("cannot open {s}: {s}\n", .{ path, @errorName(err) });
        try out.flush();
        std.process.exit(1);
    };
    defer file.close(init.io);
    var read_buffer: [4096]u8 = undefined;
    var file_reader: std.Io.File.Reader = .init(file, init.io, &read_buffer);
    return file_reader.interface.allocRemaining(arena, .limited(max_file_bytes));
}

fn writeArgs(out: *std.Io.Writer, args: []const pingo.value.Value) !void {
    try out.writeByte('(');
    for (args, 0..) |a, i| {
        if (i > 0) try out.writeByte(' ');
        try pingo.printer.writeValue(a, out);
    }
    try out.writeByte(')');
}

fn reportError(out: *std.Io.Writer, machine: *pingo.machine.Machine, err: pingo.machine.Error) !void {
    try out.print("error: {s}", .{pingo.eval.kindOf(err)});
    if (machine.diagnostic) |diag| try out.print(" ({s})", .{diag.context});
    try out.writeByte('\n');
    try out.flush();
}

fn repl(init: std.process.Init, out: *std.Io.Writer) !void {
    var stdin_buffer: [max_line_bytes]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .init(.stdin(), init.io, &stdin_buffer);
    const in = &stdin_reader.interface;

    var session_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer session_arena_state.deinit();
    // Heap budget (§5 heap_bytes): everything the guest allocates — values,
    // environments, datums — goes through this budgeted view of the arena.
    var session_heap = pingo.limits.LimitedAllocator.init(session_arena_state.allocator(), repl_heap_bytes);
    const session_arena = session_heap.allocator();
    var evaluator = try pingo.machine.Machine.init(session_arena, repl_limits);

    var print_host = PrintHost{ .out = out };
    const print_cap = pingo.capability.Capability{
        .name = "print",
        .class = .globally_ordered,
        .ctx = &print_host,
        .handler = PrintHost.print,
    };
    try pingo.capability.register(evaluator.global, &print_cap);

    while (true) {
        try out.writeAll("pingo> ");
        try out.flush();

        const line = in.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try out.print("error: line longer than {d} bytes\n", .{max_line_bytes});
                try out.flush();
                return;
            },
            error.ReadFailed => return err,
        } orelse break; // end of input

        // Session arena: definitions and closure bodies must outlive the
        // line that read them, so datums are read into the same arena.
        var reader = pingo.reader.Reader.init(session_arena, line, max_read_depth);
        evaluator.fuel_used = 0; // fresh budget per line

        while (true) {
            const d = reader.read() catch |err| {
                try out.print("read error: {s}\n", .{@errorName(err)});
                break;
            } orelse break;
            const v = evaluator.runToCompletion(d) catch |err| {
                try out.print("error: {s}", .{pingo.eval.kindOf(err)});
                if (evaluator.diagnostic) |diag|
                    try out.print(" ({s})", .{diag.context});
                try out.writeByte('\n');
                continue;
            };
            if (v != .unspecified) {
                try pingo.printer.writeValue(v, out);
                try out.writeByte('\n');
            }
        }
    }
    try out.flush();
}

test "library is wired in" {
    try std.testing.expect(pingo.version.len > 0);
}
