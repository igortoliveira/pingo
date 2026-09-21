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

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var file_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.startsWith(u8, args[i], "--")) {
            try out.print("unknown option: {s}\nusage: pingo [file.scm]\n", .{args[i]});
            try out.flush();
            return;
        }
        file_path = args[i];
    }

    if (file_path) |path| return runFile(init, out, path);
    return repl(init, out);
}

/// File mode: evaluate every form; the first error aborts with exit code 1.
fn runFile(init: std.process.Init, out: *std.Io.Writer, path: []const u8) !void {
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
    var last: pingo.value.Value = .unspecified;
    while (true) {
        const d = reader.read() catch |err| {
            try out.print("read error: {s}\n", .{@errorName(err)});
            try out.flush();
            std.process.exit(1);
        } orelse break;
        last = machine.runToCompletion(d) catch |err| {
            try out.print("error: {s}", .{pingo.eval.kindOf(err)});
            if (machine.diagnostic) |diag| try out.print(" ({s})", .{diag.context});
            try out.writeByte('\n');
            try out.flush();
            std.process.exit(1);
        };
    }
    if (last != .unspecified) {
        try pingo.printer.writeValue(last, out);
        try out.writeByte('\n');
    }
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
