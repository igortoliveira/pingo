//! Shared expander for derived forms (semantics §2 "Derived forms"): the
//! machine and the reference oracle both call these, so derived-form
//! semantics cannot drift between them.

const std = @import("std");
const datum_mod = @import("datum.zig");

const Datum = datum_mod.Datum;

pub const Error = error{ BadSyntax, OutOfMemory };

/// `(let ((n e) ...) body ...)` → `((lambda (n ...) body ...) e ...)`.
/// `(let name ((n e) ...) body ...)` →
/// `(letrec ((name (lambda (n ...) body ...))) (name e ...))`.
/// `form` is the datum after the `let` symbol. Distinct names and non-empty
/// body are enforced by the lambda the expansion produces.
pub fn expandLet(arena: std.mem.Allocator, form: Datum) Error!Datum {
    if (form != .pair) return error.BadSyntax;
    if (form.pair.car == .symbol) return expandNamedLet(arena, form);
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

fn expandNamedLet(arena: std.mem.Allocator, form: Datum) Error!Datum {
    // form = (name ((n e) ...) body ...)
    const name = form.pair.car;
    if (form.pair.cdr != .pair) return error.BadSyntax;
    const b = try parseBindings(arena, form.pair.cdr.pair.car);
    const body = form.pair.cdr.pair.cdr;

    var params: Datum = .empty_list;
    var i = b.names.len;
    while (i > 0) {
        i -= 1;
        params = try datum_mod.cons(arena, try datum_mod.symbol(arena, b.names[i]), params);
    }
    const lambda_form = try datum_mod.cons(
        arena,
        try datum_mod.symbol(arena, "lambda"),
        try datum_mod.cons(arena, params, body),
    );
    const binding = try listOf(arena, &.{try listOf(arena, &.{ name, lambda_form })});
    const call = try datum_mod.cons(arena, name, try listFrom(arena, b.inits));
    return try listOf(arena, &.{ try datum_mod.symbol(arena, "letrec"), binding, call });
}

/// `(let* ((n e) ...) body ...)` → nested `let`s, one binding each, so every
/// init sees the names before it.
pub fn expandLetStar(arena: std.mem.Allocator, form: Datum) Error!Datum {
    if (form != .pair) return error.BadSyntax;
    const bindings = form.pair.car;
    if (bindings == .empty_list)
        return try datum_mod.cons(arena, try datum_mod.symbol(arena, "let"), form);
    if (bindings != .pair) return error.BadSyntax;
    const first = try listOf(arena, &.{bindings.pair.car});
    const inner = try datum_mod.cons(
        arena,
        try datum_mod.symbol(arena, "let*"),
        try datum_mod.cons(arena, bindings.pair.cdr, form.pair.cdr),
    );
    return try listOf(arena, &.{ try datum_mod.symbol(arena, "let"), first, inner });
}

/// `(do ((n init [step]) ...) (test res ...) cmd ...)` → a named-let-style
/// loop over an unreadable loop symbol; a missing step keeps the variable.
pub fn expandDo(arena: std.mem.Allocator, form: Datum) Error!Datum {
    if (form != .pair or form.pair.cdr != .pair) return error.BadSyntax;
    const exit_clause = form.pair.cdr.pair.car;
    if (exit_clause != .pair) return error.BadSyntax;
    const cmds = form.pair.cdr.pair.cdr;

    var bindings: Datum = .empty_list;
    var steps: std.ArrayList(Datum) = .empty;
    defer steps.deinit(arena);
    {
        // walk the specs twice: once to validate/collect, building backwards
        var specs: std.ArrayList(Datum) = .empty;
        defer specs.deinit(arena);
        var b = form.pair.car;
        while (b == .pair) : (b = b.pair.cdr) try specs.append(arena, b.pair.car);
        if (b != .empty_list) return error.BadSyntax;

        var i = specs.items.len;
        while (i > 0) {
            i -= 1;
            const spec = specs.items[i];
            if (spec != .pair or spec.pair.car != .symbol or spec.pair.cdr != .pair)
                return error.BadSyntax;
            const name = spec.pair.car;
            const init = spec.pair.cdr.pair.car;
            const step: Datum = switch (spec.pair.cdr.pair.cdr) {
                .empty_list => name, // no step: the variable carries over
                .pair => |s| if (s.cdr == .empty_list) s.car else return error.BadSyntax,
                else => return error.BadSyntax,
            };
            bindings = try datum_mod.cons(arena, try listOf(arena, &.{ name, init }), bindings);
            try steps.insert(arena, 0, step);
        }
    }

    const loop = try datum_mod.symbol(arena, " do-loop");
    const recur = try datum_mod.cons(arena, loop, try listFrom(arena, steps.items));
    const loop_body = switch (cmds) {
        .empty_list => recur,
        .pair => try datum_mod.cons(arena, try datum_mod.symbol(arena, "begin"), try appendDatum(arena, cmds, recur)),
        else => return error.BadSyntax,
    };
    const result: Datum = switch (exit_clause.pair.cdr) {
        .empty_list => try listOf(arena, &.{ try datum_mod.symbol(arena, "if"), .{ .boolean = false }, .{ .boolean = false } }),
        .pair => |r| try beginOf(arena, .{ .pair = r }),
        else => return error.BadSyntax,
    };
    const if_form = try listOf(arena, &.{
        try datum_mod.symbol(arena, "if"), exit_clause.pair.car, result, loop_body,
    });
    return try listOf(arena, &.{ try datum_mod.symbol(arena, "let"), loop, bindings, if_form });
}

/// Copies proper list `xs` with `last` appended as the final element.
fn appendDatum(arena: std.mem.Allocator, xs: Datum, last: Datum) Error!Datum {
    var items: std.ArrayList(Datum) = .empty;
    defer items.deinit(arena);
    var rest = xs;
    while (rest == .pair) : (rest = rest.pair.cdr) try items.append(arena, rest.pair.car);
    if (rest != .empty_list) return error.BadSyntax;
    try items.append(arena, last);
    return listFrom(arena, items.items);
}

/// `(cond (c e ...) ... [(else e ...)])` → nested `if`s. Each clause needs at
/// least one expression after its test; `else` must be last. No matching
/// clause yields unspecified (expansion target: `(if #f #f)`).
/// `else_is_bound`: hygiene — when the caller's scope binds `else`, it is a
/// variable like any other, not the keyword (the r5rs suite tests this).
pub fn expandCond(arena: std.mem.Allocator, form: Datum, else_is_bound: bool) Error!Datum {
    var clauses: std.ArrayList(Datum) = .empty;
    defer clauses.deinit(arena);
    var rest = form;
    while (rest == .pair) : (rest = rest.pair.cdr) try clauses.append(arena, rest.pair.car);
    if (rest != .empty_list or clauses.items.len == 0) return error.BadSyntax;

    // (if #f #f) evaluates to unspecified — the no-clause-matched result.
    var result = try listOf(arena, &.{
        try datum_mod.symbol(arena, "if"),
        .{ .boolean = false },
        .{ .boolean = false },
    });

    var i = clauses.items.len;
    while (i > 0) {
        i -= 1;
        const clause = clauses.items[i];
        if (clause != .pair or clause.pair.cdr != .pair) return error.BadSyntax;
        const test_d = clause.pair.car;
        const body = try beginOf(arena, clause.pair.cdr);
        if (!else_is_bound and test_d == .symbol and std.mem.eql(u8, test_d.symbol, "else")) {
            if (i != clauses.items.len - 1) return error.BadSyntax; // else must be last
            result = body;
        } else {
            result = try listOf(arena, &.{
                try datum_mod.symbol(arena, "if"), test_d, body, result,
            });
        }
    }
    return result;
}

/// `(and)` → `#t`; `(and e)` → `e`; `(and e r ...)` → `(if e (and r ...) #f)`.
pub fn expandAnd(arena: std.mem.Allocator, form: Datum) Error!Datum {
    if (form == .empty_list) return .{ .boolean = true };
    if (form != .pair) return error.BadSyntax;
    if (form.pair.cdr == .empty_list) return form.pair.car;
    const rest_and = try datum_mod.cons(arena, try datum_mod.symbol(arena, "and"), form.pair.cdr);
    return try listOf(arena, &.{
        try datum_mod.symbol(arena, "if"), form.pair.car, rest_and, .{ .boolean = false },
    });
}

/// `(or)` → `#f`; `(or e)` → `e`; `(or e r ...)` →
/// `((lambda (t) (if t t (or r ...))) e)` where `t` has a leading space, so
/// the reader can never produce it — expansion-hygiene on the cheap.
pub fn expandOr(arena: std.mem.Allocator, form: Datum) Error!Datum {
    if (form == .empty_list) return .{ .boolean = false };
    if (form != .pair) return error.BadSyntax;
    if (form.pair.cdr == .empty_list) return form.pair.car;
    const tmp = try datum_mod.symbol(arena, " or-tmp");
    const rest_or = try datum_mod.cons(arena, try datum_mod.symbol(arena, "or"), form.pair.cdr);
    const if_form = try listOf(arena, &.{ try datum_mod.symbol(arena, "if"), tmp, tmp, rest_or });
    const lambda_form = try listOf(arena, &.{
        try datum_mod.symbol(arena, "lambda"),
        try listOf(arena, &.{tmp}),
        if_form,
    });
    return try listOf(arena, &.{ lambda_form, form.pair.car });
}

/// Parsed `((n e) ...)` binding list; names are distinct symbols. Shared by
/// both engines' native `letrec` (§2 "Derived forms II").
pub const Bindings = struct {
    names: []const []const u8,
    inits: []const Datum,
};

pub fn parseBindings(arena: std.mem.Allocator, bindings: Datum) Error!Bindings {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(arena);
    var inits: std.ArrayList(Datum) = .empty;
    defer inits.deinit(arena);

    var b = bindings;
    while (b == .pair) : (b = b.pair.cdr) {
        const binding = b.pair.car;
        if (binding != .pair or binding.pair.car != .symbol) return error.BadSyntax;
        if (binding.pair.cdr != .pair or binding.pair.cdr.pair.cdr != .empty_list)
            return error.BadSyntax;
        const name = binding.pair.car.symbol;
        for (names.items) |seen|
            if (std.mem.eql(u8, seen, name)) return error.BadSyntax;
        try names.append(arena, name);
        try inits.append(arena, binding.pair.cdr.pair.car);
    }
    if (b != .empty_list) return error.BadSyntax;
    return .{
        .names = try arena.dupe([]const u8, names.items),
        .inits = try arena.dupe(Datum, inits.items),
    };
}

/// Wraps a non-empty expression list: single expression stays bare, several
/// become `(begin ...)`.
fn beginOf(arena: std.mem.Allocator, exprs: Datum) Error!Datum {
    std.debug.assert(exprs == .pair);
    if (exprs.pair.cdr == .empty_list) return exprs.pair.car;
    return try datum_mod.cons(arena, try datum_mod.symbol(arena, "begin"), exprs);
}

fn listOf(arena: std.mem.Allocator, items: []const Datum) Error!Datum {
    return listFrom(arena, items);
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

fn expectExpansionCond(src: []const u8, expected: []const u8) !void {
    const wrap = struct {
        fn f(arena: std.mem.Allocator, form: Datum) Error!Datum {
            return expandCond(arena, form, false);
        }
    }.f;
    try expectExpansion(wrap, src, expected);
}

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

test "named let expands to letrec" {
    try expectExpansion(
        expandLet,
        "(let loop ((n 3) (acc 1)) (if (= n 0) acc (loop (- n 1) (* acc n))))",
        "(letrec ((loop (lambda (n acc) (if (= n 0) acc (loop (- n 1) (* acc n)))))) (loop 3 1))",
    );
}

test "do expands to a loop" {
    try expectExpansion(
        expandDo,
        "(do ((i 0 (+ i 1)) (acc 1)) ((= i 3) acc) 42)",
        "(let  do-loop ((i 0) (acc 1)) (if (= i 3) acc (begin 42 ( do-loop (+ i 1) acc))))",
    );
    try expectExpansion(
        expandDo,
        "(do ((i 0 (+ i 1))) ((= i 3)))",
        "(let  do-loop ((i 0)) (if (= i 3) (if #f #f) ( do-loop (+ i 1))))",
    );
}

test "let* expands to nested lets" {
    try expectExpansion(expandLetStar, "(let* ((x 1) (y x)) y)", "(let ((x 1)) (let* ((y x)) y))");
    try expectExpansion(expandLetStar, "(let* () 5)", "(let () 5)");
}

test "cond, and, or expansions" {
    try expectExpansionCond("(cond (a 1) (else 2))", "(if a 1 2)");
    try expectExpansionCond("(cond (a 1 2))", "(if a (begin 1 2) (if #f #f))");
    try expectExpansion(expandAnd, "(and)", "#t");
    try expectExpansion(expandAnd, "(and x)", "x");
    try expectExpansion(expandAnd, "(and x y)", "(if x (and y) #f)");
    try expectExpansion(expandOr, "(or)", "#f");
    try expectExpansion(expandOr, "(or x)", "x");
    try expectExpansion(expandOr, "(or x y)", "((lambda ( or-tmp) (if  or-tmp  or-tmp (or y))) x)");
}

test "cond shape errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_][]const u8{ "(cond)", "(cond (a))", "(cond (else 1) (a 2))" };
    for (cases) |src| {
        var r = reader_mod.Reader.init(arena, src, 16);
        const d = (try r.read()).?;
        try std.testing.expectError(error.BadSyntax, expandCond(arena, d.pair.cdr, false));
    }
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
