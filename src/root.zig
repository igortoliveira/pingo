//! Biblioteca do Pingo. O executável (src/main.zig) é um cliente deste módulo.

const std = @import("std");

pub const version = "0.0.0";

test {
    std.testing.refAllDecls(@This());
}
