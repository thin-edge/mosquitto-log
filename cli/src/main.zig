//! mqtt-log — filter and format the JSON-Lines files written by the mosquitto
//! message-logger plugin.
//!
//! Pipeline: discover files -> read (decompress .gz) -> parse each line ->
//! apply filters -> collect matches -> sort by time -> head/tail -> render.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("options.zig");
const filter = @import("filter.zig");
const output = @import("output.zig");
const sources = @import("sources.zig");
const time = @import("time.zig");

const version = "0.1.0";

const Match = struct {
    ns: i96,
    seq: u64,
    line: []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    const now_ns: i96 = std.Io.Clock.real.now(io).nanoseconds;

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_w = stdout_file.writer(io, &stdout_buf);
    const w = &stdout_w.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = std.Io.File.stderr();
    var stderr_w = stderr_file.writer(io, &stderr_buf);
    const ew = &stderr_w.interface;

    const parsed = try options.parse(arena, argv, now_ns);
    const opts = switch (parsed) {
        .err => |msg| {
            try ew.print("mqtt-log: {s}\n\nTry 'mqtt-log --help'.\n", .{msg});
            try ew.flush();
            return 2;
        },
        .ok => |o| o,
    };

    if (opts.help) {
        try w.writeAll(options.usage);
        try w.flush();
        return 0;
    }
    if (opts.version) {
        try w.print("mqtt-log {s}\n", .{version});
        try w.flush();
        return 0;
    }

    const files = try sources.collect(arena, io, opts);

    var matches: std.ArrayList(Match) = .empty;
    var seq: u64 = 0;

    // Reused per line for transient filter allocations (e.g. base64 payload
    // decode); reset with retained capacity to avoid churn. Matched lines point
    // into the persistent file `contents`, so resetting here is safe.
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    for (files) |path| {
        const contents = sources.readContents(arena, io, path) catch |err| {
            try ew.print("mqtt-log: cannot read {s}: {t}\n", .{ path, err });
            try ew.flush();
            continue;
        };

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0) continue;

            _ = scratch.reset(.retain_capacity);
            const p = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch continue;
            defer p.deinit();
            if (p.value != .object) continue;
            const obj = p.value.object;

            const ns = recordNs(trimmed, obj);
            const keep = filter.matches(scratch.allocator(), opts, obj, ns) catch continue;
            if (!keep) continue;

            try matches.append(arena, .{ .ns = ns, .seq = seq, .line = trimmed });
            seq += 1;
        }
    }

    std.mem.sort(Match, matches.items, {}, lessThanOldest);
    if (opts.sort == .newest) std.mem.reverse(Match, matches.items);

    // Count assertions apply to the full match set, independent of the
    // --head/--tail display limit.
    const match_count = matches.items.len;

    if (!opts.quiet) {
        const view = selectHeadTail(matches.items, opts);
        try render(w, gpa, opts, view, terminalWidth(io, stdout_file));
        try w.flush();
    }

    if (assertionFailure(opts, match_count)) |kind| {
        try reportAssertion(ew, opts, kind, match_count);
        try ew.flush();
        return 1;
    }
    return 0;
}

const AssertionKind = enum { too_few, too_many };

/// Evaluate the count assertions; returns which one was violated, or null.
fn assertionFailure(opts: options.Options, count: usize) ?AssertionKind {
    if (opts.min_count) |min| {
        if (count < min) return .too_few;
    }
    if (opts.max_count) |max| {
        if (count > max) return .too_many;
    }
    return null;
}

/// Print a human-readable assertion failure with the expected/actual counts and
/// the active filter criteria that produced the match set.
fn reportAssertion(ew: *std.Io.Writer, opts: options.Options, kind: AssertionKind, count: usize) !void {
    switch (kind) {
        .too_few => try ew.print(
            "mqtt-log: assertion failed: expected at least {d} matching message(s), but found {d}\n",
            .{ opts.min_count.?, count },
        ),
        .too_many => try ew.print(
            "mqtt-log: assertion failed: expected at most {d} matching message(s), but found {d}\n",
            .{ opts.max_count.?, count },
        ),
    }
    try ew.writeAll("  criteria:\n");
    try describeCriteria(ew, opts);
}

/// Write one `    key: value` line per active filter, so a failing assertion
/// makes clear exactly what was searched for.
fn describeCriteria(ew: *std.Io.Writer, opts: options.Options) !void {
    if (opts.paths.len > 0) {
        try ew.writeAll("    files:");
        for (opts.paths) |p| try ew.print(" {s}", .{p});
        try ew.writeByte('\n');
    } else {
        try ew.print("    dir: {s}{s}\n", .{ opts.dir, if (opts.recursive) " (recursive)" else "" });
    }
    if (opts.from_raw) |v| try writeDateCriteria(ew, "from", v, opts.from.?);
    if (opts.to_raw) |v| try writeDateCriteria(ew, "to", v, opts.to.?);
    if (opts.types.len > 0) try printList(ew, "type", opts.types);
    if (opts.encodings.len > 0) try printList(ew, "encoding", opts.encodings);
    if (opts.topic) |v| try ew.print("    topic: {s}\n", .{v});
    if (opts.topic_contains) |v| try ew.print("    topic-contains: {s}\n", .{v});
    if (opts.client) |v| try ew.print("    client: {s}\n", .{v});
    if (opts.qos.len > 0) {
        try ew.writeAll("    qos:");
        for (opts.qos) |q| try ew.print(" {d}", .{q});
        try ew.writeByte('\n');
    }
    if (opts.retain) |v| try ew.print("    retain: {s}\n", .{if (v) "true" else "false"});
    if (opts.min_size) |v| try ew.print("    min-size: {d}\n", .{v});
    if (opts.max_size) |v| try ew.print("    max-size: {d}\n", .{v});
    if (opts.payload_contains) |v| try ew.print("    payload-contains: {s}\n", .{v});
    if (opts.payload_matches_raw) |v| try ew.print("    payload-matches: {s}\n", .{v});
    if (opts.reason) |v| try ew.print("    reason: {d}\n", .{v});
}

/// Print a `from`/`to` criterion. For relative or Unix-seconds inputs, also show
/// the resolved absolute UTC instant in parentheses, e.g. `from: -1h (2026-07-06T08:38:00Z)`.
fn writeDateCriteria(ew: *std.Io.Writer, label: []const u8, raw: []const u8, ns: i96) !void {
    if (time.needsResolution(raw)) {
        var buf: [32]u8 = undefined;
        try ew.print("    {s}: {s} ({s})\n", .{ label, raw, time.formatIso(ns, &buf) });
    } else {
        try ew.print("    {s}: {s}\n", .{ label, raw });
    }
}

fn printList(ew: *std.Io.Writer, label: []const u8, items: []const []const u8) !void {
    try ew.print("    {s}:", .{label});
    for (items) |it| try ew.print(" {s}", .{it});
    try ew.writeByte('\n');
}

fn lessThanOldest(_: void, a: Match, b: Match) bool {
    if (a.ns != b.ns) return a.ns < b.ns;
    return a.seq < b.seq;
}

fn selectHeadTail(items: []const Match, opts: options.Options) []const Match {
    if (opts.head) |n| return items[0..@min(n, items.len)];
    if (opts.tail) |n| {
        const start = if (n >= items.len) 0 else items.len - n;
        return items[start..];
    }
    return items;
}

/// Extract the record's epoch nanoseconds. Reads the raw `timestamp_unix`
/// substring to keep full nanosecond precision (its float form would round);
/// falls back to the ISO `timestamp`, then to 0.
fn recordNs(line: []const u8, obj: filter.Object) i96 {
    if (rawNumber(line, "\"timestamp_unix\":")) |num| {
        if (time.parseUnixNanos(num)) |ns| return ns else |_| {}
    }
    if (filter.getStr(obj, "timestamp")) |iso| {
        if (time.parseIso(iso)) |ns| return ns else |_| {}
    }
    return 0;
}

/// Return the numeric literal that follows `key` in `line` (digits, `.`, sign).
fn rawNumber(line: []const u8, key: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, line, key) orelse return null;
    var i = idx + key.len;
    const start = i;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (!((c >= '0' and c <= '9') or c == '.' or c == '-' or c == '+')) break;
    }
    if (i == start) return null;
    return line[start..i];
}

/// The terminal width in columns, or null when stdout is not a terminal (e.g.
/// piped or redirected) — in which case table headers are not clipped.
fn terminalWidth(io: std.Io, file: std.Io.File) ?usize {
    return switch (builtin.os.tag) {
        .windows, .wasi => null, // ioctl path below is POSIX-only
        else => unixTerminalWidth(io, file),
    };
}

fn unixTerminalWidth(io: std.Io, file: std.Io.File) ?usize {
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const res = io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &ws,
    } }) catch return null;
    if (res.device_io_control >= 0 and ws.col > 0) return ws.col;
    return null; // not a tty (pipe/file) or unknown
}

fn render(w: *std.Io.Writer, gpa: std.mem.Allocator, opts: options.Options, view: []const Match, term_width: ?usize) !void {
    // `table` needs every row up front to size columns, so it takes its own path
    // (a custom --format still overrides the output mode).
    if (opts.output == .table and opts.format == null) {
        try renderTable(w, gpa, opts, view, term_width);
        return;
    }
    if (opts.output == .json and opts.format == null) {
        try w.writeAll("[\n");
    }
    for (view, 0..) |m, idx| {
        const p = std.json.parseFromSlice(std.json.Value, gpa, m.line, .{}) catch continue;
        defer p.deinit();
        if (p.value != .object) continue;
        const obj = p.value.object;

        // A per-record arena keeps payload-decode allocations from accumulating.
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        if (opts.format) |tmpl| {
            try output.renderFormat(w, sa, obj, tmpl);
            continue;
        }
        switch (opts.output) {
            .table => unreachable, // handled by renderTable before this loop
            .text => try output.renderText(w, sa, obj, opts.fields),
            .list => try output.renderList(w, sa, obj, opts.fields),
            .ndjson => {
                try output.renderJsonObject(w, obj, opts.fields, m.line);
                try w.writeByte('\n');
            },
            .json => {
                try w.writeAll("  ");
                try output.renderJsonObject(w, obj, opts.fields, null);
                if (idx + 1 < view.len) try w.writeByte(',');
                try w.writeByte('\n');
            },
        }
    }
    if (opts.output == .json and opts.format == null) {
        try w.writeAll("]\n");
    }
}

/// Column-aligned `table` output. Buffers every row (cells owned by a local
/// arena) so column widths can be computed before printing.
fn renderTable(w: *std.Io.Writer, gpa: std.mem.Allocator, opts: options.Options, view: []const Match, term_width: ?usize) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const headers = if (opts.fields.len > 0) opts.fields else &output.default_fields;

    var rows: std.ArrayList([]const []const u8) = .empty;
    for (view) |m| {
        const p = std.json.parseFromSlice(std.json.Value, gpa, m.line, .{}) catch continue;
        defer p.deinit();
        if (p.value != .object) continue;
        const obj = p.value.object;

        const cells = try arena.alloc([]const u8, headers.len);
        for (headers, 0..) |name, i| cells[i] = try output.cellString(arena, obj, name);
        try rows.append(arena, cells);
    }

    try output.writeTable(w, gpa, headers, rows.items, term_width);
}

const testing = std.testing;

test "assertionFailure min-count" {
    const opts: options.Options = .{ .min_count = 2 };
    try testing.expectEqual(@as(?AssertionKind, .too_few), assertionFailure(opts, 1));
    try testing.expectEqual(@as(?AssertionKind, null), assertionFailure(opts, 2));
    try testing.expectEqual(@as(?AssertionKind, null), assertionFailure(opts, 3));
}

test "assertionFailure max-count" {
    const opts: options.Options = .{ .max_count = 2 };
    try testing.expectEqual(@as(?AssertionKind, null), assertionFailure(opts, 0));
    try testing.expectEqual(@as(?AssertionKind, null), assertionFailure(opts, 2));
    try testing.expectEqual(@as(?AssertionKind, .too_many), assertionFailure(opts, 3));
}

test "assertionFailure range (inclusive both ends)" {
    const opts: options.Options = .{ .min_count = 1, .max_count = 3 };
    try testing.expectEqual(@as(?AssertionKind, .too_few), assertionFailure(opts, 0));
    try testing.expectEqual(@as(?AssertionKind, null), assertionFailure(opts, 1));
    try testing.expectEqual(@as(?AssertionKind, null), assertionFailure(opts, 3));
    try testing.expectEqual(@as(?AssertionKind, .too_many), assertionFailure(opts, 4));
}

test "assertionFailure none configured" {
    try testing.expectEqual(@as(?AssertionKind, null), assertionFailure(.{}, 0));
    try testing.expectEqual(@as(?AssertionKind, null), assertionFailure(.{}, 999));
}

test {
    // Pull in the unit tests defined in each module.
    _ = @import("time.zig");
    _ = @import("filter.zig");
    _ = @import("options.zig");
    _ = @import("output.zig");
    _ = @import("sources.zig");
    _ = @import("regex.zig");
}
