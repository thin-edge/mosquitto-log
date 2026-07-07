//! Input discovery and reading.
//!
//! `collect` produces the ordered list of files to read (explicit paths, or a
//! scan of `--dir`); `readContents` reads one file, transparently decompressing
//! `.gz` archives. All buffers come from the caller's arena.

const std = @import("std");
const flate = std.compress.flate;
const Options = @import("options.zig").Options;

const Io = std.Io;
const Dir = std.Io.Dir;

/// A directory scan picks up any file ending in `.log` or `.gz` (covers
/// `mqtt-messages-YYYYMMDD.log` and archived forms like `...log.gz`, as well as
/// arbitrarily named log files). Lines that are not valid records are skipped
/// during parsing, so unrelated files are harmless. Explicit path arguments
/// bypass this filter entirely.
fn isLogFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".log") or std.mem.endsWith(u8, name, ".gz");
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Build the list of input files. When `opts.paths` is non-empty those are used
/// verbatim; otherwise `opts.dir` is scanned (recursively unless
/// `--no-recursive`). Returned paths are joined against `opts.dir` and sorted.
pub fn collect(arena: std.mem.Allocator, io: Io, opts: Options) ![]const []const u8 {
    if (opts.paths.len > 0) return opts.paths;

    var list: std.ArrayList([]const u8) = .empty;

    var dir = Dir.cwd().openDir(io, opts.dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return list.toOwnedSlice(arena), // no dir -> no files
        else => return err,
    };
    defer dir.close(io);

    if (opts.recursive) {
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!isLogFile(entry.basename)) continue;
            const joined = try std.fs.path.join(arena, &.{ opts.dir, entry.path });
            try list.append(arena, joined);
        }
    } else {
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!isLogFile(entry.name)) continue;
            const joined = try std.fs.path.join(arena, &.{ opts.dir, entry.name });
            try list.append(arena, joined);
        }
    }

    const slice = try list.toOwnedSlice(arena);
    std.mem.sort([]const u8, slice, {}, lessThanStr);
    return slice;
}

/// Read a file into memory, decompressing if the name ends in `.gz`.
pub fn readContents(arena: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    const raw = try Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    if (!std.mem.endsWith(u8, path, ".gz")) return raw;

    var in: Io.Reader = .fixed(raw);
    var window: [flate.max_window_len]u8 = undefined;
    var d = flate.Decompress.init(&in, .gzip, &window);
    return try d.reader.allocRemaining(arena, .unlimited);
}
