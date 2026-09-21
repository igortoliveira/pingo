//! Runs the parallelism-study target programs (tests/examples/*.scm) against
//! stub capabilities, proving they are valid v0 programs and pinning their
//! §6 observation counts. The latency analysis lives in
//! docs/parallelism-study.md; this file only establishes the ground truth
//! those numbers are computed from.

const std = @import("std");
const pingo = @import("pingo");

const Value = pingo.value.Value;

const StubHost = struct {
    calls: usize = 0,

    /// Every stub returns a value derived from nothing — programs only need
    /// values to flow, not to mean anything.
    fn handle(ctx: *anyopaque, arena: std.mem.Allocator, _: []const Value) pingo.capability.HostError!Value {
        const h: *StubHost = @ptrCast(@alignCast(ctx));
        h.calls += 1;
        return .{ .string = try arena.dupe(u8, "stub-result") };
    }
};

const stub_names = [_][]const u8{
    "summarize", "synthesize",
    "plan",      "draft",
    "critique",  "revise",
    "propose",   "score",
    "pick-best", "expand",
    "rewrite",   "search-web",
    "search-wiki", "search-docs",
    "rerank",    "answer",
    "tool-a",    "tool-b",
    "merge",
};

fn runProgram(src: []const u8, host: *StubHost, caps: []pingo.capability.Capability) !Value {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var evaluator = try pingo.machine.Machine.init(arena, .{
        .fuel = 1_000_000,
        .call_depth = 500,
    });
    for (stub_names, 0..) |name, i| {
        caps[i] = .{ .name = name, .class = .external_independent, .ctx = host, .handler = StubHost.handle };
        try pingo.capability.register(evaluator.global, &caps[i]);
    }

    var r = pingo.reader.Reader.init(arena, src, 32);
    var last: Value = .unspecified;
    while (try r.read()) |d| last = try evaluator.runToCompletion(d);
    // Values referencing the arena die here; callers only inspect the tag.
    return switch (last) {
        .string => .unspecified, // arena-owned bytes die with this frame
        else => last,
    };
}

fn expectCalls(src: []const u8, expected: usize) !void {
    var host = StubHost{};
    var caps: [stub_names.len]pingo.capability.Capability = undefined;
    _ = try runProgram(src, &host, &caps);
    try std.testing.expectEqual(expected, host.calls);
}

test "p1 fan-out: 4 summaries + 1 synthesize" {
    try expectCalls(@embedFile("examples/p1-fanout.scm"), 5);
}

/// Schedule fuzz (§6): runs a program resolving outstanding calls in a
/// seeded-random order and demands the same printed outcome and dispatch
/// count as the sequential in-order run. Completion order is the host's
/// freedom; results must not depend on it.
fn runShuffled(src: []const u8, seed: u64, out: *std.Io.Writer.Allocating) !usize {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var host = StubHost{};
    var caps: [stub_names.len]pingo.capability.Capability = undefined;
    var machine = try pingo.machine.Machine.init(arena, .{ .fuel = 1_000_000, .call_depth = 500 });
    for (stub_names, 0..) |name, i| {
        caps[i] = .{ .name = name, .class = .external_independent, .ctx = &host, .handler = StubHost.handle };
        try pingo.capability.register(machine.global, &caps[i]);
    }

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var dispatched: usize = 0;

    var r = pingo.reader.Reader.init(arena, src, 32);
    var last: pingo.value.Value = .unspecified;
    while (try r.read()) |d| {
        var outcome = try machine.evalToplevel(d);
        while (outcome == .blocked) {
            const calls = machine.outstanding();
            const pick = calls[random.intRangeLessThan(usize, 0, calls.len)];
            dispatched += 1;
            machine.resolve(pick, .{ .string = try arena.dupe(u8, "stub-result") });
            outcome = try machine.continueRun();
        }
        last = outcome.value;
    }
    try pingo.printer.writeValue(last, &out.writer);
    return dispatched;
}

test "schedule fuzz: completion order never changes the outcome" {
    const programs = [_][]const u8{
        @embedFile("examples/p1-fanout.scm"),
        @embedFile("examples/p2-chain.scm"),
        @embedFile("examples/p3-tree.scm"),
        @embedFile("examples/p4-rag.scm"),
        @embedFile("examples/p5-agent-loop.scm"),
    };
    const expected_calls = [_]usize{ 5, 4, 8, 6, 9 };

    for (programs, expected_calls) |src, expected| {
        var baseline = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer baseline.deinit();
        try std.testing.expectEqual(expected, try runShuffled(src, 0, &baseline));

        for (1..8) |seed| {
            var shuffled = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer shuffled.deinit();
            try std.testing.expectEqual(expected, try runShuffled(src, seed, &shuffled));
            try std.testing.expectEqualStrings(baseline.written(), shuffled.written());
        }
    }
}

test "differential: opportunistic machine agrees with the sequential oracle" {
    const programs = [_][]const u8{
        @embedFile("examples/p1-fanout.scm"),
        @embedFile("examples/p2-chain.scm"),
        @embedFile("examples/p3-tree.scm"),
        @embedFile("examples/p4-rag.scm"),
        @embedFile("examples/p5-agent-loop.scm"),
    };
    for (programs) |src| {
        // Oracle: the recursive evaluator with synchronous dispatch.
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var host = StubHost{};
        var caps: [stub_names.len]pingo.capability.Capability = undefined;
        var oracle = try pingo.eval.Evaluator.init(arena, .{ .fuel = 1_000_000, .call_depth = 500 });
        for (stub_names, 0..) |name, i| {
            caps[i] = .{ .name = name, .class = .external_independent, .ctx = &host, .handler = StubHost.handle };
            try pingo.capability.register(oracle.global, &caps[i]);
        }
        var r = pingo.reader.Reader.init(arena, src, 32);
        var last: pingo.value.Value = .unspecified;
        while (try r.read()) |d| last = try oracle.evalToplevel(d);
        var oracle_out = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer oracle_out.deinit();
        try pingo.printer.writeValue(last, &oracle_out.writer);

        var machine_out = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer machine_out.deinit();
        _ = try runShuffled(src, 42, &machine_out);
        try std.testing.expectEqualStrings(oracle_out.written(), machine_out.written());
    }
}

/// Record→replay differential (9.3): a recording fully determines a run.
/// Each program runs once with recording stubs (per-name results, one
/// `(call ...)` line per settle), then again with stubs reconstructed from
/// the trace headers serving the recorded results. Printed outcome and
/// dispatch count must match.
const RecTool = struct {
    name: []const u8,
    trace_out: *std.Io.Writer.Allocating,
    calls: *usize,

    fn handle(ctx: *anyopaque, arena: std.mem.Allocator, args: []const Value) pingo.capability.HostError!Value {
        const t: *RecTool = @ptrCast(@alignCast(ctx));
        t.calls.* += 1;
        const text = std.fmt.allocPrint(arena, "{s}-result", .{t.name}) catch return error.OutOfMemory;
        const result: Value = .{ .string = text };
        pingo.trace.writeCall(&t.trace_out.writer, t.name, args, result) catch return error.OutOfMemory;
        return result;
    }
};

const ReplayTool = struct {
    name: []const u8,
    replay: *pingo.trace.Replay,
    calls: *usize,

    fn handle(ctx: *anyopaque, arena: std.mem.Allocator, args: []const Value) pingo.capability.HostError!Value {
        const t: *ReplayTool = @ptrCast(@alignCast(ctx));
        t.calls.* += 1;
        const served = (try t.replay.next(arena, t.name, args)) orelse return error.HostError;
        return switch (served) {
            .ok => |v| v,
            .failure => error.HostError,
        };
    }
};

fn runRecorded(src: []const u8, trace_out: *std.Io.Writer.Allocating, printed: *std.Io.Writer.Allocating) !usize {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var calls: usize = 0;
    var tools: [stub_names.len]RecTool = undefined;
    var caps: [stub_names.len]pingo.capability.Capability = undefined;
    var machine = try pingo.machine.Machine.init(arena, .{ .fuel = 1_000_000, .call_depth = 500 });
    for (stub_names, 0..) |name, i| {
        try pingo.trace.writeTool(&trace_out.writer, name, .external_independent, 0);
        tools[i] = .{ .name = name, .trace_out = trace_out, .calls = &calls };
        caps[i] = .{ .name = name, .class = .external_independent, .ctx = &tools[i], .handler = RecTool.handle };
        try pingo.capability.register(machine.global, &caps[i]);
    }

    var r = pingo.reader.Reader.init(arena, src, 32);
    var last: pingo.value.Value = .unspecified;
    while (try r.read()) |d| last = try machine.runToCompletion(d);
    try pingo.printer.writeValue(last, &printed.writer);
    return calls;
}

fn runReplayed(src: []const u8, trace_src: []const u8, printed: *std.Io.Writer.Allocating) !usize {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var replay = try pingo.trace.parse(arena, trace_src);
    var calls: usize = 0;
    // Capabilities come from the trace headers, as the replay runner does.
    const tools = try arena.alloc(ReplayTool, replay.tools.len);
    const caps = try arena.alloc(pingo.capability.Capability, replay.tools.len);
    var machine = try pingo.machine.Machine.init(arena, .{ .fuel = 1_000_000, .call_depth = 500 });
    for (replay.tools, tools, caps) |spec, *tool, *cap| {
        tool.* = .{ .name = spec.name, .replay = &replay, .calls = &calls };
        cap.* = .{ .name = spec.name, .class = spec.class, .ctx = tool, .handler = ReplayTool.handle };
        try pingo.capability.register(machine.global, cap);
    }

    var r = pingo.reader.Reader.init(arena, src, 32);
    var last: pingo.value.Value = .unspecified;
    while (try r.read()) |d| last = try machine.runToCompletion(d);
    try pingo.printer.writeValue(last, &printed.writer);
    return calls;
}

test "differential: replay reproduces the recorded run" {
    const programs = [_][]const u8{
        @embedFile("examples/p1-fanout.scm"),
        @embedFile("examples/p2-chain.scm"),
        @embedFile("examples/p3-tree.scm"),
        @embedFile("examples/p4-rag.scm"),
        @embedFile("examples/p5-agent-loop.scm"),
    };
    const expected_calls = [_]usize{ 5, 4, 8, 6, 9 };

    for (programs, expected_calls) |src, expected| {
        var trace_out = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer trace_out.deinit();
        var recorded = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer recorded.deinit();
        try std.testing.expectEqual(expected, try runRecorded(src, &trace_out, &recorded));

        var replayed = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer replayed.deinit();
        try std.testing.expectEqual(expected, try runReplayed(src, trace_out.written(), &replayed));
        try std.testing.expectEqualStrings(recorded.written(), replayed.written());
    }
}

test "p2 chain: 4 sequential calls" {
    try expectCalls(@embedFile("examples/p2-chain.scm"), 4);
}

test "p3 tree: 3 propose + 3 score + pick + expand" {
    try expectCalls(@embedFile("examples/p3-tree.scm"), 8);
}

test "p4 rag: rewrite + 3 searches + rerank + answer" {
    try expectCalls(@embedFile("examples/p4-rag.scm"), 6);
}

test "p5 agent loop: 3 iterations x (2 tools + merge)" {
    try expectCalls(@embedFile("examples/p5-agent-loop.scm"), 9);
}
