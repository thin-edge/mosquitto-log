//! Timestamp parsing for the query CLI.
//!
//! Two things live here:
//!   * `parseInstant` — turn a user-supplied string (ISO 8601, a relative
//!     offset like `-1h`, `now`, or a bare Unix seconds value) into an absolute
//!     instant expressed as nanoseconds since the Unix epoch.
//!   * `parseUnixNanos` — turn the logger's `timestamp_unix` field (an exact
//!     `sec.nsec` decimal, read from the raw line to preserve nanosecond
//!     precision) into the same representation, used as the sort/compare key.
//!
//! Everything is nanoseconds-since-epoch as an `i96`, matching
//! `std.Io.Timestamp`, so instants and record times compare directly.

const std = @import("std");

pub const ParseError = error{InvalidTimestamp};

const ns_per_s: i96 = std.time.ns_per_s;

/// Days from the Unix epoch (1970-01-01) to the given civil date, using Howard
/// Hinnant's `days_from_civil` algorithm. Valid for any Gregorian date.
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = y_in - @as(i64, @intFromBool(m <= 2));
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Parse `count` decimal digits starting at `s[i.*]`, advancing `i`.
fn takeInt(s: []const u8, i: *usize, count: usize) ParseError!i64 {
    if (i.* + count > s.len) return error.InvalidTimestamp;
    var v: i64 = 0;
    var n: usize = 0;
    while (n < count) : (n += 1) {
        const c = s[i.* + n];
        if (!isDigit(c)) return error.InvalidTimestamp;
        v = v * 10 + (c - '0');
    }
    i.* += count;
    return v;
}

/// Parse an ISO 8601 timestamp into epoch nanoseconds.
///
/// Accepts `YYYY-MM-DD`, an optional `T`/space time `HH:MM:SS`, an optional
/// fractional second (any number of digits), and an optional zone (`Z`,
/// `+HH:MM`, `+HHMM`, or `+HH`). A missing zone is treated as UTC, matching the
/// logger's `+0000` output.
pub fn parseIso(s: []const u8) ParseError!i96 {
    var i: usize = 0;
    const year = try takeInt(s, &i, 4);
    if (i >= s.len or s[i] != '-') return error.InvalidTimestamp;
    i += 1;
    const month = try takeInt(s, &i, 2);
    if (i >= s.len or s[i] != '-') return error.InvalidTimestamp;
    i += 1;
    const day = try takeInt(s, &i, 2);
    if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidTimestamp;

    var hour: i64 = 0;
    var minute: i64 = 0;
    var second: i64 = 0;
    var frac_ns: i96 = 0;
    var tz_offset_s: i64 = 0;

    if (i < s.len and (s[i] == 'T' or s[i] == ' ')) {
        i += 1;
        hour = try takeInt(s, &i, 2);
        if (i >= s.len or s[i] != ':') return error.InvalidTimestamp;
        i += 1;
        minute = try takeInt(s, &i, 2);
        if (i >= s.len or s[i] != ':') return error.InvalidTimestamp;
        i += 1;
        second = try takeInt(s, &i, 2);

        // Optional fractional seconds: consume digits, scale first 9 to ns.
        if (i < s.len and s[i] == '.') {
            i += 1;
            var scale: i96 = 100_000_000; // first digit is 100ms in ns
            var saw_digit = false;
            while (i < s.len and isDigit(s[i])) : (i += 1) {
                saw_digit = true;
                if (scale >= 1) {
                    frac_ns += @as(i96, s[i] - '0') * scale;
                    scale = @divTrunc(scale, 10);
                }
            }
            if (!saw_digit) return error.InvalidTimestamp;
        }

        // Optional timezone.
        if (i < s.len) {
            switch (s[i]) {
                'Z', 'z' => i += 1,
                '+', '-' => {
                    const sign: i64 = if (s[i] == '-') -1 else 1;
                    i += 1;
                    const oh = try takeInt(s, &i, 2);
                    var om: i64 = 0;
                    if (i < s.len) {
                        if (s[i] == ':') i += 1;
                        if (i < s.len and isDigit(s[i])) om = try takeInt(s, &i, 2);
                    }
                    tz_offset_s = sign * (oh * 3600 + om * 60);
                },
                else => return error.InvalidTimestamp,
            }
        }
    }

    if (hour > 23 or minute > 59 or second > 60) return error.InvalidTimestamp;
    if (i != s.len) return error.InvalidTimestamp;

    const days = daysFromCivil(year, month, day);
    const secs: i96 = @as(i96, days) * 86_400 + hour * 3600 + minute * 60 + second - tz_offset_s;
    return secs * ns_per_s + frac_ns;
}

/// Parse a relative offset like `-1h`, `+30m`, `-2d`. Sign is required. Units:
/// `s` seconds, `m` minutes, `h` hours, `d` days, `w` weeks. Returned as a
/// signed nanosecond delta.
fn parseOffset(s: []const u8) ParseError!i96 {
    if (s.len < 3) return error.InvalidTimestamp;
    const sign: i96 = switch (s[0]) {
        '-' => -1,
        '+' => 1,
        else => return error.InvalidTimestamp,
    };
    const unit = s[s.len - 1];
    const digits = s[1 .. s.len - 1];
    if (digits.len == 0) return error.InvalidTimestamp;
    var magnitude: i96 = 0;
    for (digits) |c| {
        if (!isDigit(c)) return error.InvalidTimestamp;
        magnitude = magnitude * 10 + (c - '0');
    }
    const unit_ns: i96 = switch (unit) {
        's' => std.time.ns_per_s,
        'm' => std.time.ns_per_min,
        'h' => std.time.ns_per_hour,
        'd' => std.time.ns_per_day,
        'w' => std.time.ns_per_week,
        else => return error.InvalidTimestamp,
    };
    return sign * magnitude * unit_ns;
}

/// Parse a `sec.nsec` decimal (the logger's `timestamp_unix`) into epoch
/// nanoseconds without floating-point rounding. A missing fractional part is
/// allowed. Also handles a leading `-` for completeness.
pub fn parseUnixNanos(s_in: []const u8) ParseError!i96 {
    var s = s_in;
    var sign: i96 = 1;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        if (s[0] == '-') sign = -1;
        s = s[1..];
    }
    if (s.len == 0) return error.InvalidTimestamp;

    var sec: i96 = 0;
    var i: usize = 0;
    while (i < s.len and isDigit(s[i])) : (i += 1) {
        sec = sec * 10 + (s[i] - '0');
    }
    var frac_ns: i96 = 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var scale: i96 = 100_000_000;
        while (i < s.len and isDigit(s[i])) : (i += 1) {
            if (scale >= 1) {
                frac_ns += @as(i96, s[i] - '0') * scale;
                scale = @divTrunc(scale, 10);
            }
        }
    }
    if (i != s.len) return error.InvalidTimestamp;
    return sign * (sec * ns_per_s + frac_ns);
}

/// Parse a user-supplied instant. Order of interpretation:
///   1. `now`             → `now_ns`
///   2. `-1h` / `+30m`    → `now_ns` + offset
///   3. `1770964807[.x]`  → bare Unix seconds
///   4. otherwise         → ISO 8601
pub fn parseInstant(s: []const u8, now_ns: i96) ParseError!i96 {
    if (s.len == 0) return error.InvalidTimestamp;
    if (std.mem.eql(u8, s, "now")) return now_ns;
    if (s[0] == '-' or s[0] == '+') return now_ns + try parseOffset(s);

    // Bare Unix seconds: all digits with an optional single dot.
    var only_numeric = true;
    var dots: usize = 0;
    for (s) |c| {
        if (c == '.') {
            dots += 1;
        } else if (!isDigit(c)) {
            only_numeric = false;
            break;
        }
    }
    if (only_numeric and dots <= 1) return try parseUnixNanos(s);

    return try parseIso(s);
}

const Ymd = struct { year: i64, month: i64, day: i64 };

/// Inverse of `daysFromCivil`: turn a day count since the Unix epoch back into a
/// civil date (Howard Hinnant's `civil_from_days`).
fn civilFromDays(z_in: i64) Ymd {
    const z = z_in + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100)); // [0, 365]
    const mp = @divTrunc(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1; // [1, 31]
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{ .year = y + @as(i64, @intFromBool(m <= 2)), .month = m, .day = d };
}

/// Format epoch nanoseconds as an ISO 8601 UTC timestamp with seconds
/// precision, e.g. "2026-07-06T08:38:00Z". Sub-second digits are truncated (the
/// display is for human context, not round-tripping). Writes into `buf` and
/// returns the written slice.
pub fn formatIso(ns: i96, buf: []u8) []const u8 {
    const total_secs: i64 = @intCast(@divFloor(ns, ns_per_s));
    const days = @divFloor(total_secs, 86_400);
    const rem = total_secs - days * 86_400; // [0, 86399] because divFloor
    const hour = @divTrunc(rem, 3600);
    const minute = @divTrunc(@mod(rem, 3600), 60);
    const second = @mod(rem, 60);
    const ymd = civilFromDays(days);
    // Cast to unsigned: Zig 0.16 prints a leading '+' for signed integers, which
    // would corrupt the fixed-width fields (values are always non-negative here).
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u32, @intCast(ymd.year)),   @as(u32, @intCast(ymd.month)),  @as(u32, @intCast(ymd.day)),
        @as(u32, @intCast(hour)),       @as(u32, @intCast(minute)),     @as(u32, @intCast(second)),
    }) catch buf[0..0];
}

/// Whether a user-supplied timestamp benefits from also showing its resolved
/// absolute date: relative offsets (`-1h`, `+30m`), `now`, and bare Unix
/// seconds. An already-absolute ISO string does not.
pub fn needsResolution(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.eql(u8, s, "now")) return true;
    if (s[0] == '-' or s[0] == '+') return true;
    for (s) |c| {
        if (!(isDigit(c) or c == '.')) return false;
    }
    return true; // all-numeric => Unix seconds
}

const testing = std.testing;

test "formatIso round-trips to seconds" {
    var buf: [32]u8 = undefined;
    const ns: i96 = 1770964807 * std.time.ns_per_s + 822_347_123;
    // Formats at seconds precision (fraction truncated).
    try testing.expectEqualStrings("2026-02-13T06:40:07Z", formatIso(ns, &buf));
    // And parsing it back yields the whole-second instant.
    try testing.expectEqual(@as(i96, 1770964807 * std.time.ns_per_s), try parseIso(formatIso(ns, &buf)));
}

test "needsResolution" {
    try testing.expect(needsResolution("-1h"));
    try testing.expect(needsResolution("+30m"));
    try testing.expect(needsResolution("now"));
    try testing.expect(needsResolution("1770964807"));
    try testing.expect(!needsResolution("2026-02-13T06:40:07Z"));
    try testing.expect(!needsResolution("2026-02-13"));
}


test "parseIso basic UTC" {
    // 2026-02-13T06:40:07Z -> 1770964807 s
    try testing.expectEqual(@as(i96, 1770964807 * std.time.ns_per_s), try parseIso("2026-02-13T06:40:07Z"));
}

test "parseIso fractional and offset" {
    const a = try parseIso("2026-02-13T06:40:07.822347+0000");
    try testing.expectEqual(@as(i96, 1770964807 * std.time.ns_per_s + 822_347_000), a);
    // +01:00 offset means the UTC instant is one hour earlier.
    const b = try parseIso("2026-02-13T07:40:07+01:00");
    try testing.expectEqual(@as(i96, 1770964807 * std.time.ns_per_s), b);
}

test "parseIso date only" {
    try testing.expectEqual(@as(i96, 1770940800 * std.time.ns_per_s), try parseIso("2026-02-13"));
}

test "parseUnixNanos preserves nanoseconds" {
    try testing.expectEqual(@as(i96, 1770964807 * std.time.ns_per_s + 822_347_123), try parseUnixNanos("1770964807.822347123"));
    try testing.expectEqual(@as(i96, 5 * std.time.ns_per_s), try parseUnixNanos("5"));
}

test "parseInstant relative offset" {
    const now: i96 = 1_000 * std.time.ns_per_s;
    try testing.expectEqual(now - std.time.ns_per_hour, try parseInstant("-1h", now));
    try testing.expectEqual(now + 30 * std.time.ns_per_min, try parseInstant("+30m", now));
    try testing.expectEqual(now, try parseInstant("now", now));
}

test "parseInstant rejects garbage" {
    try testing.expectError(error.InvalidTimestamp, parseInstant("not-a-date", 0));
}
