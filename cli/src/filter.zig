//! Record accessors and the match predicate.
//!
//! A "record" is one parsed JSON-Lines object (`std.json.Value` of kind
//! `.object`). Fields are optional per the logger's schema, so every accessor
//! tolerates absence.

const std = @import("std");
const Options = @import("options.zig").Options;

pub const Object = std.json.ObjectMap;

pub fn getStr(obj: Object, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        .number_string => |s| s,
        else => null,
    };
}

pub fn getInt(obj: Object, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

/// Decode a record's payload into raw bytes. Prefers the already-unescaped
/// `payload` string; falls back to base64-decoding `payload_base64` (the only
/// representation present for binary payloads). Returns null when the record
/// carries no payload. Allocates from `arena` on the base64 path.
pub fn payloadBytes(arena: std.mem.Allocator, obj: Object) !?[]const u8 {
    if (getStr(obj, "payload")) |p| return p;
    if (getStr(obj, "payload_base64")) |b64| {
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(b64) catch return null;
        const buf = try arena.alloc(u8, n);
        dec.decode(buf, b64) catch return null;
        return buf;
    }
    return null;
}

/// Standard MQTT topic-filter matching: `+` matches exactly one level, `#`
/// matches the remaining levels (must be the last segment).
pub fn topicMatches(filter: []const u8, topic: []const u8) bool {
    var fi = std.mem.splitScalar(u8, filter, '/');
    var ti = std.mem.splitScalar(u8, topic, '/');
    while (true) {
        const f = fi.next();
        const t = ti.next();
        if (f == null and t == null) return true;
        if (f == null) return false; // filter exhausted, topic has more
        if (std.mem.eql(u8, f.?, "#")) return true; // matches rest (incl. empty)
        if (t == null) return false; // topic exhausted, filter has more
        if (std.mem.eql(u8, f.?, "+")) continue; // single-level wildcard
        if (!std.mem.eql(u8, f.?, t.?)) return false;
    }
}

fn matchesAny(value: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, value, c)) return true;
    }
    return false;
}

/// True if the record satisfies every active filter in `opts`. `ns` is the
/// record's epoch-nanosecond time (already parsed) for the from/to bounds.
pub fn matches(arena: std.mem.Allocator, opts: Options, obj: Object, ns: i96) !bool {
    if (opts.from) |from| {
        if (ns < from) return false;
    }
    if (opts.to) |to| {
        if (ns > to) return false;
    }

    if (opts.types.len > 0) {
        const t = getStr(obj, "type") orelse return false;
        if (!matchesAny(t, opts.types)) return false;
    }
    if (opts.encodings.len > 0) {
        const e = getStr(obj, "payload_encoding") orelse return false;
        if (!matchesAny(e, opts.encodings)) return false;
    }
    if (opts.topic) |filter| {
        const topic = getStr(obj, "topic") orelse return false;
        if (!topicMatches(filter, topic)) return false;
    }
    if (opts.topic_contains) |needle| {
        const topic = getStr(obj, "topic") orelse return false;
        if (std.mem.indexOf(u8, topic, needle) == null) return false;
    }
    if (opts.client) |id| {
        const c = getStr(obj, "client_id") orelse return false;
        if (!std.mem.eql(u8, c, id)) return false;
    }
    if (opts.qos.len > 0) {
        const q = getInt(obj, "qos") orelse return false;
        var ok = false;
        for (opts.qos) |want| {
            if (q == want) {
                ok = true;
                break;
            }
        }
        if (!ok) return false;
    }
    if (opts.retain) |want| {
        const r = getInt(obj, "retain") orelse return false;
        if ((r != 0) != want) return false;
    }
    if (opts.min_size) |min| {
        const len = getInt(obj, "payload_len") orelse return false;
        if (len < 0 or @as(u64, @intCast(len)) < min) return false;
    }
    if (opts.max_size) |max| {
        const len = getInt(obj, "payload_len") orelse return false;
        if (len < 0 or @as(u64, @intCast(len)) > max) return false;
    }
    if (opts.reason) |want| {
        const r = getInt(obj, "reason") orelse return false;
        if (r != want) return false;
    }
    if (opts.payload_contains) |needle| {
        const bytes = (try payloadBytes(arena, obj)) orelse return false;
        if (std.mem.indexOf(u8, bytes, needle) == null) return false;
    }
    if (opts.payload_matches) |re| {
        const bytes = (try payloadBytes(arena, obj)) orelse return false;
        if (!try re.search(arena, bytes)) return false;
    }

    return true;
}

const testing = std.testing;

test "topicMatches exact and levels" {
    try testing.expect(topicMatches("home/status", "home/status"));
    try testing.expect(!topicMatches("home/status", "home/temp"));
}

test "topicMatches single-level +" {
    try testing.expect(topicMatches("home/+/temp", "home/kitchen/temp"));
    try testing.expect(!topicMatches("home/+/temp", "home/kitchen/humidity"));
    try testing.expect(!topicMatches("home/+/temp", "home/temp")); // + needs a level
    try testing.expect(!topicMatches("home/+", "home/a/b"));
}

test "topicMatches multi-level #" {
    try testing.expect(topicMatches("home/#", "home/kitchen/temp"));
    try testing.expect(topicMatches("home/#", "home")); // # matches parent level too
    try testing.expect(topicMatches("#", "any/thing/here"));
    try testing.expect(!topicMatches("home/#", "away/x"));
}
