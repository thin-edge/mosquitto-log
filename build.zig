const std = @import("std");

const cflags = [_][]const u8{
    "-Wall",
    "-Werror",
    "-O2",
    "-fPIC",
    "-D_GNU_SOURCE",
};

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // When a gnu/linux target is selected without an explicit glibc version
    // (notably GoReleaser's zig builder, which passes bare `-Dtarget=x86_64-linux-gnu`),
    // pin an old glibc so the plugin loads across a wide range of distributions.
    // Mirrors the versions used by the `all` step below.
    if (target.result.os.tag == .linux and target.result.abi.isGnu() and target.query.glibc_version == null) {
        var q = target.query;
        q.glibc_version = if (target.result.cpu.arch == .riscv64)
            .{ .major = 2, .minor = 27, .patch = 0 } // RISC-V needs glibc 2.27+
        else
            .{ .major = 2, .minor = 17, .patch = 0 }; // RHEL 7 / CentOS 7 (2013)
        target = b.resolveTargetQuery(q);
    }

    // Version the plugin reports to the broker. GoReleaser passes the release
    // version here (see .goreleaser.yaml); defaults to a dev marker otherwise.
    const plugin_version = b.option(
        []const u8,
        "plugin-version",
        "Version string the plugin reports to mosquitto (default: 0.0.0-dev)",
    ) orelse "0.0.0-dev";

    // Mosquitto 2.1.x headers (downloaded as a dependency).
    const mosquitto_dep = b.dependency("mosquitto", .{});

    // --- Default build: a shared library for the host (or -Dtarget) ---
    const lib = addPlugin(b, target, optimize, mosquitto_dep, plugin_version);
    b.installArtifact(lib);

    // Also install under bin/ with a stable, architecture-independent name.
    // GoReleaser's zig builder expects the artifact at zig-out/<target>/bin/<name>,
    // and a fixed name means users reference the same plugin path in mosquitto.conf
    // regardless of CPU architecture.
    const stable_install = b.addInstallFileWithDir(
        lib.getEmittedBin(),
        .bin,
        "mosquitto_message_logger.so",
    );
    b.getInstallStep().dependOn(&stable_install.step);

    // --- `all` step: cross-compile every supported target ---
    const build_all_step = b.step(
        "all",
        "Build all architectures (glibc + musl + macOS)",
    );

    // Set glibc version for maximum compatibility
    // 2.17 = RHEL 7 / CentOS 7 (2013) - needed for aarch64 minimum
    // Older architectures (x86_64, x86, arm) will use even older versions (2.4) automatically
    // You can adjust this to:
    //   - 2.19 for Ubuntu 14.04+ compatibility
    //   - 2.27 for Ubuntu 18.04+ / Debian 10+ compatibility
    //   - 2.31 for Ubuntu 20.04+ / Debian 11+ compatibility
    const glibc_version = std.SemanticVersion{ .major = 2, .minor = 17, .patch = 0 };

    // RISC-V requires glibc 2.27+ (added in 2018)
    const glibc_version_riscv = std.SemanticVersion{ .major = 2, .minor = 27, .patch = 0 };

    const linux_targets = [_]std.Target.Query{
        // glibc targets (Debian, Ubuntu, RHEL, etc.)
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu, .glibc_version = glibc_version },
        .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .gnu, .glibc_version = glibc_version },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu, .glibc_version = glibc_version },
        .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu, .glibc_version = glibc_version_riscv },
        .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .gnueabihf, .glibc_version = glibc_version, .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm1176jzf_s } },
        .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .gnueabihf, .glibc_version = glibc_version },

        // musl targets (Alpine, embedded systems, etc.)
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .musleabihf, .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm1176jzf_s } },
        .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .musleabihf },

        // macOS
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
    };

    const target_names = [_][]const u8{
        // glibc
        "x86_64",
        "x86",
        "aarch64",
        "riscv64",
        "armv6",
        "armv7",

        // musl
        "x86_64-musl",
        "x86-musl",
        "aarch64-musl",
        "riscv64-musl",
        "armv6-musl",
        "armv7-musl",

        // macOS
        "macos-aarch64",
    };

    for (linux_targets, target_names) |linux_target, target_name| {
        const resolved_target = b.resolveTargetQuery(linux_target);
        const target_lib = addPlugin(b, resolved_target, optimize, mosquitto_dep, plugin_version);

        // Install with an architecture-specific name:
        //   dist/libmosquitto_message_logger-<arch>.<ext>
        const extension = if (resolved_target.result.os.tag == .macos) "dylib" else "so";
        const install_step = b.addInstallFile(
            target_lib.getEmittedBin(),
            b.fmt("dist/libmosquitto_message_logger-{s}.{s}", .{ target_name, extension }),
        );

        build_all_step.dependOn(&install_step.step);
    }
}

/// Build the plugin as a dynamic library against the given mosquitto headers.
/// C sources, include paths and libc linking are configured on the module, as
/// required by the Zig 0.16 build API.
fn addPlugin(
    b: *std.Build,
    resolved_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mosquitto_dep: *std.Build.Dependency,
    plugin_version: []const u8,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = resolved_target,
        .optimize = optimize,
        .link_libc = true,
    });

    // cflags + a -DPLUGIN_VERSION="..." define carrying the build version. The
    // inner quotes are literal so the macro expands to a C string. Arena-allocated
    // so the slice outlives this function.
    const flags = b.allocator.alloc([]const u8, cflags.len + 1) catch @panic("OOM");
    for (cflags, 0..) |f, i| flags[i] = f;
    flags[cflags.len] = b.fmt("-DPLUGIN_VERSION=\"{s}\"", .{plugin_version});

    mod.addCSourceFile(.{
        .file = b.path("mosquitto_message_logger.c"),
        .flags = flags,
    });

    // Mosquitto headers (downloaded as a dependency). `include` covers both the
    // flat 2.0 layout and the 2.1 `mosquitto/` subdirectory.
    mod.addIncludePath(mosquitto_dep.path("include"));
    mod.addIncludePath(mosquitto_dep.path("src"));

    // Mosquitto 2.1's public headers reference <cjson/cJSON.h> for a function
    // this plugin never calls. The compat/ stub satisfies that forward declaration
    // without requiring the full cJSON library.
    mod.addIncludePath(b.path("compat"));

    const lib = b.addLibrary(.{
        .name = "mosquitto_message_logger",
        .root_module = mod,
        .linkage = .dynamic,
    });

    // For plugins, allow undefined symbols (resolved at runtime by mosquitto).
    if (resolved_target.result.os.tag == .linux or resolved_target.result.os.tag == .macos) {
        lib.linker_allow_shlib_undefined = true;
    }

    return lib;
}
