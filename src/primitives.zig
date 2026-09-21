//! Built-in VM primitives (semantics §1): safe, pure computation only.
//! Anything with authority lives behind host capabilities (Phase 5), never here.

const std = @import("std");
const value_mod = @import("value.zig");
const env_mod = @import("env.zig");

const Value = value_mod.Value;
const PrimitiveError = value_mod.PrimitiveError;

/// Installs all primitives into `scope` (normally the global environment).
pub fn install(scope: *env_mod.Env) std.mem.Allocator.Error!void {
    for (&table) |*p| try scope.define(p.name, .{ .primitive = p });
    try scope.define(apply_primitive.name, .{ .primitive = &apply_primitive });
}

/// `apply` is engine-level (§2): a primitive cannot invoke procedures, so the
/// engines intercept this sentinel by identity and spread the argument list
/// through their ordinary application path. The stub only fires if an engine
/// forgets to intercept.
pub const apply_primitive = Value.Primitive{
    .name = "apply",
    .func = applyStub,
    .strict_args = false, // the target procedure decides strictness
};

fn applyStub(_: std.mem.Allocator, _: []const Value) PrimitiveError!Value {
    return error.TypeError;
}

const table = [_]Value.Primitive{
    .{ .name = "+", .func = add },
    .{ .name = "-", .func = sub },
    .{ .name = "*", .func = mul },
    .{ .name = "/", .func = div },
    .{ .name = "cons", .func = cons, .strict_args = false },
    .{ .name = "car", .func = car },
    .{ .name = "cdr", .func = cdr },
    .{ .name = "null?", .func = isNull },
    .{ .name = "pair?", .func = isPair },
    .{ .name = "eq?", .func = eq },
    // list stores like cons does, so it is equally non-strict (§4).
    .{ .name = "list", .func = list, .strict_args = false },
    .{ .name = "append", .func = append },
    .{ .name = "length", .func = length },
    .{ .name = "not", .func = not },
    .{ .name = "=", .func = numEq },
    .{ .name = "<", .func = lt },
    .{ .name = ">", .func = gt },
    .{ .name = "<=", .func = le },
    .{ .name = ">=", .func = ge },
    .{ .name = "eqv?", .func = eqv },
    .{ .name = "equal?", .func = equalPred },
    .{ .name = "number?", .func = isNumber },
    .{ .name = "complex?", .func = isNumber }, // restricted tower: number = real
    .{ .name = "real?", .func = isNumber },
    .{ .name = "rational?", .func = isRational },
    .{ .name = "integer?", .func = isInteger },
    .{ .name = "exact?", .func = isExact },
    .{ .name = "inexact?", .func = isInexact },
    .{ .name = "exact->inexact", .func = exactToInexact },
    .{ .name = "inexact->exact", .func = inexactToExact },
    .{ .name = "quotient", .func = quotient },
    .{ .name = "remainder", .func = remainder },
    .{ .name = "modulo", .func = modulo },
    .{ .name = "expt", .func = expt },
    .{ .name = "sqrt", .func = sqrtFn },
    .{ .name = "floor", .func = floorFn },
    .{ .name = "ceiling", .func = ceilingFn },
    .{ .name = "truncate", .func = truncateFn },
    .{ .name = "round", .func = roundFn },
    .{ .name = "set-car!", .func = setCar },
    .{ .name = "set-cdr!", .func = setCdr },
    .{ .name = "char?", .func = isChar },
    .{ .name = "char->integer", .func = charToInt },
    .{ .name = "integer->char", .func = intToChar },
    .{ .name = "char-upcase", .func = charUpcase },
    .{ .name = "char-downcase", .func = charDowncase },
    .{ .name = "char-alphabetic?", .func = charAlpha },
    .{ .name = "char-numeric?", .func = charNumeric },
    .{ .name = "char-whitespace?", .func = charWhitespace },
    .{ .name = "char-upper-case?", .func = charUpper },
    .{ .name = "char-lower-case?", .func = charLower },
    .{ .name = "string?", .func = isString },
    .{ .name = "make-string", .func = makeString },
    .{ .name = "string", .func = stringOfChars },
    .{ .name = "string-length", .func = stringLength },
    .{ .name = "string-ref", .func = stringRef },
    .{ .name = "string-set!", .func = stringSet },
    .{ .name = "substring", .func = substringFn },
    .{ .name = "string-append", .func = stringAppend },
    .{ .name = "string-copy", .func = stringCopy },
    .{ .name = "string-fill!", .func = stringFill },
    .{ .name = "string->list", .func = stringToList },
    .{ .name = "list->string", .func = listToString },
    .{ .name = "string=?", .func = strEq },
    .{ .name = "string<?", .func = strLt },
    .{ .name = "string>?", .func = strGt },
    .{ .name = "string<=?", .func = strLe },
    .{ .name = "string>=?", .func = strGe },
    .{ .name = "string-ci=?", .func = strCiEq },
    .{ .name = "symbol?", .func = isSymbol },
    .{ .name = "symbol->string", .func = symbolToString },
    .{ .name = "string->symbol", .func = stringToSymbol },
    .{ .name = "number->string", .func = numberToString },
    .{ .name = "string->number", .func = stringToNumber },
    .{ .name = "boolean?", .func = isBoolean },
    .{ .name = "procedure?", .func = isProcedure },
    .{ .name = "vector?", .func = isVector },
    .{ .name = "make-vector", .func = makeVector },
    // like list/cons, vector only stores — pendings may flow in (§4)
    .{ .name = "vector", .func = vectorOfArgs, .strict_args = false },
    .{ .name = "vector-length", .func = vectorLength },
    .{ .name = "vector-ref", .func = vectorRef },
    .{ .name = "vector-set!", .func = vectorSet },
    .{ .name = "vector->list", .func = vectorToList },
    .{ .name = "list->vector", .func = listToVector },
    .{ .name = "vector-fill!", .func = vectorFill },
};

fn asVector(v: Value) PrimitiveError![]Value {
    return if (v == .vector) v.vector else error.TypeError;
}

fn isVector(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = args[0] == .vector };
}

fn makeVector(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    const k = try asInt(args[0]);
    if (k < 0 or k > 100_000_000) return error.TypeError;
    const fill: Value = if (args.len == 2) args[1] else .unspecified;
    const items = try arena.alloc(Value, @intCast(k));
    @memset(items, fill);
    return .{ .vector = items };
}

fn vectorOfArgs(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return .{ .vector = try arena.dupe(Value, args) };
}

fn vectorLength(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .integer = @intCast((try asVector(args[0])).len) };
}

fn vectorIndex(items: []const Value, v: Value) PrimitiveError!usize {
    const k = try asInt(v);
    if (k < 0 or k >= items.len) return error.TypeError;
    return @intCast(k);
}

fn vectorRef(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    const items = try asVector(args[0]);
    return items[try vectorIndex(items, args[1])];
}

fn vectorSet(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 3);
    const items = try asVector(args[0]);
    items[try vectorIndex(items, args[1])] = args[2];
    return .unspecified;
}

fn vectorToList(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    const items = try asVector(args[0]);
    var result: Value = .empty_list;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const p = try arena.create(Value.Pair);
        p.* = .{ .car = items[i], .cdr = result };
        result = .{ .pair = p };
    }
    return result;
}

fn listToVector(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(arena);
    var rest = args[0];
    var fast = args[0];
    while (rest == .pair) {
        try items.append(arena, rest.pair.car);
        rest = rest.pair.cdr;
        if (fast == .pair) fast = fast.pair.cdr;
        if (fast == .pair) fast = fast.pair.cdr;
        if (rest == .pair and fast == .pair and rest.pair == fast.pair) return error.TypeError;
    }
    if (rest != .empty_list) return error.TypeError;
    return .{ .vector = try arena.dupe(Value, items.items) };
}

fn vectorFill(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    @memset(try asVector(args[0]), args[1]);
    return .unspecified;
}

fn isSymbol(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = args[0] == .symbol };
}

fn isBoolean(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = args[0] == .boolean };
}

fn isProcedure(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = switch (args[0]) {
        .closure, .primitive, .capability => true,
        else => false,
    } };
}

fn symbolToString(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    if (args[0] != .symbol) return error.TypeError;
    return .{ .string = try arena.dupe(u8, args[0].symbol) };
}

fn stringToSymbol(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .symbol = try arena.dupe(u8, try asString(args[0])) };
}

fn radixOf(args: []const Value) PrimitiveError!u8 {
    if (args.len == 1) return 10;
    const r = try asInt(args[1]);
    return switch (r) {
        2, 8, 10, 16 => @intCast(r),
        else => error.TypeError,
    };
}

fn numberToString(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    const radix = try radixOf(args);
    switch (args[0]) {
        .integer => |n| {
            const text = switch (radix) {
                10 => try std.fmt.allocPrint(arena, "{d}", .{n}),
                2 => try std.fmt.allocPrint(arena, "{b}", .{n}),
                8 => try std.fmt.allocPrint(arena, "{o}", .{n}),
                16 => try std.fmt.allocPrint(arena, "{x}", .{n}),
                else => unreachable,
            };
            return .{ .string = text };
        },
        .real => |x| {
            if (radix != 10) return error.TypeError; // R5RS: inexact needs radix 10
            var out = std.Io.Writer.Allocating.init(arena);
            printer_mod.writeReal(x, &out.writer) catch return error.OutOfMemory;
            return .{ .string = out.toOwnedSlice() catch return error.OutOfMemory };
        },
        else => return error.TypeError,
    }
}

/// R5RS: an unparsable string yields #f, not an error.
fn stringToNumber(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    const s = try asString(args[0]);
    const radix = try radixOf(args);
    if (s.len == 0) return .{ .boolean = false };
    if (std.fmt.parseInt(i64, s, radix)) |n| return .{ .integer = n } else |_| {}
    if (radix == 10) {
        // reject symbol-ish inputs parseFloat would take (e.g. "inf")
        var has_digit = false;
        for (s) |c| has_digit = has_digit or std.ascii.isDigit(c);
        if (has_digit) if (std.fmt.parseFloat(f64, s)) |x| return .{ .real = x } else |_| {};
    }
    return .{ .boolean = false };
}

const printer_mod = @import("printer.zig");

fn asString(v: Value) PrimitiveError![]u8 {
    return if (v == .string) v.string else error.TypeError;
}

fn isString(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = args[0] == .string };
}

fn makeString(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    const k = try asInt(args[0]);
    if (k < 0 or k > 100_000_000) return error.TypeError;
    const fill: u8 = if (args.len == 2) try asChar(args[1]) else ' ';
    const bytes = try arena.alloc(u8, @intCast(k));
    @memset(bytes, fill);
    return .{ .string = bytes };
}

fn stringOfChars(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    const bytes = try arena.alloc(u8, args.len);
    for (args, 0..) |a, i| bytes[i] = try asChar(a);
    return .{ .string = bytes };
}

fn stringLength(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .integer = @intCast((try asString(args[0])).len) };
}

fn stringIndex(s: []const u8, v: Value) PrimitiveError!usize {
    const k = try asInt(v);
    if (k < 0 or k >= s.len) return error.TypeError;
    return @intCast(k);
}

fn stringRef(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    const s = try asString(args[0]);
    return .{ .char = s[try stringIndex(s, args[1])] };
}

fn stringSet(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 3);
    const s = try asString(args[0]);
    s[try stringIndex(s, args[1])] = try asChar(args[2]);
    return .unspecified;
}

fn substringFn(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 3);
    const s = try asString(args[0]);
    const start = try asInt(args[1]);
    const end = try asInt(args[2]);
    if (start < 0 or end < start or end > s.len) return error.TypeError;
    return .{ .string = try arena.dupe(u8, s[@intCast(start)..@intCast(end)]) };
}

fn stringAppend(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    var total: usize = 0;
    for (args) |a| total += (try asString(a)).len;
    const bytes = try arena.alloc(u8, total);
    var at: usize = 0;
    for (args) |a| {
        const part = try asString(a);
        @memcpy(bytes[at .. at + part.len], part);
        at += part.len;
    }
    return .{ .string = bytes };
}

fn stringCopy(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .string = try arena.dupe(u8, try asString(args[0])) };
}

fn stringFill(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    @memset(try asString(args[0]), try asChar(args[1]));
    return .unspecified;
}

fn stringToList(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    const s = try asString(args[0]);
    var result: Value = .empty_list;
    var i = s.len;
    while (i > 0) {
        i -= 1;
        const p = try arena.create(Value.Pair);
        p.* = .{ .car = .{ .char = s[i] }, .cdr = result };
        result = .{ .pair = p };
    }
    return result;
}

fn listToString(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    var chars: std.ArrayList(u8) = .empty;
    defer chars.deinit(arena);
    var rest = args[0];
    var fast = args[0];
    while (rest == .pair) {
        try chars.append(arena, try asChar(rest.pair.car));
        rest = rest.pair.cdr;
        if (fast == .pair) fast = fast.pair.cdr;
        if (fast == .pair) fast = fast.pair.cdr;
        if (rest == .pair and fast == .pair and rest.pair == fast.pair) return error.TypeError;
    }
    if (rest != .empty_list) return error.TypeError;
    return .{ .string = try chars.toOwnedSlice(arena) };
}

fn strChain(args: []const Value, comptime op: Cmp, comptime fold: bool) PrimitiveError!Value {
    if (args.len < 2) return error.ArityMismatch;
    var prev = try asString(args[0]);
    for (args[1..]) |a| {
        const cur = try asString(a);
        const order = if (fold) foldedOrder(prev, cur) else std.mem.order(u8, prev, cur);
        const good = switch (op) {
            .eq => order == .eq,
            .lt => order == .lt,
            .gt => order == .gt,
            .le => order != .gt,
            .ge => order != .lt,
        };
        if (!good) return .{ .boolean = false };
        prev = cur;
    }
    return .{ .boolean = true };
}

fn foldedOrder(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        const x = std.ascii.toLower(a[i]);
        const y = std.ascii.toLower(b[i]);
        if (x != y) return if (x < y) .lt else .gt;
    }
    return std.math.order(a.len, b.len);
}

fn strEq(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return strChain(args, .eq, false);
}
fn strLt(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return strChain(args, .lt, false);
}
fn strGt(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return strChain(args, .gt, false);
}
fn strLe(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return strChain(args, .le, false);
}
fn strGe(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return strChain(args, .ge, false);
}
fn strCiEq(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return strChain(args, .eq, true);
}

fn asChar(v: Value) PrimitiveError!u8 {
    return if (v == .char) v.char else error.TypeError;
}

fn isChar(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = args[0] == .char };
}

fn charToInt(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .integer = try asChar(args[0]) };
}

fn intToChar(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    const n = try asInt(args[0]);
    if (n < 0 or n > 255) return error.TypeError; // chars are bytes (§1)
    return .{ .char = @intCast(n) };
}

fn charUpcase(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .char = std.ascii.toUpper(try asChar(args[0])) };
}

fn charDowncase(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .char = std.ascii.toLower(try asChar(args[0])) };
}

fn charPred(args: []const Value, comptime f: fn (u8) bool) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = f(try asChar(args[0])) };
}

fn charAlpha(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return charPred(args, std.ascii.isAlphabetic);
}

fn charNumeric(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return charPred(args, std.ascii.isDigit);
}

fn charWhitespace(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return charPred(args, std.ascii.isWhitespace);
}

fn charUpper(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return charPred(args, std.ascii.isUpper);
}

fn charLower(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return charPred(args, std.ascii.isLower);
}

fn setCar(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    if (args[0] != .pair) return error.TypeError;
    args[0].pair.car = args[1];
    return .unspecified;
}

fn setCdr(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    if (args[0] != .pair) return error.TypeError;
    args[0].pair.cdr = args[1];
    return .unspecified;
}

fn intDiv2(args: []const Value, comptime f: fn (i64, i64) i64) PrimitiveError!Value {
    try exactly(args, 2);
    const a = try asInt(args[0]);
    const b = try asInt(args[1]);
    if (b == 0) return error.DivideByZero;
    if (a == std.math.minInt(i64) and b == -1) return error.IntegerOverflow;
    return .{ .integer = f(a, b) };
}

fn quotient(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return intDiv2(args, struct {
        fn f(a: i64, b: i64) i64 {
            return @divTrunc(a, b);
        }
    }.f);
}

fn remainder(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return intDiv2(args, struct {
        fn f(a: i64, b: i64) i64 {
            return @rem(a, b);
        }
    }.f);
}

fn modulo(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return intDiv2(args, struct {
        fn f(a: i64, b: i64) i64 {
            return @mod(a, b);
        }
    }.f);
}

/// Exact base with non-negative exact exponent stays exact (overflow errors);
/// anything else goes through f64 pow.
fn expt(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    const base = try Num.of(args[0]);
    const expo = try Num.of(args[1]);
    if (base == .int and expo == .int and expo.int >= 0) {
        var acc: i64 = 1;
        var b = base.int;
        var e = expo.int;
        while (e > 0) {
            if (e & 1 == 1) acc = std.math.mul(i64, acc, b) catch return error.IntegerOverflow;
            e >>= 1;
            if (e > 0) b = std.math.mul(i64, b, b) catch return error.IntegerOverflow;
        }
        return .{ .integer = acc };
    }
    return .{ .real = std.math.pow(f64, base.toF(), expo.toF()) };
}

fn sqrtFn(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    const n = try Num.of(args[0]);
    const x = n.toF();
    if (x < 0) return error.TypeError; // no complex numbers (§1)
    const r = @sqrt(x);
    // exact perfect squares stay exact
    if (n == .int and @floor(r) == r and @abs(r) <= 9007199254740992.0) {
        const ri: i64 = @intFromFloat(r);
        if (std.math.mul(i64, ri, ri) catch null == n.int) return .{ .integer = ri };
    }
    return .{ .real = r };
}

fn realUnary(args: []const Value, comptime f: fn (f64) f64) PrimitiveError!Value {
    try exactly(args, 1);
    return switch (args[0]) {
        .integer => args[0], // already integral, stays exact (R5RS)
        .real => |x| .{ .real = f(x) },
        else => error.TypeError,
    };
}

fn floorFn(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return realUnary(args, struct {
        fn f(x: f64) f64 {
            return @floor(x);
        }
    }.f);
}

fn ceilingFn(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return realUnary(args, struct {
        fn f(x: f64) f64 {
            return @ceil(x);
        }
    }.f);
}

fn truncateFn(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return realUnary(args, struct {
        fn f(x: f64) f64 {
            return @trunc(x);
        }
    }.f);
}

fn roundFn(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return realUnary(args, struct {
        // R5RS rounds to even on ties
        fn f(x: f64) f64 {
            const r = @round(x);
            if (@abs(x - @trunc(x)) == 0.5 and @mod(r, 2.0) != 0.0)
                return r - std.math.sign(x);
            return r;
        }
    }.f);
}

fn isNumber(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = args[0] == .integer or args[0] == .real };
}

fn isRational(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = switch (args[0]) {
        .integer => true,
        .real => |x| std.math.isFinite(x),
        else => false,
    } };
}

/// R5RS: an integral real is an integer — (integer? 1.0) is #t.
fn isInteger(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = switch (args[0]) {
        .integer => true,
        .real => |x| std.math.isFinite(x) and @floor(x) == x,
        else => false,
    } };
}

fn isExact(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return switch (args[0]) {
        .integer => .{ .boolean = true },
        .real => .{ .boolean = false },
        else => error.TypeError,
    };
}

fn isInexact(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return switch (args[0]) {
        .integer => .{ .boolean = false },
        .real => .{ .boolean = true },
        else => error.TypeError,
    };
}

fn exactToInexact(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return switch (args[0]) {
        .integer => |n| .{ .real = @floatFromInt(n) },
        .real => args[0],
        else => error.TypeError,
    };
}

fn inexactToExact(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return switch (args[0]) {
        .integer => args[0],
        // no rationals in the restricted tower: only integral reals convert
        .real => |x| if (std.math.isFinite(x) and @floor(x) == x and
            @abs(x) <= 9007199254740992.0)
            .{ .integer = @intFromFloat(x) }
        else
            error.TypeError,
        else => error.TypeError,
    };
}

/// Numeric contagion (§1): integer with integer stays exact; anything
/// touching a real goes through f64.
const Num = union(enum) {
    int: i64,
    real: f64,

    fn of(v: Value) PrimitiveError!Num {
        return switch (v) {
            .integer => |n| .{ .int = n },
            .real => |x| .{ .real = x },
            else => error.TypeError,
        };
    }

    fn toF(n: Num) f64 {
        return switch (n) {
            .int => |i| @floatFromInt(i),
            .real => |x| x,
        };
    }

    fn value(n: Num) Value {
        return switch (n) {
            .int => |i| .{ .integer = i },
            .real => |x| .{ .real = x },
        };
    }
};

const Cmp = enum { eq, lt, gt, le, ge };

fn compare(args: []const Value, comptime op: Cmp) PrimitiveError!Value {
    if (args.len < 2) return error.ArityMismatch;
    var prev = try Num.of(args[0]);
    for (args[1..]) |a| {
        const cur = try Num.of(a);
        const good = if (prev == .int and cur == .int) switch (op) {
            .eq => prev.int == cur.int,
            .lt => prev.int < cur.int,
            .gt => prev.int > cur.int,
            .le => prev.int <= cur.int,
            .ge => prev.int >= cur.int,
        } else switch (op) {
            // mixed comparisons pass through f64 (§1: 2^53 restriction)
            .eq => prev.toF() == cur.toF(),
            .lt => prev.toF() < cur.toF(),
            .gt => prev.toF() > cur.toF(),
            .le => prev.toF() <= cur.toF(),
            .ge => prev.toF() >= cur.toF(),
        };
        if (!good) return .{ .boolean = false };
        prev = cur;
    }
    return .{ .boolean = true };
}

fn numEq(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return compare(args, .eq);
}

fn lt(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return compare(args, .lt);
}

fn gt(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return compare(args, .gt);
}

fn le(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return compare(args, .le);
}

fn ge(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return compare(args, .ge);
}

/// §2 "Equivalence predicates": eqv? is identical to eq? in v0.
fn eqv(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    return .{ .boolean = eqValues(args[0], args[1]) };
}

/// §2: structural — pairs recursively, strings by content, else eqv?.
/// Cycle-safe (§1): the cdr spine is iterated under a node budget and the car
/// side is depth-capped; exceeding either bound errors (never diverges).
pub fn equalValues(a: Value, b: Value) bool {
    return equalValuesChecked(a, b) catch false;
}

pub fn equalValuesChecked(a: Value, b: Value) error{LimitExceeded}!bool {
    var budget: usize = 1_000_000;
    return equalInner(a, b, 0, &budget);
}

fn equalInner(a0: Value, b0: Value, depth: usize, budget: *usize) error{LimitExceeded}!bool {
    if (depth > 4_000) return error.LimitExceeded;
    var a = a0;
    var b = b0;
    while (true) {
        if (budget.* == 0) return error.LimitExceeded;
        budget.* -= 1;
        if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) return false;
        switch (a) {
            .string => return std.mem.eql(u8, a.string, b.string),
            .vector => {
                if (a.vector.ptr == b.vector.ptr) return true;
                if (a.vector.len != b.vector.len) return false;
                for (a.vector, b.vector) |x, y|
                    if (!try equalInner(x, y, depth + 1, budget)) return false;
                return true;
            },
            .pair => {
                if (a.pair == b.pair) return true; // same cell (incl. shared cycles)
                if (!try equalInner(a.pair.car, b.pair.car, depth + 1, budget)) return false;
                a = a.pair.cdr;
                b = b.pair.cdr;
            },
            else => return eqValues(a, b),
        }
    }
}

fn equalPred(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    return .{ .boolean = equalValuesChecked(args[0], args[1]) catch return error.LimitExceeded };
}

fn list(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    var result: Value = .empty_list;
    var i = args.len;
    while (i > 0) {
        i -= 1;
        const p = try arena.create(Value.Pair);
        p.* = .{ .car = args[i], .cdr = result };
        result = .{ .pair = p };
    }
    return result;
}

fn append(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    if (args.len == 0) return .empty_list;
    var result = args[args.len - 1]; // tail is shared, per R5RS
    var i = args.len - 1;
    while (i > 0) {
        i -= 1;
        // copy the spine of args[i], splicing `result` as its tail
        var items: std.ArrayList(Value) = .empty;
        defer items.deinit(arena);
        var rest = args[i];
        var fast = args[i];
        while (rest == .pair) {
            try items.append(arena, rest.pair.car);
            rest = rest.pair.cdr;
            // Floyd: reject cyclic arguments instead of diverging (§1)
            if (fast == .pair) fast = fast.pair.cdr;
            if (fast == .pair) fast = fast.pair.cdr;
            if (rest == .pair and fast == .pair and rest.pair == fast.pair)
                return error.TypeError;
        }
        if (rest != .empty_list) return error.TypeError; // proper lists only
        var j = items.items.len;
        while (j > 0) {
            j -= 1;
            const p = try arena.create(Value.Pair);
            p.* = .{ .car = items.items[j], .cdr = result };
            result = .{ .pair = p };
        }
    }
    return result;
}

fn length(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    // Floyd: a cyclic list is not a proper list (§1 "Cycles").
    var slow = args[0];
    var fast = args[0];
    var n: i64 = 0;
    while (fast == .pair) {
        fast = fast.pair.cdr;
        n += 1;
        if (fast != .pair) break;
        fast = fast.pair.cdr;
        n += 1;
        slow = slow.pair.cdr;
        if (fast == .pair and fast.pair == slow.pair) return error.TypeError;
    }
    if (fast != .empty_list) return error.TypeError;
    return .{ .integer = n };
}

fn not(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = !value_mod.isTruthy(args[0]) };
}

fn exactly(args: []const Value, n: usize) PrimitiveError!void {
    if (args.len != n) return error.ArityMismatch;
}

fn asInt(v: Value) PrimitiveError!i64 {
    return switch (v) {
        .integer => |n| n,
        else => error.TypeError,
    };
}

fn accumulate(
    args: []const Value,
    start: Num,
    comptime intOp: fn (i64, i64) error{Overflow}!i64,
    comptime realOp: fn (f64, f64) f64,
) PrimitiveError!Value {
    var acc = start;
    for (args) |a| {
        const cur = try Num.of(a);
        if (acc == .int and cur == .int) {
            const r = intOp(acc.int, cur.int) catch return error.IntegerOverflow;
            acc = .{ .int = r };
        } else {
            // note: compute first — `acc = .{ .real = f(acc...) }` may clobber
            // acc before reading it (result location semantics)
            const r = realOp(acc.toF(), cur.toF());
            acc = .{ .real = r };
        }
    }
    return acc.value();
}

const addI = struct {
    fn f(a: i64, b: i64) error{Overflow}!i64 {
        return std.math.add(i64, a, b);
    }
}.f;
const subI = struct {
    fn f(a: i64, b: i64) error{Overflow}!i64 {
        return std.math.sub(i64, a, b);
    }
}.f;
const mulI = struct {
    fn f(a: i64, b: i64) error{Overflow}!i64 {
        return std.math.mul(i64, a, b);
    }
}.f;
const addR = struct {
    fn f(a: f64, b: f64) f64 {
        return a + b;
    }
}.f;
const subR = struct {
    fn f(a: f64, b: f64) f64 {
        return a - b;
    }
}.f;
const mulR = struct {
    fn f(a: f64, b: f64) f64 {
        return a * b;
    }
}.f;

fn add(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return accumulate(args, .{ .int = 0 }, addI, addR);
}

fn sub(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    if (args.len == 0) return error.ArityMismatch;
    const first = try Num.of(args[0]);
    if (args.len == 1) return switch (first) { // unary negation
        .int => |i| .{ .integer = std.math.negate(i) catch return error.IntegerOverflow },
        .real => |x| .{ .real = -x },
    };
    return accumulate(args[1..], first, subI, subR);
}

fn mul(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    return accumulate(args, .{ .int = 1 }, mulI, mulR);
}

fn cons(arena: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    const p = try arena.create(Value.Pair);
    p.* = .{ .car = args[0], .cdr = args[1] };
    return .{ .pair = p };
}

fn car(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return if (args[0] == .pair) args[0].pair.car else error.TypeError;
}

fn cdr(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return if (args[0] == .pair) args[0].pair.cdr else error.TypeError;
}

fn isNull(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = args[0] == .empty_list };
}

fn isPair(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 1);
    return .{ .boolean = args[0] == .pair };
}

/// Identity comparison: immediates by value, symbols by name (v0 does not
/// intern), heap objects (pairs, strings, closures, primitives) by identity.
pub fn eqValues(a: Value, b: Value) bool {
    if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) return false;
    return switch (a) {
        .integer => a.integer == b.integer,
        // R5RS eqv?: both inexact and numerically equal (NaN != NaN).
        .real => a.real == b.real,
        .char => a.char == b.char,
        .boolean => a.boolean == b.boolean,
        .symbol => std.mem.eql(u8, a.symbol, b.symbol),
        .string => a.string.ptr == b.string.ptr and a.string.len == b.string.len,
        .pair => a.pair == b.pair,
        .empty_list, .unspecified => true,
        .closure => a.closure == b.closure,
        .primitive => a.primitive == b.primitive,
        .capability => a.capability == b.capability,
        .pending => a.pending == b.pending,
        .vector => a.vector.ptr == b.vector.ptr and a.vector.len == b.vector.len,
    };
}

fn eq(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    try exactly(args, 2);
    return .{ .boolean = eqValues(args[0], args[1]) };
}

/// §1: `/` stays exact only while every step divides exactly; otherwise the
/// result is real. Division by an exact zero errors; by an inexact zero it
/// follows IEEE. Truncating integer division is `quotient` (tier 8B.6).
fn div(_: std.mem.Allocator, args: []const Value) PrimitiveError!Value {
    if (args.len < 2) return error.ArityMismatch;
    var acc = try Num.of(args[0]);
    for (args[1..]) |a| {
        const d = try Num.of(a);
        if (d == .int and d.int == 0) return error.DivideByZero;
        if (acc == .int and d == .int and
            @rem(acc.int, d.int) == 0 and
            !(acc.int == std.math.minInt(i64) and d.int == -1))
        {
            const q = @divExact(acc.int, d.int);
            acc = .{ .int = q };
        } else {
            const q = acc.toF() / d.toF();
            acc = .{ .real = q };
        }
    }
    return acc.value();
}

// -- tests ---------------------------------------------------------------

/// Builds `(1 2 . <cycle back to head>)` by hand — guest code can't make one
/// until set-cdr! exists, but the walkers must already survive it.
fn makeCycle(arena: std.mem.Allocator) !Value {
    const a = try arena.create(Value.Pair);
    const b = try arena.create(Value.Pair);
    a.* = .{ .car = .{ .integer = 1 }, .cdr = .{ .pair = b } };
    b.* = .{ .car = .{ .integer = 2 }, .cdr = .{ .pair = a } };
    return .{ .pair = a };
}

test "walkers survive cyclic pairs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cyc = try makeCycle(arena);

    try std.testing.expectError(error.TypeError, length(arena, &.{cyc}));
    try std.testing.expectError(error.TypeError, append(arena, &.{ cyc, Value.empty_list }));
    // same cell: trivially equal; two distinct cycles: bounded, errors
    try std.testing.expect(try equalValuesChecked(cyc, cyc));
    const cyc2 = try makeCycle(arena);
    try std.testing.expectError(error.LimitExceeded, equalValuesChecked(cyc, cyc2));
    try std.testing.expect(!value_mod.isPureData(cyc));
}

test "printer truncates cyclic values instead of diverging" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cyc = try makeCycle(arena_state.allocator());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try @import("printer.zig").writeValue(cyc, &out.writer);
    try std.testing.expect(std.mem.endsWith(u8, out.written(), " ...)"));
}
