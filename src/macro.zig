//! syntax-rules macros (tier 8I; design in docs/syntax-rules.md). A macro is
//! a keyword transformer stored as `Value.macro`; both engines expand a
//! `(keyword . args)` form through `expand` here at their form-dispatch point,
//! so the matcher never forks between machine and oracle.
//!
//! 8I.2 scope: fixed patterns (no ellipsis), literals, `_`, dotted patterns.
//! Transcription is **non-hygienic** — hygiene (renaming + def_env resolver)
//! lands in 8I.4.

const std = @import("std");
const datum_mod = @import("datum.zig");
const env_mod = @import("env.zig");
const value_mod = @import("value.zig");

const Datum = datum_mod.Datum;

pub const Error = error{ BadSyntax, OutOfMemory };

pub const Rule = struct { pattern: Datum, template: Datum };

/// A parsed `syntax-rules` transformer. `def_env` is recorded for hygiene
/// obligation (b), unused until 8I.4. `ellipsis` is the ellipsis identifier
/// (custom ellipsis is 8I.6; "..." until then).
pub const Macro = struct {
    literals: []const []const u8,
    rules: []const Rule,
    ellipsis: []const u8,
    def_env: *env_mod.Env,
};

/// Casts between the opaque `Value.Macro` and the concrete struct.
pub fn toValue(m: *Macro) value_mod.Value {
    return .{ .macro = @ptrCast(m) };
}
pub fn fromValue(v: value_mod.Value) *Macro {
    return @ptrCast(@alignCast(v.macro));
}

/// Parses `(syntax-rules (literal ...) (pattern template) ...)`. `form` is the
/// whole `syntax-rules` datum. `def_env` is the scope where the macro is
/// defined (hygiene b, 8I.4).
pub fn parse(arena: std.mem.Allocator, form: Datum, def_env: *env_mod.Env) Error!*Macro {
    if (form != .pair or form.pair.car != .symbol or
        !std.mem.eql(u8, form.pair.car.symbol, "syntax-rules")) return error.BadSyntax;
    var rest = form.pair.cdr;
    if (rest != .pair) return error.BadSyntax;

    // literals list
    var literals: std.ArrayList([]const u8) = .empty;
    defer literals.deinit(arena);
    var lits = rest.pair.car;
    while (lits == .pair) : (lits = lits.pair.cdr) {
        if (lits.pair.car != .symbol) return error.BadSyntax;
        try literals.append(arena, lits.pair.car.symbol);
    }
    if (lits != .empty_list) return error.BadSyntax;
    rest = rest.pair.cdr;

    // rules
    var rules: std.ArrayList(Rule) = .empty;
    defer rules.deinit(arena);
    while (rest == .pair) : (rest = rest.pair.cdr) {
        const rule = rest.pair.car;
        if (rule != .pair or rule.pair.cdr != .pair or rule.pair.cdr.pair.cdr != .empty_list)
            return error.BadSyntax;
        // the pattern's leading element is the keyword slot; it must be a
        // pair whose car is a symbol (R5RS)
        if (rule.pair.car != .pair or rule.pair.car.pair.car != .symbol) return error.BadSyntax;
        try rules.append(arena, .{ .pattern = rule.pair.car, .template = rule.pair.cdr.pair.car });
    }
    if (rest != .empty_list) return error.BadSyntax;

    const m = try arena.create(Macro);
    m.* = .{
        .literals = try arena.dupe([]const u8, literals.items),
        .rules = try arena.dupe(Rule, rules.items),
        .ellipsis = "...",
        .def_env = def_env,
    };
    return m;
}

/// `(define-syntax name (syntax-rules ...))`: parse the transformer and bind
/// `name` as a macro keyword in `scope`. Shared by both engines (§2).
pub fn defineSyntax(arena: std.mem.Allocator, rest: Datum, scope: *env_mod.Env) Error!void {
    if (rest != .pair or rest.pair.car != .symbol) return error.BadSyntax;
    if (rest.pair.cdr != .pair or rest.pair.cdr.pair.cdr != .empty_list) return error.BadSyntax;
    const name = rest.pair.car.symbol;
    const m = try parse(arena, rest.pair.cdr.pair.car, scope);
    try scope.define(name, toValue(m));
}

/// If `form` is `(kw . args)` with `kw` a symbol bound to a macro in `env`,
/// returns that macro; else null. The caller expands and re-evaluates.
pub fn lookupMacro(form: Datum, env: *const env_mod.Env) ?*Macro {
    if (form != .pair or form.pair.car != .symbol) return null;
    const v = env.lookup(form.pair.car.symbol) orelse return null;
    return if (v == .macro) fromValue(v) else null;
}

const Bindings = std.StringHashMapUnmanaged(Datum);

fn isLiteral(m: *const Macro, name: []const u8) bool {
    for (m.literals) |lit| if (std.mem.eql(u8, lit, name)) return true;
    return false;
}

/// Expands one macro use. `form` is the whole `(keyword . args)`. Tries each
/// rule in order; the first matching pattern transcribes.
pub fn expand(arena: std.mem.Allocator, m: *const Macro, form: Datum) Error!Datum {
    for (m.rules) |rule| {
        var binds: Bindings = .empty;
        defer binds.deinit(arena);
        // The keyword slot (pattern car / form car) is ignored in matching.
        if (try match(arena, m, rule.pattern.pair.cdr, form.pair.cdr, &binds))
            return transcribe(arena, m, rule.template, &binds);
    }
    return error.BadSyntax; // no rule matched
}

/// Matches `pat` against `inp`, binding pattern variables into `binds`.
/// Fixed patterns only (no ellipsis in 8I.2).
fn match(arena: std.mem.Allocator, m: *const Macro, pat: Datum, inp: Datum, binds: *Bindings) Error!bool {
    switch (pat) {
        .symbol => |name| {
            if (std.mem.eql(u8, name, "_")) return true; // wildcard
            if (isLiteral(m, name))
                return inp == .symbol and std.mem.eql(u8, inp.symbol, name);
            try binds.put(arena, name, inp); // pattern variable
            return true;
        },
        .pair => |pp| {
            if (inp != .pair) return false;
            if (!try match(arena, m, pp.car, inp.pair.car, binds)) return false;
            return match(arena, m, pp.cdr, inp.pair.cdr, binds);
        },
        .empty_list => return inp == .empty_list,
        .vector => |pv| {
            if (inp != .vector or inp.vector.len != pv.len) return false;
            for (pv, inp.vector) |pe, ie|
                if (!try match(arena, m, pe, ie, binds)) return false;
            return true;
        },
        // self-matching literals (numbers, booleans, chars, strings)
        else => return selfMatch(pat, inp),
    }
}

/// Constant patterns (numbers/booleans/chars/strings) match an equal input.
fn selfMatch(pat: Datum, inp: Datum) bool {
    return switch (pat) {
        .integer => inp == .integer and inp.integer == pat.integer,
        .real => inp == .real and inp.real == pat.real,
        .boolean => inp == .boolean and inp.boolean == pat.boolean,
        .char => inp == .char and inp.char == pat.char,
        .string => inp == .string and std.mem.eql(u8, inp.string, pat.string),
        else => false,
    };
}

// -- tests ----------------------------------------------------------------

const eval_mod = @import("eval.zig");

test "define-syntax fixed patterns (oracle)" {
    var s = eval_mod.TestSession.init();
    defer s.deinit();

    _ = try s.run("(define-syntax my-if (syntax-rules () ((_ c a b) (cond (c a) (else b)))))");
    try std.testing.expectEqualStrings("yes", (try s.run("(my-if #t 'yes 'no)")).symbol);
    try std.testing.expectEqualStrings("no", (try s.run("(my-if #f 'yes 'no)")).symbol);

    // multiple rules, first match wins; literal keyword
    _ = try s.run(
        \\(define-syntax classify
        \\  (syntax-rules (zero)
        \\    ((_ zero) 'is-zero)
        \\    ((_ x) 'other)))
    );
    try std.testing.expectEqualStrings("is-zero", (try s.run("(classify zero)")).symbol);
    try std.testing.expectEqualStrings("other", (try s.run("(classify 5)")).symbol);

    // no rule matches → BadSyntax
    _ = try s.run("(define-syntax only2 (syntax-rules () ((_ a b) (list a b))))");
    try std.testing.expectError(error.BadSyntax, s.run("(only2 1)"));

    // a keyword used as a value is a syntax error
    try std.testing.expectError(error.BadSyntax, s.run("only2"));
}

/// Copies `tmpl`, substituting pattern variables. Non-hygienic (8I.2):
/// introduced identifiers pass through unrenamed.
fn transcribe(arena: std.mem.Allocator, m: *const Macro, tmpl: Datum, binds: *Bindings) Error!Datum {
    switch (tmpl) {
        .symbol => |name| return binds.get(name) orelse tmpl,
        .pair => |p| return datum_mod.cons(
            arena,
            try transcribe(arena, m, p.car, binds),
            try transcribe(arena, m, p.cdr, binds),
        ),
        .vector => |items| {
            const out = try arena.alloc(Datum, items.len);
            for (items, out) |item, *o| o.* = try transcribe(arena, m, item, binds);
            return .{ .vector = out };
        },
        else => return tmpl,
    }
}
