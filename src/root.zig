//! Biblioteca do Pingo. O executável (src/main.zig) é um cliente deste módulo.

const std = @import("std");

pub const version = "0.0.0";

pub const lexer = @import("syntax/lexer.zig");
pub const datum = @import("syntax/datum.zig");
pub const reader = @import("syntax/reader.zig");
pub const printer = @import("syntax/printer.zig");
pub const value = @import("runtime/value.zig");
pub const eval = @import("engine/eval.zig");
pub const env = @import("runtime/env.zig");
pub const primitives = @import("engine/primitives.zig");
pub const limits = @import("runtime/limits.zig");
pub const capability = @import("runtime/capability.zig");
pub const machine = @import("engine/machine.zig");
pub const expand = @import("engine/expand.zig");
pub const trace = @import("host/trace.zig");
pub const macro = @import("engine/macro.zig");

test {
    std.testing.refAllDecls(@This());
}
