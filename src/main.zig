const std = @import("std");
const pingo = @import("pingo");

const max_line_bytes = 4096;
const max_read_depth = 64;

// The REPL is the host here (§5): each line gets a fresh fuel budget.
const repl_limits: pingo.eval.Limits = .{ .fuel = 10_000_000, .call_depth = 1_000 };
const repl_heap_bytes = 256 * 1024 * 1024; // per session (the v0 arena never frees)

pub fn main(init: std.process.Init) !void {
    var stdin_buffer: [max_line_bytes]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .init(.stdin(), init.io, &stdin_buffer);
    const in = &stdin_reader.interface;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var session_arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer session_arena_state.deinit();
    // Heap budget (§5 heap_bytes): everything the guest allocates — values,
    // environments, datums — goes through this budgeted view of the arena.
    var session_heap = pingo.limits.LimitedAllocator.init(session_arena_state.allocator(), repl_heap_bytes);
    const session_arena = session_heap.allocator();
    var evaluator = try pingo.eval.Evaluator.init(session_arena, repl_limits);

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
            const v = evaluator.evalToplevel(d) catch |err| {
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
