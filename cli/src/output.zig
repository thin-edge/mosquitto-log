//! Rendering of matched records to the output writer.
//!
//! Output modes: `text` (single key=value line per record), `list` (one field
//! per line, Format-List style), `ndjson` (one JSON object per line), `json`
//! (a JSON array — the array framing is handled by the caller), and a custom
//! `--format` template.

const std = @import("std");
const filter = @import("filter.zig");
const Object = filter.Object;
const opts_mod = @import("options.zig");

/// Fields shown by `text`/`list`/`table` output when the user gives no explicit
/// `--fields`. The verbose `payload_json` / `payload_base64` / `payload_len` are
/// omitted by default; ask for them explicitly with `--fields`.
pub const default_fields = [_][]const u8{
    "timestamp", "type", "client_id", "topic", "qos", "retain", "reason", "payload",
};

/// Write a JSON value as a bare display string (no surrounding quotes for
/// strings), for `text` and `--format` output. Objects/arrays are minified.
fn writeScalar(w: *std.Io.Writer, v: std.json.Value) !void {
    switch (v) {
        .string => |s| try w.writeAll(s),
        .number_string => |s| try w.writeAll(s),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .null => try w.writeAll("null"),
        .object, .array => try std.json.Stringify.value(v, .{}, w),
    }
}

/// Resolve a field name to a printable value and write it. `payload` is special:
/// it yields the decoded payload bytes (text or base64-decoded), so it works
/// even for records that only carry `payload_base64`.
fn writeField(w: *std.Io.Writer, arena: std.mem.Allocator, obj: Object, name: []const u8) !bool {
    if (std.mem.eql(u8, name, "payload")) {
        if (try filter.payloadBytes(arena, obj)) |bytes| {
            try w.writeAll(bytes);
            return true;
        }
        return false;
    }
    const v = obj.get(name) orelse return false;
    try writeScalar(w, v);
    return true;
}

/// Emit `key=value` pairs for the present fields, joined by `separator`. Used
/// by both `text` (separator = " ", single line) and `list` (separator =
/// "\n", one field per line). Only fields actually present are emitted (and
/// `payload` only when decodable).
fn writeKeyValues(
    w: *std.Io.Writer,
    arena: std.mem.Allocator,
    obj: Object,
    fields: []const []const u8,
    separator: []const u8,
) !void {
    const names = if (fields.len > 0) fields else &default_fields;
    var first = true;
    for (names) |name| {
        if (std.mem.eql(u8, name, "payload")) {
            const bytes = (try filter.payloadBytes(arena, obj)) orelse continue;
            if (!first) try w.writeAll(separator);
            try w.print("{s}=", .{name});
            try w.writeAll(bytes);
            first = false;
            continue;
        }
        const v = obj.get(name) orelse continue;
        if (!first) try w.writeAll(separator);
        try w.print("{s}=", .{name});
        try writeScalar(w, v);
        first = false;
    }
}

/// Single-line `key=value key=value ...` per record.
pub fn renderText(w: *std.Io.Writer, arena: std.mem.Allocator, obj: Object, fields: []const []const u8) !void {
    try writeKeyValues(w, arena, obj, fields, " ");
    try w.writeByte('\n');
}

/// Multi-line block (like PowerShell's Format-List): one `key=value` per line,
/// followed by a blank line so consecutive records are visually separated.
pub fn renderList(w: *std.Io.Writer, arena: std.mem.Allocator, obj: Object, fields: []const []const u8) !void {
    try writeKeyValues(w, arena, obj, fields, "\n");
    try w.writeAll("\n\n");
}

/// The display string for one field of a record, always allocated in `arena`
/// (so it survives the record's parse being freed). `payload` yields the decoded
/// payload; absent fields yield "". Used to build `table` rows.
pub fn cellString(arena: std.mem.Allocator, obj: Object, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "payload")) {
        const bytes = (try filter.payloadBytes(arena, obj)) orelse return "";
        return arena.dupe(u8, bytes);
    }
    const v = obj.get(name) orelse return "";
    return switch (v) {
        .string => |s| try arena.dupe(u8, s),
        .number_string => |s| try arena.dupe(u8, s),
        .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        .object, .array => try std.json.Stringify.valueAlloc(arena, v, .{}),
    };
}

/// Display width of a cell: UTF-8 codepoint count (byte length if invalid).
/// Good enough for the ASCII-heavy fields; wide/control characters may still
/// misalign (payloads with such bytes are best excluded via `--fields`).
fn displayWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// A column is right-aligned when every non-empty cell looks numeric.
fn looksNumeric(s: []const u8) bool {
    var has_digit = false;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            has_digit = true;
        } else if (c != '.' and c != '-' and c != '+' and c != 'e' and c != 'E') {
            return false;
        }
    }
    return has_digit;
}

fn writeRepeat(w: *std.Io.Writer, byte: u8, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeByte(byte);
}

/// Write one table row's content (no trailing newline). Numeric columns are
/// right-aligned; text columns left-aligned with no trailing pad on the last.
fn writeTableRow(w: *std.Io.Writer, cells: []const []const u8, widths: []const usize, numeric: []const bool) !void {
    for (cells, 0..) |cell, i| {
        if (i > 0) try w.writeAll("  ");
        const pad = widths[i] -| displayWidth(cell);
        if (numeric[i]) {
            try writeRepeat(w, ' ', pad); // right-align
            try w.writeAll(cell);
        } else {
            try w.writeAll(cell);
            if (i != cells.len - 1) try writeRepeat(w, ' ', pad); // left-align, no trailing pad
        }
    }
}

/// Clip `s` to at most `max_cols` display columns, at a UTF-8 boundary.
fn clipToColumns(s: []const u8, max_cols: usize) []const u8 {
    var view = std.unicode.Utf8View.init(s) catch return s[0..@min(max_cols, s.len)];
    var it = view.iterator();
    var cols: usize = 0;
    var end: usize = 0;
    while (it.nextCodepointSlice()) |cp| {
        if (cols >= max_cols) break;
        cols += 1;
        end += cp.len;
    }
    return s[0..end];
}

/// Write a pre-built line, clipped to `max_width` columns if given, plus a
/// newline. Used for the header and separator so they never wrap.
fn writeClipped(w: *std.Io.Writer, line: []const u8, max_width: ?usize) !void {
    const out = if (max_width) |mw| clipToColumns(line, mw) else line;
    try w.writeAll(out);
    try w.writeByte('\n');
}

/// Render `rows` as a column-aligned table (like PowerShell's Format-Table):
/// a header row, a dashed separator, then the data. Column widths are the max
/// cell width; numeric columns are right-aligned. Emits nothing for no rows.
/// Each row must have exactly `headers.len` cells.
///
/// The header and separator are clipped to `max_width` columns (the terminal
/// width, when known) so they never wrap; **data rows are printed in full** and
/// may exceed the terminal width.
pub fn writeTable(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    headers: []const []const u8,
    rows: []const []const []const u8,
    max_width: ?usize,
) !void {
    if (rows.len == 0) return;
    const ncol = headers.len;

    const widths = try gpa.alloc(usize, ncol);
    defer gpa.free(widths);
    const numeric = try gpa.alloc(bool, ncol);
    defer gpa.free(numeric);

    for (headers, 0..) |h, i| {
        widths[i] = displayWidth(h);
        numeric[i] = true; // until a non-numeric value disproves it
    }
    for (rows) |cells| {
        for (cells, 0..) |c, i| {
            widths[i] = @max(widths[i], displayWidth(c));
            if (c.len > 0 and !looksNumeric(c)) numeric[i] = false;
        }
    }

    // Header and separator are built into a scratch buffer so they can be
    // clipped to the terminal width before writing.
    var line = std.Io.Writer.Allocating.init(gpa);
    defer line.deinit();

    try writeTableRow(&line.writer, headers, widths, numeric);
    try writeClipped(w, line.written(), max_width);

    line.clearRetainingCapacity();
    for (widths, 0..) |width, i| {
        if (i > 0) try line.writer.writeAll("  ");
        try writeRepeat(&line.writer, '-', width);
    }
    try writeClipped(w, line.written(), max_width);

    for (rows) |cells| {
        try writeTableRow(w, cells, widths, numeric);
        try w.writeByte('\n');
    }
}

/// Render a record as a single minified JSON object. When `fields` is empty and
/// `raw_line` is given, the original line is emitted verbatim (lossless, fast).
/// Otherwise a projected object is built.
pub fn renderJsonObject(
    w: *std.Io.Writer,
    obj: Object,
    fields: []const []const u8,
    raw_line: ?[]const u8,
) !void {
    if (fields.len == 0) {
        if (raw_line) |line| {
            try w.writeAll(line);
            return;
        }
        try std.json.Stringify.value(std.json.Value{ .object = obj }, .{}, w);
        return;
    }
    var s: std.json.Stringify = .{ .writer = w, .options = .{} };
    try s.beginObject();
    for (fields) |name| {
        const v = obj.get(name) orelse continue;
        try s.objectField(name);
        try s.write(v);
    }
    try s.endObject();
}

/// Render a `--format` template. `{name}` is replaced by the field's value
/// (empty if absent); `{payload}` yields the decoded payload. `{{` / `}}` are
/// literal braces.
pub fn renderFormat(w: *std.Io.Writer, arena: std.mem.Allocator, obj: Object, template: []const u8) !void {
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c == '{') {
            if (i + 1 < template.len and template[i + 1] == '{') {
                try w.writeByte('{');
                i += 2;
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, template, i + 1, '}') orelse {
                // Unterminated: emit the rest literally.
                try w.writeAll(template[i..]);
                break;
            };
            const name = template[i + 1 .. end];
            _ = try writeField(w, arena, obj, name);
            i = end + 1;
        } else if (c == '}' and i + 1 < template.len and template[i + 1] == '}') {
            try w.writeByte('}');
            i += 2;
        } else {
            try w.writeByte(c);
            i += 1;
        }
    }
    try w.writeByte('\n');
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "looksNumeric" {
    try testing.expect(looksNumeric("0"));
    try testing.expect(looksNumeric("22.5"));
    try testing.expect(looksNumeric("-3"));
    try testing.expect(looksNumeric("1.2e9"));
    try testing.expect(!looksNumeric(""));
    try testing.expect(!looksNumeric("online"));
    try testing.expect(!looksNumeric("home/temp"));
}

test "writeTable aligns columns and right-aligns numeric" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const headers = [_][]const u8{ "type", "topic", "qos" };
    const rows = [_][]const []const u8{
        &.{ "publish_in", "home/temperature", "1" },
        &.{ "connect", "a", "0" },
    };
    try writeTable(&aw.writer, testing.allocator, &headers, &rows, null);
    const expected =
        "type        topic             qos\n" ++
        "----------  ----------------  ---\n" ++
        "publish_in  home/temperature    1\n" ++
        "connect     a                   0\n";
    try testing.expectEqualStrings(expected, aw.written());
}

test "writeTable clips header and separator to max_width, not data rows" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const headers = [_][]const u8{ "type", "topic" };
    const rows = [_][]const []const u8{
        &.{ "publish_in", "home/temperature" },
    };
    try writeTable(&aw.writer, testing.allocator, &headers, &rows, 12);
    // Columns size to the data (type->10, topic->16). Header and separator are
    // clipped to 12 columns; the data row is printed in full.
    const expected =
        "type        \n" ++ // "type" + 8 spaces = 12 cols
        "----------  \n" ++ // 10 dashes + 2 spaces = 12 cols
        "publish_in  home/temperature\n";
    try testing.expectEqualStrings(expected, aw.written());
}

test "writeTable emits nothing for no rows" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const headers = [_][]const u8{ "type", "topic" };
    try writeTable(&aw.writer, testing.allocator, &headers, &.{}, null);
    try testing.expectEqualStrings("", aw.written());
}
