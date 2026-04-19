const std = @import("std");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const File = std.Io.File;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var stdout_file = File.stdout().writer(io, &.{});
    const stdout = &stdout_file.interface;

    // Find the compiler binary
    const compiler_path = findCompiler(io, allocator) catch {
        try stdout.writeAll("error: could not find 'run' compiler binary. Run 'zig build' first.\n");
        std.process.exit(1);
    };
    defer allocator.free(compiler_path);

    // Discover example directories containing main.run
    var examples: std.ArrayList([]const u8) = .empty;
    defer {
        for (examples.items) |name| allocator.free(name);
        examples.deinit(allocator);
    }

    var examples_dir = findExamplesDir(io) catch {
        try stdout.writeAll("error: could not find examples/ directory\n");
        std.process.exit(1);
    };
    defer examples_dir.close(io);

    var iter = examples_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        // Check if directory contains main.run
        const main_path = try std.fmt.allocPrint(allocator, "examples/{s}/main.run", .{entry.name});
        defer allocator.free(main_path);

        if (Dir.cwd().access(io, main_path, .{})) |_| {
            try examples.append(allocator, try allocator.dupe(u8, entry.name));
        } else |_| {}
    }

    // Sort for deterministic ordering
    std.mem.sort([]const u8, examples.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    if (examples.items.len == 0) {
        try stdout.writeAll("No example programs found.\n");
        std.process.exit(1);
    }

    try stdout.print("Found {d} example(s)\n\n", .{examples.items.len});

    const start_ns = std.Io.Clock.awake.now(io).nanoseconds;

    var passed: usize = 0;
    var failed: usize = 0;

    for (examples.items) |name| {
        const main_path = try std.fmt.allocPrint(allocator, "examples/{s}/main.run", .{name});
        defer allocator.free(main_path);

        const out_path = try std.fmt.allocPrint(allocator, "/tmp/example_{s}", .{name});
        defer allocator.free(out_path);

        const result = buildExample(io, allocator, compiler_path, main_path, out_path) catch |err| {
            try stdout.print("FAIL {s}: runner error: {s}\n", .{ name, @errorName(err) });
            failed += 1;
            continue;
        };
        defer allocator.free(result.message);

        // Clean up compiled binary
        Dir.cwd().deleteFile(io, out_path) catch {};

        if (result.passed) {
            try stdout.print("PASS {s}\n", .{name});
            passed += 1;
        } else {
            try stdout.print("FAIL {s}: {s}\n", .{ name, result.message });
            failed += 1;
        }
    }

    const elapsed_ms = @as(u64, @intCast(std.Io.Clock.awake.now(io).nanoseconds - start_ns)) / std.time.ns_per_ms;
    try stdout.print("\n{d} passed, {d} failed, {d} total ({d}ms)\n", .{
        passed,
        failed,
        passed + failed,
        elapsed_ms,
    });

    if (failed > 0) {
        std.process.exit(1);
    }
}

fn buildExample(
    io: std.Io,
    allocator: Allocator,
    compiler_path: []const u8,
    source_path: []const u8,
    out_path: []const u8,
) !struct { passed: bool, message: []const u8 } {
    const result = try runProcess(io, allocator, &.{
        compiler_path, "build", "-o", out_path, "--no-color", source_path,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.exit_code != 0) {
        return .{
            .passed = false,
            .message = try std.fmt.allocPrint(allocator, "build failed (exit {d}): {s}", .{
                result.exit_code,
                if (result.stderr.len > 500) result.stderr[0..500] else result.stderr,
            }),
        };
    }

    return .{ .passed = true, .message = try allocator.dupe(u8, "") };
}

const ProcessResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

fn runProcess(io: std.Io, allocator: Allocator, argv: []const []const u8) !ProcessResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(10 * 1024 * 1024),
    });

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = childExitCode(result.term),
    };
}

fn childExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| if (@intFromEnum(sig) + 128 <= std.math.maxInt(u8)) @as(u8, @intCast(@intFromEnum(sig) + 128)) else std.math.maxInt(u8),
        .stopped, .unknown => 1,
    };
}

fn findCompiler(io: std.Io, allocator: Allocator) ![]const u8 {
    const local_path = "zig-out/bin/run";
    if (Dir.cwd().access(io, local_path, .{})) |_| {
        return try allocator.dupe(u8, local_path);
    } else |_| {}

    return error.CompilerNotFound;
}

fn findExamplesDir(io: std.Io) !Dir {
    return Dir.cwd().openDir(io, "examples", .{ .iterate = true });
}
