//! A small, self-contained regular-expression engine (Thompson NFA).
//!
//! Zig 0.16's standard library has no regex, and this tool scans potentially
//! many log lines, so a linear-time NFA simulation is used rather than a
//! backtracking matcher (no catastrophic blow-up on inputs like `(a*)*`).
//! Only a boolean "does it match anywhere" (`search`) is needed — no captures.
//!
//! Supported syntax:
//!   literals, `.` (any byte except newline), `*` `+` `?` quantifiers,
//!   `|` alternation, `(...)` grouping, `^` `$` anchors,
//!   character classes `[...]` / `[^...]` with `a-z` ranges,
//!   escapes `\. \* \\ \n \t \r \f \v` and shorthands `\d \D \w \W \s \S`.
//! Matching is unanchored (a pattern with no `^`/`$` matches any substring).

const std = @import("std");

pub const Error = error{ InvalidRegex, OutOfMemory };

const Range = struct { lo: u8, hi: u8 };

const Class = struct {
    negated: bool,
    ranges: []const Range,

    fn matches(self: Class, byte: u8) bool {
        var hit = false;
        for (self.ranges) |r| {
            if (byte >= r.lo and byte <= r.hi) {
                hit = true;
                break;
            }
        }
        return if (self.negated) !hit else hit;
    }
};

/// Compiled NFA instruction.
const Inst = union(enum) {
    char: u8,
    any,
    class: u16,
    match,
    jmp: u32,
    split: struct { a: u32, b: u32 },
    assert_start,
    assert_end,
};

// --- AST ---------------------------------------------------------------------

const Node = union(enum) {
    empty,
    char: u8,
    any,
    class: u16,
    assert_start,
    assert_end,
    concat: [2]*Node,
    alt: [2]*Node,
    star: *Node,
    plus: *Node,
    quest: *Node,
};

const Parser = struct {
    pat: []const u8,
    pos: usize = 0,
    gpa: std.mem.Allocator,
    classes: *std.ArrayList(Class),

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.pat.len) p.pat[p.pos] else null;
    }

    fn create(p: *Parser, node: Node) Error!*Node {
        const n = try p.gpa.create(Node);
        n.* = node;
        return n;
    }

    fn parseAlt(p: *Parser) Error!*Node {
        var left = try p.parseConcat();
        while (p.peek() == '|') {
            p.pos += 1;
            const right = try p.parseConcat();
            left = try p.create(.{ .alt = .{ left, right } });
        }
        return left;
    }

    fn parseConcat(p: *Parser) Error!*Node {
        var acc: ?*Node = null;
        while (true) {
            const atom = (try p.parseRepeat()) orelse break;
            acc = if (acc) |a| try p.create(.{ .concat = .{ a, atom } }) else atom;
        }
        return acc orelse try p.create(.empty);
    }

    fn parseRepeat(p: *Parser) Error!?*Node {
        var node = (try p.parseAtom()) orelse return null;
        while (p.peek()) |c| {
            switch (c) {
                '*' => {
                    p.pos += 1;
                    node = try p.create(.{ .star = node });
                },
                '+' => {
                    p.pos += 1;
                    node = try p.create(.{ .plus = node });
                },
                '?' => {
                    p.pos += 1;
                    node = try p.create(.{ .quest = node });
                },
                '{' => {
                    // `{n}` / `{n,}` / `{n,m}` counted repetition. A malformed
                    // brace (e.g. a bare `{`) is treated as a literal character,
                    // matching common regex behavior — leave it for parseAtom.
                    const rep = (try p.parseBrace()) orelse break;
                    node = try p.expandRepeat(node, rep.min, rep.max);
                },
                else => break,
            }
        }
        return node;
    }

    const Rep = struct { min: usize, max: ?usize };
    const max_repeat = 1000; // guard against `a{999999}` program blow-up

    /// Try to parse a `{n}` / `{n,}` / `{n,m}` quantifier at the current `{`.
    /// Returns null (without consuming) if it is not a well-formed count, so the
    /// `{` falls through to being a literal. Errors only on an out-of-range count.
    fn parseBrace(p: *Parser) Error!?Rep {
        var i = p.pos + 1; // skip '{'
        const min = readUint(p.pat, &i) orelse return null; // require a lower bound
        var max: ?usize = min;
        if (i < p.pat.len and p.pat[i] == ',') {
            i += 1;
            max = readUint(p.pat, &i); // null => unbounded `{n,}`
        }
        if (i >= p.pat.len or p.pat[i] != '}') return null; // malformed => literal '{'
        i += 1;
        if (min > max_repeat) return error.InvalidRegex;
        if (max) |m| {
            if (m > max_repeat or m < min) return error.InvalidRegex;
        }
        p.pos = i;
        return .{ .min = min, .max = max };
    }

    /// Desugar `X{min,max}` into concatenations of `X`:
    ///   {n}    -> X (n times)
    ///   {n,}   -> X (n times) then X*
    ///   {n,m}  -> X (n times) then X? (m-n times)
    /// The AST node is shared (compiled read-only), so no deep copy is needed.
    fn expandRepeat(p: *Parser, node: *Node, min: usize, max: ?usize) Error!*Node {
        var acc: *Node = try p.create(.empty);
        var k: usize = 0;
        while (k < min) : (k += 1) acc = try p.create(.{ .concat = .{ acc, node } });
        if (max) |m| {
            var j = min;
            while (j < m) : (j += 1) {
                const opt = try p.create(.{ .quest = node });
                acc = try p.create(.{ .concat = .{ acc, opt } });
            }
        } else {
            acc = try p.create(.{ .concat = .{ acc, try p.create(.{ .star = node }) } });
        }
        return acc;
    }

    fn parseAtom(p: *Parser) Error!?*Node {
        const c = p.peek() orelse return null;
        switch (c) {
            '|', ')' => return null, // let the caller stop here
            '*', '+', '?' => return error.InvalidRegex, // nothing to repeat
            '(' => {
                p.pos += 1;
                const inner = try p.parseAlt();
                if (p.peek() != ')') return error.InvalidRegex;
                p.pos += 1;
                return inner;
            },
            '[' => return try p.parseClass(),
            '.' => {
                p.pos += 1;
                return try p.create(.any);
            },
            '^' => {
                p.pos += 1;
                return try p.create(.assert_start);
            },
            '$' => {
                p.pos += 1;
                return try p.create(.assert_end);
            },
            '\\' => {
                p.pos += 1;
                return try p.parseEscape();
            },
            else => {
                p.pos += 1;
                return try p.create(.{ .char = c });
            },
        }
    }

    /// Parse an escape outside a character class into a node.
    fn parseEscape(p: *Parser) Error!*Node {
        const e = p.peek() orelse return error.InvalidRegex; // trailing backslash
        p.pos += 1;
        switch (e) {
            'd', 'D', 'w', 'W', 's', 'S' => {
                const idx = try p.addShorthand(e);
                return try p.create(.{ .class = idx });
            },
            else => return try p.create(.{ .char = escapeChar(e) }),
        }
    }

    fn parseClass(p: *Parser) Error!*Node {
        p.pos += 1; // consume '['
        var negated = false;
        if (p.peek() == '^') {
            negated = true;
            p.pos += 1;
        }
        var ranges: std.ArrayList(Range) = .empty;
        while (true) {
            const c = p.peek() orelse return error.InvalidRegex; // unterminated
            if (c == ']') {
                p.pos += 1;
                break;
            }
            // A class member: either a shorthand (expands to ranges) or a single
            // char that may start an `a-z` range.
            if (c == '\\') {
                p.pos += 1;
                const e = p.peek() orelse return error.InvalidRegex;
                p.pos += 1;
                switch (e) {
                    'd', 'w', 's' => {
                        try p.appendShorthandRanges(&ranges, e);
                        continue;
                    },
                    'D', 'W', 'S' => return error.InvalidRegex, // negated shorthand inside [] unsupported
                    else => try p.rangeFrom(&ranges, escapeChar(e)),
                }
            } else {
                p.pos += 1;
                try p.rangeFrom(&ranges, c);
            }
        }
        const idx: u16 = @intCast(p.classes.items.len);
        try p.classes.append(p.gpa, .{ .negated = negated, .ranges = try ranges.toOwnedSlice(p.gpa) });
        return try p.create(.{ .class = idx });
    }

    /// Having consumed a class char `lo`, look for a `-hi` range continuation.
    fn rangeFrom(p: *Parser, ranges: *std.ArrayList(Range), lo: u8) Error!void {
        // Range only if '-' is followed by a real member (not the closing ']').
        if (p.peek() == '-' and p.pos + 1 < p.pat.len and p.pat[p.pos + 1] != ']') {
            p.pos += 1; // consume '-'
            var hi = p.peek().?;
            if (hi == '\\') {
                p.pos += 1;
                hi = escapeChar(p.peek() orelse return error.InvalidRegex);
            }
            p.pos += 1;
            if (hi < lo) return error.InvalidRegex;
            try ranges.append(p.gpa, .{ .lo = lo, .hi = hi });
        } else {
            try ranges.append(p.gpa, .{ .lo = lo, .hi = lo });
        }
    }

    fn appendShorthandRanges(p: *Parser, ranges: *std.ArrayList(Range), kind: u8) Error!void {
        for (shorthandRanges(kind)) |r| try ranges.append(p.gpa, r);
    }

    fn addShorthand(p: *Parser, kind: u8) Error!u16 {
        const idx: u16 = @intCast(p.classes.items.len);
        const negated = kind == 'D' or kind == 'W' or kind == 'S';
        const lower = std.ascii.toLower(kind);
        try p.classes.append(p.gpa, .{ .negated = negated, .ranges = try p.gpa.dupe(Range, shorthandRanges(lower)) });
        return idx;
    }
};

/// Read a run of decimal digits from `s` starting at `i.*`, advancing `i`.
/// Returns null if there is no digit. Saturates to keep absurd counts from
/// overflowing (the caller's range check then rejects them).
fn readUint(s: []const u8, i: *usize) ?usize {
    const start = i.*;
    var v: usize = 0;
    while (i.* < s.len and s[i.*] >= '0' and s[i.*] <= '9') : (i.* += 1) {
        v = @min(v * 10 + (s[i.*] - '0'), 1_000_000);
    }
    return if (i.* == start) null else v;
}

fn escapeChar(e: u8) u8 {
    return switch (e) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        'f' => 12,
        'v' => 11,
        '0' => 0,
        else => e, // \. \* \\ \/ etc. -> the literal character
    };
}

fn shorthandRanges(lower_kind: u8) []const Range {
    return switch (lower_kind) {
        'd' => &.{.{ .lo = '0', .hi = '9' }},
        'w' => &.{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 'a', .hi = 'z' }, .{ .lo = '_', .hi = '_' } },
        's' => &.{ .{ .lo = ' ', .hi = ' ' }, .{ .lo = '\t', .hi = '\t' }, .{ .lo = '\n', .hi = '\n' }, .{ .lo = '\r', .hi = '\r' }, .{ .lo = 11, .hi = 12 } },
        else => unreachable,
    };
}

// --- Compiler ----------------------------------------------------------------

const Compiler = struct {
    prog: std.ArrayList(Inst) = .empty,
    gpa: std.mem.Allocator,

    fn emit(c: *Compiler, inst: Inst) Error!u32 {
        const idx: u32 = @intCast(c.prog.items.len);
        try c.prog.append(c.gpa, inst);
        return idx;
    }

    fn compile(c: *Compiler, node: *const Node) Error!void {
        switch (node.*) {
            .empty => {},
            .char => |ch| _ = try c.emit(.{ .char = ch }),
            .any => _ = try c.emit(.any),
            .class => |i| _ = try c.emit(.{ .class = i }),
            .assert_start => _ = try c.emit(.assert_start),
            .assert_end => _ = try c.emit(.assert_end),
            .concat => |ab| {
                try c.compile(ab[0]);
                try c.compile(ab[1]);
            },
            .alt => |ab| {
                // split A, B ; A: <a> ; jmp End ; B: <b> ; End:
                const split_idx = try c.emit(.{ .split = .{ .a = 0, .b = 0 } });
                const a_at: u32 = @intCast(c.prog.items.len);
                try c.compile(ab[0]);
                const jmp_idx = try c.emit(.{ .jmp = 0 });
                const b_at: u32 = @intCast(c.prog.items.len);
                try c.compile(ab[1]);
                const end: u32 = @intCast(c.prog.items.len);
                c.prog.items[split_idx] = .{ .split = .{ .a = a_at, .b = b_at } };
                c.prog.items[jmp_idx] = .{ .jmp = end };
            },
            .star => |child| {
                // L1: split Body, End ; Body: <child> ; jmp L1 ; End:
                const l1: u32 = @intCast(c.prog.items.len);
                const split_idx = try c.emit(.{ .split = .{ .a = 0, .b = 0 } });
                const body: u32 = @intCast(c.prog.items.len);
                try c.compile(child);
                _ = try c.emit(.{ .jmp = l1 });
                const end: u32 = @intCast(c.prog.items.len);
                c.prog.items[split_idx] = .{ .split = .{ .a = body, .b = end } };
            },
            .plus => |child| {
                // L1: <child> ; split L1, End ; End:
                const l1: u32 = @intCast(c.prog.items.len);
                try c.compile(child);
                const split_idx = try c.emit(.{ .split = .{ .a = 0, .b = 0 } });
                const end: u32 = @intCast(c.prog.items.len);
                c.prog.items[split_idx] = .{ .split = .{ .a = l1, .b = end } };
            },
            .quest => |child| {
                // split Body, End ; Body: <child> ; End:
                const split_idx = try c.emit(.{ .split = .{ .a = 0, .b = 0 } });
                const body: u32 = @intCast(c.prog.items.len);
                try c.compile(child);
                const end: u32 = @intCast(c.prog.items.len);
                c.prog.items[split_idx] = .{ .split = .{ .a = body, .b = end } };
            },
        }
    }
};

// --- Public API --------------------------------------------------------------

pub const Regex = struct {
    prog: []const Inst,
    classes: []const Class,

    /// True if `input` contains a match for the pattern (unanchored). `gpa` is
    /// used for small, short-lived scratch buffers.
    pub fn search(self: Regex, gpa: std.mem.Allocator, input: []const u8) Error!bool {
        const n = self.prog.len;
        var clist = try std.ArrayList(u32).initCapacity(gpa, n);
        defer clist.deinit(gpa);
        var nlist = try std.ArrayList(u32).initCapacity(gpa, n);
        defer nlist.deinit(gpa);
        const visited = try gpa.alloc(u32, n);
        defer gpa.free(visited);
        @memset(visited, 0);

        var gen: u32 = 0;
        gen += 1;
        var cgen = gen;
        gen += 1;
        var ngen = gen;

        var pos: usize = 0;
        while (true) : (pos += 1) {
            // Unanchored search: (re)seed the start state at every position.
            self.addThread(&clist, cgen, visited, 0, input, pos);

            for (clist.items) |pc| {
                switch (self.prog[pc]) {
                    .match => return true,
                    .char => |ch| if (pos < input.len and input[pos] == ch)
                        self.addThread(&nlist, ngen, visited, pc + 1, input, pos + 1),
                    .any => if (pos < input.len and input[pos] != '\n')
                        self.addThread(&nlist, ngen, visited, pc + 1, input, pos + 1),
                    .class => |i| if (pos < input.len and self.classes[i].matches(input[pos]))
                        self.addThread(&nlist, ngen, visited, pc + 1, input, pos + 1),
                    else => {}, // jmp/split/assert are expanded inside addThread
                }
            }

            if (pos >= input.len) break;

            // Swap current/next and prepare a fresh next list.
            std.mem.swap(std.ArrayList(u32), &clist, &nlist);
            std.mem.swap(u32, &cgen, &ngen);
            gen += 1;
            ngen = gen;
            nlist.clearRetainingCapacity();
        }
        return false;
    }

    /// Follow epsilon transitions (jmp/split/assert) from `pc`, appending the
    /// reachable consuming instructions to `list`. `visited[pc] == gen` dedupes
    /// within this list, which also breaks epsilon cycles.
    fn addThread(self: Regex, list: *std.ArrayList(u32), gen: u32, visited: []u32, pc: u32, input: []const u8, pos: usize) void {
        if (visited[pc] == gen) return;
        visited[pc] = gen;
        switch (self.prog[pc]) {
            .jmp => |x| self.addThread(list, gen, visited, x, input, pos),
            .split => |s| {
                self.addThread(list, gen, visited, s.a, input, pos);
                self.addThread(list, gen, visited, s.b, input, pos);
            },
            .assert_start => if (pos == 0) self.addThread(list, gen, visited, pc + 1, input, pos),
            .assert_end => if (pos == input.len) self.addThread(list, gen, visited, pc + 1, input, pos),
            else => list.appendAssumeCapacity(pc), // char, any, class, match
        }
    }
};

/// Compile `pattern` into a `Regex`. All storage is taken from `gpa` (use an
/// arena for a compile-once, never-free lifetime).
pub fn compile(gpa: std.mem.Allocator, pattern: []const u8) Error!Regex {
    var classes: std.ArrayList(Class) = .empty;
    var parser: Parser = .{ .pat = pattern, .gpa = gpa, .classes = &classes };
    const ast = try parser.parseAlt();
    if (parser.pos != pattern.len) return error.InvalidRegex; // e.g. stray ')'

    var compiler: Compiler = .{ .gpa = gpa };
    try compiler.compile(ast);
    _ = try compiler.emit(.match);

    return .{
        .prog = try compiler.prog.toOwnedSlice(gpa),
        .classes = try classes.toOwnedSlice(gpa),
    };
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

fn matchesPattern(pattern: []const u8, input: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const re = try compile(arena.allocator(), pattern);
    return re.search(arena.allocator(), input);
}

test "literal substring (unanchored)" {
    try testing.expect(try matchesPattern("temp", "the temperature"));
    try testing.expect(!try matchesPattern("temp", "humidity"));
}

test "anchors" {
    try testing.expect(try matchesPattern("^ON$", "ON"));
    try testing.expect(!try matchesPattern("^ON$", "ONLINE"));
    try testing.expect(try matchesPattern("^ON", "ONLINE"));
    try testing.expect(try matchesPattern("INE$", "ONLINE"));
}

test "dot and quantifiers" {
    try testing.expect(try matchesPattern("a.c", "abc"));
    try testing.expect(!try matchesPattern("a.c", "ac"));
    try testing.expect(try matchesPattern("ab*c", "ac"));
    try testing.expect(try matchesPattern("ab*c", "abbbc"));
    try testing.expect(try matchesPattern("ab+c", "abc"));
    try testing.expect(!try matchesPattern("ab+c", "ac"));
    try testing.expect(try matchesPattern("colou?r", "color"));
    try testing.expect(try matchesPattern("colou?r", "colour"));
}

test "alternation and groups" {
    try testing.expect(try matchesPattern("cat|dog", "hotdog"));
    try testing.expect(try matchesPattern("(ab)+", "abab"));
    try testing.expect(!try matchesPattern("^(ab)+$", "aba"));
}

test "character classes and ranges" {
    try testing.expect(try matchesPattern("[0-9]+", "temp=22"));
    try testing.expect(!try matchesPattern("^[0-9]+$", "22.5"));
    try testing.expect(try matchesPattern("[^0-9]", "a1"));
    try testing.expect(try matchesPattern("gr[ae]y", "gray"));
    try testing.expect(try matchesPattern("gr[ae]y", "grey"));
}

test "shorthand classes" {
    try testing.expect(try matchesPattern("\\d\\d", "x42y"));
    try testing.expect(try matchesPattern("\\w+", "_ok"));
    try testing.expect(try matchesPattern("a\\sb", "a b"));
    try testing.expect(!try matchesPattern("\\D", "123"));
}

test "escaped metacharacters are literal" {
    try testing.expect(try matchesPattern("a\\.b", "a.b"));
    try testing.expect(!try matchesPattern("a\\.b", "axb"));
}

test "invalid patterns are rejected" {
    try testing.expectError(error.InvalidRegex, matchesPattern("(unterminated", ""));
    try testing.expectError(error.InvalidRegex, matchesPattern("[abc", ""));
    try testing.expectError(error.InvalidRegex, matchesPattern("*", ""));
    try testing.expectError(error.InvalidRegex, matchesPattern("a)b", ""));
}

test "empty pattern matches anything" {
    try testing.expect(try matchesPattern("", "anything"));
    try testing.expect(try matchesPattern("", ""));
}

test "counted repetition {n} {n,} {n,m}" {
    try testing.expect(try matchesPattern("^[0-9]{3}$", "123"));
    try testing.expect(!try matchesPattern("^[0-9]{3}$", "12"));
    try testing.expect(!try matchesPattern("^[0-9]{3}$", "1234"));
    try testing.expect(try matchesPattern("a{2,}", "aaaa"));
    try testing.expect(!try matchesPattern("^a{2,}$", "a"));
    try testing.expect(try matchesPattern("^a{2,3}$", "aa"));
    try testing.expect(try matchesPattern("^a{2,3}$", "aaa"));
    try testing.expect(!try matchesPattern("^a{2,3}$", "aaaa"));
    try testing.expect(try matchesPattern("[0-9]{8}", "x17833307y"));
}

test "malformed brace is a literal" {
    try testing.expect(try matchesPattern("a{b", "a{b"));
    try testing.expect(try matchesPattern("q{}", "q{}"));
}

test "oversized counted repetition is rejected" {
    try testing.expectError(error.InvalidRegex, matchesPattern("a{5000}", "a"));
    try testing.expectError(error.InvalidRegex, matchesPattern("a{3,2}", "a"));
}
