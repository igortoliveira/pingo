//! Biblioteca do Pingo. O executável (src/main.zig) é um cliente deste módulo.

const std = @import("std");

pub const version = "0.0.0";

pub const lexer = @import("lexer.zig");
pub const datum = @import("datum.zig");
pub const reader = @import("reader.zig");
pub const printer = @import("printer.zig");
pub const value = @import("value.zig");
pub const eval = @import("eval.zig");
pub const env = @import("env.zig");
pub const primitives = @import("primitives.zig");
pub const limits = @import("limits.zig");
pub const capability = @import("capability.zig");

test {
    std.testing.refAllDecls(@This());
}
