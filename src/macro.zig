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

/// A matched pattern variable's value, carrying ellipsis depth: a `single`
/// datum at depth 0, or a `seq` of sub-matches per enclosing ellipsis level.
const Match = union(enum) { single: Datum, seq: []Match };

const Bindings = std.StringHashMapUnmanaged(Match);

fn isLiteral(m: *const Macro, name: []const u8) bool {
    for (m.literals) |lit| if (std.mem.eql(u8, lit, name)) return true;
    return false;
}

fn isEllipsis(m: *const Macro, d: Datum) bool {
    return d == .symbol and std.mem.eql(u8, d.symbol, m.ellipsis);
}

/// Collects the pattern-variable names in `pat` (not literals, `_`, or the
/// ellipsis) so ellipsis matching can seed every enclosed variable even with
/// zero repetitions.
fn collectVars(arena: std.mem.Allocator, m: *const Macro, pat: Datum, out: *std.ArrayList([]const u8)) Error!void {
    switch (pat) {
        .symbol => |name| {
            if (std.mem.eql(u8, name, "_") or isLiteral(m, name) or isEllipsis(m, pat)) return;
            for (out.items) |seen| if (std.mem.eql(u8, seen, name)) return;
            try out.append(arena, name);
        },
        .pair => |p| {
            try collectVars(arena, m, p.car, out);
            try collectVars(arena, m, p.cdr, out);
        },
        .vector => |items| for (items) |it| try collectVars(arena, m, it, out),
        else => {},
    }
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
/// Supports one ellipsis per list level with tail patterns after it, plus
/// dotted and vector patterns (tier 8I.3).
fn match(arena: std.mem.Allocator, m: *const Macro, pat: Datum, inp: Datum, binds: *Bindings) Error!bool {
    switch (pat) {
        .symbol => |name| {
            if (std.mem.eql(u8, name, "_")) return true; // wildcard
            if (isLiteral(m, name))
                return inp == .symbol and std.mem.eql(u8, inp.symbol, name);
            try binds.put(arena, name, .{ .single = inp }); // pattern variable
            return true;
        },
        .pair => |pp| {
            if (pp.cdr == .pair and isEllipsis(m, pp.cdr.pair.car))
                return matchEllipsis(arena, m, pp.car, pp.cdr.pair.cdr, inp, binds);
            if (inp != .pair) return false;
            if (!try match(arena, m, pp.car, inp.pair.car, binds)) return false;
            return match(arena, m, pp.cdr, inp.pair.cdr, binds);
        },
        .empty_list => return inp == .empty_list,
        .vector => |pv| {
            if (inp != .vector) return false;
            return matchVectorSpine(arena, m, pv, inp.vector, binds);
        },
        // self-matching literals (numbers, booleans, chars, strings)
        else => return selfMatch(pat, inp),
    }
}

/// `subpat ... after`: `subpat` matches the leading input items, `after`
/// (fixed tail patterns, possibly dotted) matches the rest.
fn matchEllipsis(arena: std.mem.Allocator, m: *const Macro, subpat: Datum, after: Datum, inp: Datum, binds: *Bindings) Error!bool {
    var after_count: usize = 0;
    var at = after;
    while (at == .pair) : (at = at.pair.cdr) after_count += 1;

    var items: std.ArrayList(Datum) = .empty;
    defer items.deinit(arena);
    var it = inp;
    while (it == .pair) : (it = it.pair.cdr) try items.append(arena, it.pair.car);
    const inp_tail = it;
    if (items.items.len < after_count) return false;
    const n_ell = items.items.len - after_count;

    // Each variable in subpat binds to a seq of its per-iteration match.
    var vars: std.ArrayList([]const u8) = .empty;
    defer vars.deinit(arena);
    try collectVars(arena, m, subpat, &vars);
    const cols = try arena.alloc(std.ArrayList(Match), vars.items.len);
    for (cols) |*c| c.* = .empty;

    for (0..n_ell) |i| {
        var sub: Bindings = .empty;
        defer sub.deinit(arena);
        if (!try match(arena, m, subpat, items.items[i], &sub)) return false;
        for (vars.items, cols) |v, *col|
            try col.append(arena, sub.get(v) orelse .{ .single = .empty_list });
    }
    for (vars.items, 0..) |v, ci|
        try binds.put(arena, v, .{ .seq = try cols[ci].toOwnedSlice(arena) });

    // Match the tail patterns against the remaining items + input tail.
    var rest = inp_tail;
    var k = items.items.len;
    while (k > n_ell) {
        k -= 1;
        rest = try datum_mod.cons(arena, items.items[k], rest);
    }
    return match(arena, m, after, rest, binds);
}

fn matchVectorSpine(arena: std.mem.Allocator, m: *const Macro, pv: []const Datum, iv: []const Datum, binds: *Bindings) Error!bool {
    // Rebuild both as lists and reuse list matching (handles vector ellipsis).
    var pl: Datum = .empty_list;
    var i = pv.len;
    while (i > 0) : (i -= 1) pl = try datum_mod.cons(arena, pv[i - 1], pl);
    var il: Datum = .empty_list;
    var j = iv.len;
    while (j > 0) : (j -= 1) il = try datum_mod.cons(arena, iv[j - 1], il);
    return match(arena, m, pl, il, binds);
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

test "syntax-rules ellipsis (oracle)" {
    var s = eval_mod.TestSession.init();
    defer s.deinit();

    _ = try s.run("(define-syntax my-list (syntax-rules () ((_ x ...) (list x ...))))");
    try std.testing.expectEqual(@as(i64, 3), (try s.run("(car (cdr (cdr (my-list 1 2 3))))")).integer);
    try std.testing.expect((try s.run("(my-list)")) == .empty_list); // zero reps

    // parallel ellipses (the let shape)
    _ = try s.run(
        \\(define-syntax my-let
        \\  (syntax-rules ()
        \\    ((_ ((n v) ...) body ...) ((lambda (n ...) body ...) v ...))))
    );
    try std.testing.expectEqual(@as(i64, 3), (try s.run("(my-let ((a 1) (b 2)) (+ a b))")).integer);

    // tail pattern after the ellipsis
    _ = try s.run("(define-syntax lastf (syntax-rules () ((_ a rest ... z) (list z a))))");
    const lf = try s.run("(lastf 1 2 3 4)");
    try std.testing.expectEqual(@as(i64, 4), lf.pair.car.integer);
    try std.testing.expectEqual(@as(i64, 1), lf.pair.cdr.pair.car.integer);

    // a template var used with too few ellipses is a syntax error
    _ = try s.run("(define-syntax bad (syntax-rules () ((_ x ...) x)))");
    try std.testing.expectError(error.BadSyntax, s.run("(bad 1 2)"));
}

/// Copies `tmpl`, substituting pattern variables and expanding ellipses.
/// Non-hygienic (renaming lands in 8I.4).
fn transcribe(arena: std.mem.Allocator, m: *const Macro, tmpl: Datum, binds: *Bindings) Error!Datum {
    switch (tmpl) {
        .symbol => |name| {
            const b = binds.get(name) orelse return tmpl;
            if (b != .single) return error.BadSyntax; // used with too few ellipses
            return b.single;
        },
        .pair => |p| {
            // `sub ... rest`: expand sub once per matched element, then rest.
            if (p.cdr == .pair and isEllipsis(m, p.cdr.pair.car)) {
                var depth: usize = 1;
                var after = p.cdr.pair.cdr;
                while (after == .pair and isEllipsis(m, after.pair.car)) : (after = after.pair.cdr) depth += 1;
                var expanded: std.ArrayList(Datum) = .empty;
                defer expanded.deinit(arena);
                try expandEllipsis(arena, m, p.car, binds, depth, &expanded);
                var rest = try transcribe(arena, m, after, binds);
                var i = expanded.items.len;
                while (i > 0) : (i -= 1) rest = try datum_mod.cons(arena, expanded.items[i - 1], rest);
                return rest;
            }
            return datum_mod.cons(
                arena,
                try transcribe(arena, m, p.car, binds),
                try transcribe(arena, m, p.cdr, binds),
            );
        },
        .vector => |items| {
            // Transcribe as a list (to expand ellipses), then collect back.
            var lst: Datum = .empty_list;
            var i = items.len;
            while (i > 0) : (i -= 1) lst = try datum_mod.cons(arena, items[i - 1], lst);
            const out_lst = try transcribe(arena, m, lst, binds);
            var out: std.ArrayList(Datum) = .empty;
            defer out.deinit(arena);
            var node = out_lst;
            while (node == .pair) : (node = node.pair.cdr) try out.append(arena, node.pair.car);
            return .{ .vector = try out.toOwnedSlice(arena) };
        },
        else => return tmpl,
    }
}

/// Expands `sub ...` (`depth` ellipses) into `out`. Controlling variables are
/// the pattern vars in `sub` bound to a `seq`; all must share a length.
fn expandEllipsis(arena: std.mem.Allocator, m: *const Macro, sub: Datum, binds: *Bindings, depth: usize, out: *std.ArrayList(Datum)) Error!void {
    var vars: std.ArrayList([]const u8) = .empty;
    defer vars.deinit(arena);
    try collectVars(arena, m, sub, &vars);

    var len: ?usize = null;
    for (vars.items) |v| {
        if (binds.get(v)) |b| if (b == .seq) {
            if (len) |l| {
                if (l != b.seq.len) return error.BadSyntax; // mismatched ellipsis lengths
            } else len = b.seq.len;
        };
    }
    const count = len orelse return error.BadSyntax; // no controlling variable

    for (0..count) |i| {
        var sub_binds: Bindings = .empty;
        defer sub_binds.deinit(arena);
        var iter = binds.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            var controls = false;
            for (vars.items) |v| if (std.mem.eql(u8, v, name)) {
                controls = true;
            };
            if (controls and entry.value_ptr.* == .seq)
                try sub_binds.put(arena, name, entry.value_ptr.seq[i])
            else
                try sub_binds.put(arena, name, entry.value_ptr.*);
        }
        if (depth > 1)
            try expandEllipsis(arena, m, sub, &sub_binds, depth - 1, out)
        else
            try out.append(arena, try transcribe(arena, m, sub, &sub_binds));
    }
}
