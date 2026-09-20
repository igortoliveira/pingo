const std = @import("std");
const pingo = @import("pingo");

const max_line_bytes = 4096;
const max_read_depth = 64;

pub fn main(init: std.process.Init) !void {
    var stdin_buffer: [max_line_bytes]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .init(.stdin(), init.io, &stdin_buffer);
    const in = &stdin_reader.interface;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

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

        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        var reader = pingo.reader.Reader.init(arena_state.allocator(), line, max_read_depth);

        while (true) {
            const d = reader.read() catch |err| {
                try out.print("read error: {s}\n", .{@errorName(err)});
                break;
            } orelse break;
            try pingo.printer.write(d, out);
            try out.writeByte('\n');
        }
    }
    try out.flush();
}

test "library is wired in" {
    try std.testing.expect(pingo.version.len > 0);
}
