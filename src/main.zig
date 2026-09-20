const std = @import("std");
const pingo = @import("pingo");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const w = &stdout_writer.interface;

    try w.print("pingo {s}\n", .{pingo.version});
    try w.flush();
}

test "versão exposta pela biblioteca" {
    try std.testing.expect(pingo.version.len > 0);
}
