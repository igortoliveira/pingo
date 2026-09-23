//! syntax-rules macros (tier 8I; design in docs/syntax-rules.md). A macro is
//! a keyword transformer stored as `Value.macro`; both engines expand a
//! `(keyword . args)` form through `expand` here at their form-dispatch point,
//! so the matcher never forks between machine and oracle.
//!
//! Hygiene (8I.4): every template identifier that is not a pattern variable
//! and not a syntactic keyword is renamed to a per-expansion alias registered
//! against the macro's definition scope (`Env.registerAlias`). Introduced
//! binders then can't capture, and free references stay transparent — resolved
//! at use time through `Env.lookup`'s alias fallback.

const std = @import("std");
const datum_mod = @import("../syntax/datum.zig");
const env_mod = @import("../runtime/env.zig");
const value_mod = @import("../runtime/value.zig");

const Datum = datum_mod.Datum;

pub const Error = error{ BadSyntax, OutOfMemory };

pub const Rule = struct { pattern: Datum, template: Datum };

/// Syntactic keywords never renamed by hygiene: core forms, derived forms,
/// and contextual keywords interpreted by name in the expanders (`else`,
/// `=>`, quasiquote parts). Everything else in a template is either a pattern
/// variable (substituted) or an introduced identifier (renamed).
const keywords = [_][]const u8{
    "quote",      "if",             "define",         "lambda",
    "begin",      "set!",           "let",            "let*",
    "letrec",     "cond",           "case",           "and",
    "or",         "do",             "delay",          "quasiquote",
    "unquote",    "unquote-splicing", "define-syntax", "let-syntax",
    "letrec-syntax", "else",        "=>",
};

fn isKeyword(name: []const u8) bool {
    for (keywords) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

/// If `name` is a macro alias whose underlying identifier is a syntactic
/// keyword, returns that keyword name so form dispatch can recognize it;
/// otherwise null (plain keywords need no rewrite; non-keyword aliases stay
/// aliases and resolve as values). Chases alias chains.
pub fn unwrapKeyword(env: *const env_mod.Env, name: []const u8) ?[]const u8 {
    var cur = name;
    var chased = false;
    while (env.aliasOf(cur)) |ai| {
        cur = ai.original;
        chased = true;
    }
    if (!chased) return null;
    return if (isKeyword(cur)) cur else null;
}

/// A parsed `syntax-rules` transformer. `def_env` is the scope the macro was
/// defined in (hygiene b). `ellipsis` is the ellipsis identifier (custom
/// ellipsis is 8I.6; "..." until then).
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

/// Parses `(syntax-rules (literal ...) (pattern template) ...)` — or, with a
/// custom ellipsis, `(syntax-rules ellipsis (literal ...) ...)` (tier 8I.6).
/// `form` is the whole `syntax-rules` datum; `def_env` is the definition scope.
pub fn parse(arena: std.mem.Allocator, form: Datum, def_env: *env_mod.Env) Error!*Macro {
    if (form != .pair or form.pair.car != .symbol or
        !std.mem.eql(u8, form.pair.car.symbol, "syntax-rules")) return error.BadSyntax;
    var rest = form.pair.cdr;
    if (rest != .pair) return error.BadSyntax;

    // Custom ellipsis: a symbol in place of the literals list.
    var ellipsis: []const u8 = "...";
    if (rest.pair.car == .symbol) {
        ellipsis = rest.pair.car.symbol;
        rest = rest.pair.cdr;
        if (rest != .pair) return error.BadSyntax;
    }

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
        .ellipsis = ellipsis,
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

/// Binds the `((kw transformer) ...)` of a `let-syntax`/`letrec-syntax` into
/// `target` (the body scope). Transformers see `def_env`: the outer scope for
/// `let-syntax`, the body scope itself for `letrec-syntax` (§2, tier 8I.5).
/// Returns the body datum list (after the bindings).
pub fn bindSyntax(arena: std.mem.Allocator, rest: Datum, target: *env_mod.Env, def_env: *env_mod.Env) Error!Datum {
    if (rest != .pair) return error.BadSyntax; // ((kw tx) ...) body ...
    var b = rest.pair.car;
    while (b == .pair) : (b = b.pair.cdr) {
        const binding = b.pair.car;
        if (binding != .pair or binding.pair.car != .symbol) return error.BadSyntax;
        if (binding.pair.cdr != .pair or binding.pair.cdr.pair.cdr != .empty_list) return error.BadSyntax;
        const m = try parse(arena, binding.pair.cdr.pair.car, def_env);
        try target.define(binding.pair.car.symbol, toValue(m));
    }
    if (b != .empty_list) return error.BadSyntax;
    return rest.pair.cdr; // the body
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

/// Transcription context: the macro, the per-expansion rename map
/// (original → alias), and the session mark counter for fresh aliases.
const Ctx = struct {
    arena: std.mem.Allocator,
    m: *const Macro,
    renames: *std.StringHashMapUnmanaged([]const u8),
    counter: *u64,
};

/// Expands one macro use. `form` is the whole `(keyword . args)`. Tries each
/// rule in order; the first matching pattern transcribes. `counter` supplies
/// fresh hygiene marks (session-monotonic).
pub fn expand(arena: std.mem.Allocator, m: *const Macro, form: Datum, counter: *u64) Error!Datum {
    for (m.rules) |rule| {
        var binds: Bindings = .empty;
        defer binds.deinit(arena);
        // The keyword slot (pattern car / form car) is ignored in matching.
        if (try match(arena, m, rule.pattern.pair.cdr, form.pair.cdr, &binds)) {
            var renames: std.StringHashMapUnmanaged([]const u8) = .empty;
            defer renames.deinit(arena);
            var ctx = Ctx{ .arena = arena, .m = m, .renames = &renames, .counter = counter };
            return transcribe(&ctx, rule.template, &binds, false);
        }
    }
    return error.BadSyntax; // no rule matched
}

/// Renames an introduced identifier (§8I.4): pattern-substituted names and
/// keywords are left alone by the caller; everything else gets a per-expansion
/// alias registered against the macro's def scope. The alias spelling starts
/// with a space, so the reader can never produce it.
fn renameIntroduced(ctx: *Ctx, name: []const u8) Error!Datum {
    if (ctx.renames.get(name)) |alias| return .{ .symbol = alias };
    const alias = try std.fmt.allocPrint(ctx.arena, " {s}%{d}", .{ name, ctx.counter.* });
    ctx.counter.* += 1;
    try ctx.renames.put(ctx.arena, try ctx.arena.dupe(u8, name), alias);
    try ctx.m.def_env.registerAlias(alias, name, ctx.m.def_env);
    return .{ .symbol = alias };
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

test "syntax-rules hygiene (oracle)" {
    var s = eval_mod.TestSession.init();
    defer s.deinit();

    // (a) an introduced binder does not capture a user identifier: the macro's
    // temporary `t` must not shadow the `t` the user passes in.
    _ = try s.run("(define-syntax my-or (syntax-rules () ((_ a b) (let ((t a)) (if t t b)))))");
    // hygienic: introduced `t` is #f, so the result is the user's t (5); a
    // captured (non-hygienic) `t` would shadow it and yield #f.
    try std.testing.expectEqual(@as(i64, 5), (try s.run("(let ((t 5)) (my-or #f t))")).integer);

    // (b) a template's free reference stays bound to the definition scope
    // even when the use site shadows the name
    _ = try s.run("(define-syntax wrap (syntax-rules () ((_ a) (list a a))))");
    const w = try s.run("(let ((list (lambda (a b) 'hijacked))) (wrap 9))");
    try std.testing.expectEqual(@as(i64, 9), w.pair.car.integer);

    // forward reference: a template calls a helper defined after the macro
    _ = try s.run("(define-syntax callh (syntax-rules () ((_) (helper))))");
    _ = try s.run("(define (helper) 'ok)");
    try std.testing.expectEqualStrings("ok", (try s.run("(callh)")).symbol);

    // quoted data is never renamed
    _ = try s.run("(define-syntax tagq (syntax-rules () ((_) 'lit)))");
    try std.testing.expectEqualStrings("lit", (try s.run("(tagq)")).symbol);
}

test "let-syntax and letrec-syntax (oracle)" {
    var s = eval_mod.TestSession.init();
    defer s.deinit();

    // local keyword, scoped to the body
    try std.testing.expectEqual(@as(i64, 42), (try s.run(
        "(let-syntax ((dbl (syntax-rules () ((_ x) (+ x x))))) (dbl 21))",
    )).integer);
    // the keyword is not visible outside the let-syntax
    try std.testing.expectError(error.UnboundVariable, s.run("(dbl 1)"));

    // let-syntax transformer sees the use site's lexical bindings
    try std.testing.expectEqual(@as(i64, 10), (try s.run(
        "(let ((x 10)) (let-syntax ((g (syntax-rules () ((_) x)))) (g)))",
    )).integer);

    // letrec-syntax: mutually recursive transformers
    try std.testing.expectEqualStrings("even", (try s.run(
        \\(letrec-syntax
        \\  ((ev (syntax-rules () ((_ n) (if (= n 0) 'even (od (- n 1))))))
        \\   (od (syntax-rules () ((_ n) (if (= n 0) 'odd (ev (- n 1)))))))
        \\  (ev 4))
    )).symbol);
}

test "syntax-rules custom ellipsis and escape (oracle)" {
    var s = eval_mod.TestSession.init();
    defer s.deinit();

    // custom ellipsis: with ::: as the ellipsis, `...` is an ordinary var
    try std.testing.expectEqual(@as(i64, 2), (try s.run(
        "(let-syntax ((foo (syntax-rules ::: () ((foo ... args :::) (args ::: ...))))) (foo 3 - 5))",
    )).integer);

    // the (... x) escape emits a literal ellipsis into the output
    _ = try s.run("(define-syntax lit (syntax-rules () ((_) (quote (a (... ...) b)))))");
    const l = try s.run("(lit)");
    try std.testing.expectEqualStrings("a", l.pair.car.symbol);
    try std.testing.expectEqualStrings("...", l.pair.cdr.pair.car.symbol);
}

/// Copies `tmpl`, substituting pattern variables, expanding ellipses, and
/// renaming introduced identifiers for hygiene (§8I.4). In `data` mode (inside
/// a template `quote`) pattern vars and ellipses still apply, but literal
/// identifiers are left as data — never renamed.
fn transcribe(ctx: *Ctx, tmpl: Datum, binds: *Bindings, data: bool) Error!Datum {
    const arena = ctx.arena;
    const m = ctx.m;
    switch (tmpl) {
        .symbol => |name| {
            if (binds.get(name)) |b| {
                if (b != .single) return error.BadSyntax; // used with too few ellipses
                return b.single;
            }
            if (data or isKeyword(name) or std.mem.eql(u8, name, "_") or isEllipsis(m, tmpl))
                return tmpl; // quoted data, keywords, and the ellipsis pass through
            return renameIntroduced(ctx, name); // introduced identifier
        },
        .pair => |p| {
            // A template `(quote x)`: transcribe x as data (no renaming).
            if (!data and p.car == .symbol and std.mem.eql(u8, p.car.symbol, "quote") and
                p.cdr == .pair)
                return datum_mod.cons(arena, p.car, try transcribe(ctx, p.cdr, binds, true));
            // Escape `(<ellipsis> tmpl)`: emit tmpl with ellipses literal.
            if (isEllipsis(m, p.car) and p.cdr == .pair and p.cdr.pair.cdr == .empty_list)
                return transcribeLiteral(ctx, p.cdr.pair.car, binds, data);
            // `sub ... rest`: expand sub once per matched element, then rest.
            if (p.cdr == .pair and isEllipsis(m, p.cdr.pair.car)) {
                var depth: usize = 1;
                var after = p.cdr.pair.cdr;
                while (after == .pair and isEllipsis(m, after.pair.car)) : (after = after.pair.cdr) depth += 1;
                var expanded: std.ArrayList(Datum) = .empty;
                defer expanded.deinit(arena);
                try expandEllipsis(ctx, p.car, binds, depth, &expanded, data);
                var rest = try transcribe(ctx, after, binds, data);
                var i = expanded.items.len;
                while (i > 0) : (i -= 1) rest = try datum_mod.cons(arena, expanded.items[i - 1], rest);
                return rest;
            }
            return datum_mod.cons(
                arena,
                try transcribe(ctx, p.car, binds, data),
                try transcribe(ctx, p.cdr, binds, data),
            );
        },
        .vector => |items| {
            // Transcribe as a list (to expand ellipses), then collect back.
            var lst: Datum = .empty_list;
            var i = items.len;
            while (i > 0) : (i -= 1) lst = try datum_mod.cons(arena, items[i - 1], lst);
            const out_lst = try transcribe(ctx, lst, binds, data);
            var out: std.ArrayList(Datum) = .empty;
            defer out.deinit(arena);
            var node = out_lst;
            while (node == .pair) : (node = node.pair.cdr) try out.append(arena, node.pair.car);
            return .{ .vector = try out.toOwnedSlice(arena) };
        },
        else => return tmpl,
    }
}

/// Transcribes `tmpl` treating the ellipsis as an ordinary identifier (the
/// `(... x)` escape): pattern vars and renaming still apply, ellipses do not.
fn transcribeLiteral(ctx: *Ctx, tmpl: Datum, binds: *Bindings, data: bool) Error!Datum {
    const arena = ctx.arena;
    const m = ctx.m;
    switch (tmpl) {
        .symbol => |name| {
            if (binds.get(name)) |b| {
                if (b != .single) return error.BadSyntax;
                return b.single;
            }
            if (data or isKeyword(name) or std.mem.eql(u8, name, "_") or isEllipsis(m, tmpl))
                return tmpl;
            return renameIntroduced(ctx, name);
        },
        .pair => |p| return datum_mod.cons(
            arena,
            try transcribeLiteral(ctx, p.car, binds, data),
            try transcribeLiteral(ctx, p.cdr, binds, data),
        ),
        else => return tmpl,
    }
}

/// Expands `sub ...` (`depth` ellipses) into `out`. Controlling variables are
/// the pattern vars in `sub` bound to a `seq`; all must share a length.
fn expandEllipsis(ctx: *Ctx, sub: Datum, binds: *Bindings, depth: usize, out: *std.ArrayList(Datum), data: bool) Error!void {
    const arena = ctx.arena;
    const m = ctx.m;
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
            try expandEllipsis(ctx, sub, &sub_binds, depth - 1, out, data)
        else
            try out.append(arena, try transcribe(ctx, sub, &sub_binds, data));
    }
}
