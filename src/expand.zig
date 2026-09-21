//! Shared expander for derived forms (semantics §2 "Derived forms"): the
//! machine and the reference oracle both call these, so derived-form
//! semantics cannot drift between them.

const std = @import("std");
const datum_mod = @import("datum.zig");

const Datum = datum_mod.Datum;

pub const Error = error{ BadSyntax, OutOfMemory };

/// `(let ((n e) ...) body ...)` → `((lambda (n ...) body ...) e ...)`.
/// `form` is the datum after the `let` symbol. Distinct names and non-empty
/// body are enforced by the lambda the expansion produces.
pub fn expandLet(arena: std.mem.Allocator, form: Datum) Error!Datum {
    if (form != .pair) return error.BadSyntax;
    var names: std.ArrayList(Datum) = .empty;
    defer names.deinit(arena);
    var exprs: std.ArrayList(Datum) = .empty;
    defer exprs.deinit(arena);

    var b = form.pair.car;
    while (b == .pair) : (b = b.pair.cdr) {
        const binding = b.pair.car;
        if (binding != .pair or binding.pair.car != .symbol) return error.BadSyntax;
        if (binding.pair.cdr != .pair or binding.pair.cdr.pair.cdr != .empty_list)
            return error.BadSyntax;
        try names.append(arena, binding.pair.car);
        try exprs.append(arena, binding.pair.cdr.pair.car);
    }
    if (b != .empty_list) return error.BadSyntax;

    const lambda_form = try datum_mod.cons(
        arena,
        try datum_mod.symbol(arena, "lambda"),
        try datum_mod.cons(arena, try listFrom(arena, names.items), form.pair.cdr),
    );
    return try datum_mod.cons(arena, lambda_form, try listFrom(arena, exprs.items));
}

fn listFrom(arena: std.mem.Allocator, items: []const Datum) Error!Datum {
    var result: Datum = .empty_list;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        result = try datum_mod.cons(arena, items[i], result);
    }
    return result;
}

// -- tests --------------------------------------------------------------

const reader_mod = @import("reader.zig");
const printer_mod = @import("printer.zig");

fn expectExpansion(expander: anytype, src: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r = reader_mod.Reader.init(arena, src, 16);
    const d = (try r.read()).?;
    const expanded = try expander(arena, d.pair.cdr);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try printer_mod.write(expanded, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "let expands to a lambda application" {
    try expectExpansion(expandLet, "(let ((x 1) (y 2)) (+ x y))", "((lambda (x y) (+ x y)) 1 2)");
    try expectExpansion(expandLet, "(let () 5)", "((lambda () 5))");
}

test "let shape errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_][]const u8{ "(let x 1)", "(let (x) 1)", "(let ((x 1 2)) x)", "(let ((1 2)) 3)" };
    for (cases) |src| {
        var r = reader_mod.Reader.init(arena, src, 16);
        const d = (try r.read()).?;
        try std.testing.expectError(error.BadSyntax, expandLet(arena, d.pair.cdr));
    }
}
