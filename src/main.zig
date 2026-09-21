const std = @import("std");
const pingo = @import("pingo");

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
    const class: pingo.capability.EffectClass = if (std.mem.eql(u8, class_name, "pure"))
        .pure
    else if (std.mem.eql(u8, class_name, "independent"))
        .external_independent
    else if (std.mem.eql(u8, class_name, "resource"))
        .resource_ordered
    else if (std.mem.eql(u8, class_name, "ordered"))
        .globally_ordered
    else if (std.mem.eql(u8, class_name, "irreversible"))
        .irreversible
    else
        return null;
    const latency: u64 = if (parts.next()) |l| std.fmt.parseInt(u64, l, 10) catch return null else 100;
    return .{
        .cap = .{ .name = name, .class = class, .ctx = undefined, .handler = SimTool.handle },
        .latency_ms = latency,
    };
}

const usage =
    \\usage: pingo [file.scm] [--tool name[:class[:latency_ms]]]... [--trace]
    \\  classes: pure | independent | resource | ordered | irreversible
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
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--trace")) {
            trace = true;
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

    if (file_path) |path| return runFile(init, out, path, tools.items, trace);
    return repl(init, out);
}

/// File mode: evaluate every form; the first error aborts with exit code 1.
/// Simulated tools complete on a virtual clock — the call with the earliest
/// completion settles first — so the trace and the final report show real
/// dispatch overlap without any real waiting.
fn runFile(init: std.process.Init, out: *std.Io.Writer, path: []const u8, tools: []SimTool, trace: bool) !void {
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

    const file = std.Io.Dir.cwd().openFile(init.io, path, .{}) catch |err| {
        try out.print("cannot open {s}: {s}\n", .{ path, @errorName(err) });
        try out.flush();
        std.process.exit(1);
    };
    defer file.close(init.io);
    var read_buffer: [4096]u8 = undefined;
    var file_reader: std.Io.File.Reader = .init(file, init.io, &read_buffer);
    const src = try file_reader.interface.allocRemaining(session_arena, .limited(max_file_bytes));

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
                const latency = latencyOf(tools, p.capability);
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
                machine.resolve(chosen.p, result);
            } else |err| switch (err) {
                error.HostError => {
                    if (trace) try out.print("[t={d:>5}ms] settle   {s} -> FAILED\n", .{ clock, cap.name });
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
    try out.flush();
    if (failed) std.process.exit(1);
}

fn latencyOf(tools: []const SimTool, cap: *const pingo.capability.Capability) u64 {
    for (tools) |*tool| if (&tool.cap == cap) return tool.latency_ms;
    return 0; // e.g. print
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
