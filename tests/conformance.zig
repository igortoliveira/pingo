//! Conformance runner over the vendored chibi-scheme r5rs suite.
//!
//! Allowlisting is automatic, per the plan: a `(test expected expr)` form runs
//! only if (a) v0's reader accepts it and (b) every free symbol in it resolves
//! to a v0 binding or special form. Everything else counts as SKIP — never as
//! PASS. A test that runs and diverges counts as FAIL and fails the build.

const std = @import("std");
const pingo = @import("pingo");

const Datum = pingo.datum.Datum;
const Value = pingo.value.Value;

const suite = @embedFile("vendor/chibi-scheme/r5rs-tests.scm");

const special_forms = [_][]const u8{ "quote", "if", "define", "lambda", "begin" };

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var evaluator = try pingo.eval.Evaluator.init(arena);

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;

    var forms = FormIterator{ .lexer = pingo.lexer.Lexer.init(suite) };
    while (forms.next()) |form_src| {
        const t = parseTestForm(arena, form_src) orelse {
            skip += 1;
            continue;
        };
        if (!allSymbolsSupported(arena, t.expected, &evaluator) or
            !allSymbolsSupported(arena, t.expr, &evaluator))
        {
            skip += 1;
            continue;
        }

        const expected = evaluator.evalToplevel(t.expected) catch {
            skip += 1; // the *expectation* itself needs unsupported semantics
            continue;
        };
        const actual = evaluator.evalToplevel(t.expr) catch |err| {
            fail += 1;
            try out.print("FAIL (error {s}): {s}\n", .{ pingo.eval.kindOf(err), form_src });
            continue;
        };
        if (deepEqual(expected, actual)) {
            pass += 1;
        } else {
            fail += 1;
            try out.print("FAIL (mismatch): {s}\n", .{form_src});
        }
    }

    try out.print("conformance: {d} pass, {d} fail, {d} skip\n", .{ pass, fail, skip });
    try out.flush();
    if (fail > 0) std.process.exit(1);
}

/// Iterates over top-level parenthesized forms via the lexer (so strings and
/// comments can't unbalance the scan), yielding the source slice of each.
const FormIterator = struct {
    lexer: pingo.lexer.Lexer,

    fn next(it: *FormIterator) ?[]const u8 {
        var depth: usize = 0;
        var start: usize = 0;
        while (true) {
            const tok = it.lexer.next();
            switch (tok.tag) {
                .eof => return null,
                .lparen => {
                    if (depth == 0) start = tok.start;
                    depth += 1;
                },
                .rparen => {
                    if (depth == 0) continue; // stray ) — not ours to judge
                    depth -= 1;
                    if (depth == 0) return it.lexer.src[start..tok.end];
                },
                else => {},
            }
        }
    }
};

const TestForm = struct { expected: Datum, expr: Datum };

/// Accepts `(test expected expr)` and `(test "name" expected expr)`;
/// anything else (unreadable in v0, or a different shape) is null.
fn parseTestForm(arena: std.mem.Allocator, src: []const u8) ?TestForm {
    var r = pingo.reader.Reader.init(arena, src, 64);
    const d = (r.read() catch return null) orelse return null;
    var items: [5]Datum = undefined;
    var n: usize = 0;
    var rest = d;
    while (rest == .pair) : (rest = rest.pair.cdr) {
        if (n >= items.len) return null;
        items[n] = rest.pair.car;
        n += 1;
    }
    if (rest != .empty_list) return null;
    if (n < 3 or items[0] != .symbol or !std.mem.eql(u8, items[0].symbol, "test")) return null;
    if (n == 3) return .{ .expected = items[1], .expr = items[2] };
    if (n == 4 and items[1] == .string) return .{ .expected = items[2], .expr = items[3] };
    return null;
}

/// True iff every free symbol outside quote resolves to a global binding, a
/// special form, or a lambda parameter in scope.
fn allSymbolsSupported(arena: std.mem.Allocator, d: Datum, evaluator: *pingo.eval.Evaluator) bool {
    var bound: std.ArrayList([]const u8) = .empty;
    defer bound.deinit(arena);
    return check(arena, d, evaluator, &bound) catch false;
}

fn check(
    arena: std.mem.Allocator,
    d: Datum,
    evaluator: *pingo.eval.Evaluator,
    bound: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!bool {
    switch (d) {
        .symbol => |name| {
            for (special_forms) |s| if (std.mem.eql(u8, s, name)) return true;
            for (bound.items) |b| if (std.mem.eql(u8, b, name)) return true;
            return evaluator.global.lookup(name) != null;
        },
        .pair => |p| {
            if (p.car == .symbol and std.mem.eql(u8, p.car.symbol, "quote")) return true;
            if (p.car == .symbol and std.mem.eql(u8, p.car.symbol, "lambda") and p.cdr == .pair) {
                const before = bound.items.len;
                defer bound.shrinkRetainingCapacity(before);
                var params = p.cdr.pair.car;
                while (params == .pair) : (params = params.pair.cdr) {
                    if (params.pair.car != .symbol) return false;
                    try bound.append(arena, params.pair.car.symbol);
                }
                var body = p.cdr.pair.cdr;
                while (body == .pair) : (body = body.pair.cdr)
                    if (!try check(arena, body.pair.car, evaluator, bound)) return false;
                return true;
            }
            var rest = d;
            while (rest == .pair) : (rest = rest.pair.cdr)
                if (!try check(arena, rest.pair.car, evaluator, bound)) return false;
            return true;
        },
        else => return true,
    }
}

/// Structural equality (`equal?`-like), which is what the suite's `test`
/// macro uses to compare results.
fn deepEqual(a: Value, b: Value) bool {
    if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) return false;
    return switch (a) {
        .string => std.mem.eql(u8, a.string, b.string),
        .pair => deepEqual(a.pair.car, b.pair.car) and deepEqual(a.pair.cdr, b.pair.cdr),
        else => pingo.primitives.eqValues(a, b),
    };
}
