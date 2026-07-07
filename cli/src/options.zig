//! Command-line parsing for `mqtt-log`.
//!
//! Produces an `Options` struct. All slices are allocated in the caller's arena
//! (the process-lifetime arena from `std.process.Init`), so nothing here needs
//! freeing.

const std = @import("std");
const time = @import("time.zig");
const regex = @import("regex.zig");

pub const OutputFormat = enum { text, list, table, json, ndjson };
pub const SortOrder = enum { oldest, newest };

pub const default_dir = "/var/log/mosquitto";

pub const Options = struct {
    /// Explicit input files (positional args). If empty, `dir` is scanned.
    paths: []const []const u8 = &.{},
    dir: []const u8 = default_dir,
    recursive: bool = true,

    from: ?i96 = null,
    to: ?i96 = null,
    // Original --from/--to strings, echoed verbatim in messages (nicer than the
    // resolved epoch value, e.g. shows "-1h" as typed).
    from_raw: ?[]const u8 = null,
    to_raw: ?[]const u8 = null,

    types: []const []const u8 = &.{},
    encodings: []const []const u8 = &.{},
    topic: ?[]const u8 = null,
    topic_contains: ?[]const u8 = null,
    client: ?[]const u8 = null,
    qos: []const i64 = &.{},
    retain: ?bool = null,
    min_size: ?u64 = null,
    max_size: ?u64 = null,
    payload_contains: ?[]const u8 = null,
    // Regex match on the decoded payload, compiled at parse time.
    // `payload_matches_raw` keeps the pattern string for messages.
    payload_matches: ?regex.Regex = null,
    payload_matches_raw: ?[]const u8 = null,
    reason: ?i64 = null,

    fields: []const []const u8 = &.{},
    output: OutputFormat = .text,
    format: ?[]const u8 = null,

    head: ?usize = null,
    tail: ?usize = null,
    sort: SortOrder = .oldest,

    // Count assertions on the number of matching messages (inclusive). A
    // violated assertion makes the process exit non-zero with a message.
    min_count: ?usize = null,
    max_count: ?usize = null,
    quiet: bool = false,

    help: bool = false,
    version: bool = false,
};

pub const ParseError = error{
    MissingValue,
    UnknownFlag,
    InvalidValue,
    OutOfMemory,
};

/// A parse failure carries a human-readable message for the CLI to print.
pub const Result = union(enum) {
    ok: Options,
    err: []const u8,
};

const ParseCtx = struct {
    arena: std.mem.Allocator,
    argv: []const [:0]const u8,
    i: usize,
    now_ns: i96,

    fn errf(ctx: *ParseCtx, comptime fmt: []const u8, args: anytype) ParseError!Result {
        return .{ .err = try std.fmt.allocPrint(ctx.arena, fmt, args) };
    }

    /// Value for a flag given either as `--flag value` or `--flag=value`.
    /// `inline_val` is the part after `=` if present.
    fn value(ctx: *ParseCtx, inline_val: ?[]const u8) ?[]const u8 {
        if (inline_val) |v| return v;
        if (ctx.i + 1 >= ctx.argv.len) return null;
        ctx.i += 1;
        return ctx.argv[ctx.i];
    }
};

fn splitCsv(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), s: []const u8) !void {
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        try list.append(arena, try arena.dupe(u8, part));
    }
}

pub fn parse(
    arena: std.mem.Allocator,
    argv: []const [:0]const u8,
    now_ns: i96,
) ParseError!Result {
    var opts: Options = .{};
    var paths: std.ArrayList([]const u8) = .empty;
    var types: std.ArrayList([]const u8) = .empty;
    var encodings: std.ArrayList([]const u8) = .empty;
    var fields: std.ArrayList([]const u8) = .empty;
    var qos: std.ArrayList(i64) = .empty;

    var ctx: ParseCtx = .{ .arena = arena, .argv = argv, .i = 1, .now_ns = now_ns };

    while (ctx.i < argv.len) : (ctx.i += 1) {
        const arg = argv[ctx.i];

        if (arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) {
            try paths.append(arena, try arena.dupe(u8, arg));
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            // Everything after `--` is a path.
            while (ctx.i + 1 < argv.len) {
                ctx.i += 1;
                try paths.append(arena, try arena.dupe(u8, argv[ctx.i]));
            }
            break;
        }

        // Split `--flag=value`.
        var name: []const u8 = arg;
        var inline_val: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            name = arg[0..eq];
            inline_val = arg[eq + 1 ..];
        }

        if (eqAny(name, &.{ "-h", "--help" })) {
            opts.help = true;
        } else if (eqAny(name, &.{ "-V", "--version" })) {
            opts.version = true;
        } else if (eqAny(name, &.{ "-d", "--dir" })) {
            opts.dir = try dupOrErr(&ctx, inline_val, name) orelse return missing(&ctx, name);
        } else if (std.mem.eql(u8, name, "--no-recursive")) {
            opts.recursive = false;
        } else if (std.mem.eql(u8, name, "--recursive")) {
            opts.recursive = true;
        } else if (eqAny(name, &.{ "--from", "--since" })) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            opts.from = time.parseInstant(v, now_ns) catch return ctx.errf("invalid --from timestamp: '{s}'", .{v});
            opts.from_raw = try arena.dupe(u8, v);
        } else if (eqAny(name, &.{ "--to", "--until" })) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            opts.to = time.parseInstant(v, now_ns) catch return ctx.errf("invalid --to timestamp: '{s}'", .{v});
            opts.to_raw = try arena.dupe(u8, v);
        } else if (eqAny(name, &.{ "-t", "--type" })) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            try splitCsv(arena, &types, v);
        } else if (eqAny(name, &.{ "-e", "--encoding" })) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            try splitCsv(arena, &encodings, v);
        } else if (std.mem.eql(u8, name, "--topic")) {
            opts.topic = try dupOrErr(&ctx, inline_val, name) orelse return missing(&ctx, name);
        } else if (std.mem.eql(u8, name, "--topic-contains")) {
            opts.topic_contains = try dupOrErr(&ctx, inline_val, name) orelse return missing(&ctx, name);
        } else if (eqAny(name, &.{ "-c", "--client", "--client-id" })) {
            opts.client = try dupOrErr(&ctx, inline_val, name) orelse return missing(&ctx, name);
        } else if (std.mem.eql(u8, name, "--qos")) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |part| {
                if (part.len == 0) continue;
                const q = std.fmt.parseInt(i64, part, 10) catch return ctx.errf("invalid --qos value: '{s}'", .{part});
                try qos.append(arena, q);
            }
        } else if (std.mem.eql(u8, name, "--retain")) {
            opts.retain = true;
        } else if (std.mem.eql(u8, name, "--no-retain")) {
            opts.retain = false;
        } else if (std.mem.eql(u8, name, "--min-size")) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            opts.min_size = std.fmt.parseInt(u64, v, 10) catch return ctx.errf("invalid --min-size: '{s}'", .{v});
        } else if (std.mem.eql(u8, name, "--max-size")) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            opts.max_size = std.fmt.parseInt(u64, v, 10) catch return ctx.errf("invalid --max-size: '{s}'", .{v});
        } else if (std.mem.eql(u8, name, "--payload-contains")) {
            opts.payload_contains = try dupOrErr(&ctx, inline_val, name) orelse return missing(&ctx, name);
        } else if (std.mem.eql(u8, name, "--payload-matches")) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            opts.payload_matches = regex.compile(arena, v) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidRegex => return ctx.errf("invalid --payload-matches regex: '{s}'", .{v}),
            };
            opts.payload_matches_raw = try arena.dupe(u8, v);
        } else if (std.mem.eql(u8, name, "--reason")) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            opts.reason = std.fmt.parseInt(i64, v, 10) catch return ctx.errf("invalid --reason: '{s}'", .{v});
        } else if (eqAny(name, &.{ "-f", "--fields" })) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            try splitCsv(arena, &fields, v);
        } else if (eqAny(name, &.{ "-o", "--output" })) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            opts.output = std.meta.stringToEnum(OutputFormat, v) orelse
                return ctx.errf("invalid --output '{s}' (expected text|list|table|json|ndjson)", .{v});
        } else if (std.mem.eql(u8, name, "--format")) {
            opts.format = try dupOrErr(&ctx, inline_val, name) orelse return missing(&ctx, name);
        } else if (eqAny(name, &.{ "-n", "--head", "--limit" })) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            opts.head = std.fmt.parseInt(usize, v, 10) catch return ctx.errf("invalid {s}: '{s}'", .{ name, v });
        } else if (std.mem.eql(u8, name, "--tail")) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            opts.tail = std.fmt.parseInt(usize, v, 10) catch return ctx.errf("invalid --tail: '{s}'", .{v});
        } else if (std.mem.eql(u8, name, "--sort-by")) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            opts.sort = std.meta.stringToEnum(SortOrder, v) orelse
                return ctx.errf("invalid --sort-by '{s}' (expected oldest|newest)", .{v});
        } else if (std.mem.eql(u8, name, "--reverse")) {
            opts.sort = .newest;
        } else if (std.mem.eql(u8, name, "--min-count")) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            opts.min_count = std.fmt.parseInt(usize, v, 10) catch return ctx.errf("invalid --min-count: '{s}'", .{v});
        } else if (std.mem.eql(u8, name, "--max-count")) {
            const v = ctx.value(inline_val) orelse return missing(&ctx, name);
            opts.max_count = std.fmt.parseInt(usize, v, 10) catch return ctx.errf("invalid --max-count: '{s}'", .{v});
        } else if (eqAny(name, &.{ "-q", "--quiet" })) {
            opts.quiet = true;
        } else {
            return ctx.errf("unknown flag: {s}", .{name});
        }
    }

    if (opts.head != null and opts.tail != null) {
        return ctx.errf("--head/--limit and --tail are mutually exclusive", .{});
    }
    if (opts.min_count) |min| {
        if (opts.max_count) |max| {
            if (min > max) return ctx.errf("--min-count ({d}) is greater than --max-count ({d})", .{ min, max });
        }
    }

    opts.paths = try paths.toOwnedSlice(arena);
    opts.types = try types.toOwnedSlice(arena);
    opts.encodings = try encodings.toOwnedSlice(arena);
    opts.fields = try fields.toOwnedSlice(arena);
    opts.qos = try qos.toOwnedSlice(arena);
    return .{ .ok = opts };
}

fn eqAny(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, name, c)) return true;
    }
    return false;
}

fn dupOrErr(ctx: *ParseCtx, inline_val: ?[]const u8, name: []const u8) ParseError!?[]const u8 {
    _ = name;
    const v = ctx.value(inline_val) orelse return null;
    return try ctx.arena.dupe(u8, v);
}

fn missing(ctx: *ParseCtx, name: []const u8) ParseError!Result {
    return ctx.errf("missing value for {s}", .{name});
}

pub const usage =
    \\mqtt-log — filter and format mosquitto message-logger log files
    \\
    \\USAGE:
    \\    mqtt-log [OPTIONS] [FILE...]
    \\
    \\Reads the JSON-Lines files written by the mosquitto message logger
    \\(mqtt-messages-YYYYMMDD.log, optionally .gz). With no FILE arguments, the
    \\--dir directory is scanned. Filters apply across all inputs; results are
    \\merged and sorted by time.
    \\
    \\SOURCES:
    \\    FILE...                 Explicit log files (.log or .gz). Overrides --dir.
    \\    -d, --dir <DIR>         Directory to scan (default: /var/log/mosquitto)
    \\        --no-recursive      Do not descend into subdirectories of --dir
    \\
    \\TIME FILTER (inclusive):
    \\        --from <TS>         Lower bound. ISO 8601 (2025-01-01T00:10:00Z),
    \\                            relative (-1h, -30m, -2d, -1w), Unix seconds, or now
    \\        --to <TS>           Upper bound (same formats)
    \\
    \\FIELD FILTERS (repeatable / comma-separated where noted):
    \\    -t, --type <T,...>      Event type: publish_in, publish_out, connect,
    \\                            disconnect, subscribe, unsubscribe
    \\    -e, --encoding <E,...>  Payload encoding: json, text, binary
    \\        --topic <FILTER>    MQTT topic filter with + and # wildcards
    \\        --topic-contains <S>  Substring match on topic
    \\    -c, --client <ID>       Exact client id match
    \\        --qos <N,...>       QoS level(s)
    \\        --retain            Only retained messages
    \\        --no-retain         Only non-retained messages
    \\        --min-size <N>      Minimum payload_len (bytes)
    \\        --max-size <N>      Maximum payload_len (bytes)
    \\        --payload-contains <S>   Literal substring match on decoded payload
    \\        --payload-matches <RE>   Regex match on decoded payload. Supports
    \\                            . * + ? {n,m} | () [] ^ $ and \d \w \s (and negations).
    \\                            Unanchored, so it matches any substring.
    \\        --reason <N>        Exact reason code (disconnect)
    \\
    \\OUTPUT:
    \\    -f, --fields <F,...>    Only show these fields (projection)
    \\    -o, --output <FMT>      text (default), list, table, json, or ndjson
    \\                            list  = one field per line, blank line between records
    \\                            table = column-aligned rows with a header
    \\                            (list/table mirror PowerShell's Format-List/-Table)
    \\        --format <TMPL>     Custom line template, e.g. '{timestamp} {topic} {payload}'
    \\                            {field} is replaced by that field's value; {payload}
    \\                            yields the decoded payload. Overrides --output.
    \\
    \\SELECTION & ORDER:
    \\    -n, --head <N>          Keep only the first N matches (after sorting)
    \\        --tail <N>          Keep only the last N matches
    \\        --sort-by <ORDER>   oldest (default) or newest
    \\        --reverse           Alias for --sort-by newest
    \\
    \\ASSERTIONS (on the number of matching messages, before --head/--tail):
    \\        --min-count <N>     Fail (exit 1) if fewer than N messages match
    \\        --max-count <N>     Fail (exit 1) if more than N messages match
    \\    -q, --quiet             Suppress record output; print only assertion results
    \\
    \\    -h, --help              Show this help
    \\    -V, --version           Show version
    \\
    \\EXIT CODES:
    \\    0  success (and any count assertions passed)
    \\    1  a count assertion failed
    \\    2  usage / argument error
    \\
;
