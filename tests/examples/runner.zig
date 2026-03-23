const std = @import("std");

const Allocator = std.mem.Allocator;

const TestResult = struct {
    name: []const u8,
    passed: bool,
    message: []const u8,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Find the compiler binary
    const compiler_path = findCompiler(allocator) catch {
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

    var examples_dir = findExamplesDir() catch {
        try stdout.writeAll("error: could not find examples/ directory\n");
        std.process.exit(1);
    };
    defer examples_dir.close();

    var iter = examples_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        // Check if directory contains main.run
        const main_path = try std.fmt.allocPrint(allocator, "examples/{s}/main.run", .{entry.name});
        defer allocator.free(main_path);

        if (std.fs.cwd().access(main_path, .{})) |_| {
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

    var timer = try std.time.Timer.start();

    var passed: usize = 0;
    var failed: usize = 0;

    for (examples.items) |name| {
        const main_path = try std.fmt.allocPrint(allocator, "examples/{s}/main.run", .{name});
        defer allocator.free(main_path);

        const out_path = try std.fmt.allocPrint(allocator, "/tmp/example_{s}", .{name});
        defer allocator.free(out_path);

        const result = buildExample(allocator, compiler_path, main_path, out_path) catch |err| {
            try stdout.print("FAIL {s}: runner error: {s}\n", .{ name, @errorName(err) });
            failed += 1;
            continue;
        };
        defer allocator.free(result.message);

        // Clean up compiled binary
        std.fs.cwd().deleteFile(out_path) catch {};

        if (result.passed) {
            try stdout.print("PASS {s}\n", .{name});
            passed += 1;
        } else {
            try stdout.print("FAIL {s}: {s}\n", .{ name, result.message });
            failed += 1;
        }
    }

    const elapsed_ms = timer.read() / std.time.ns_per_ms;
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
    allocator: Allocator,
    compiler_path: []const u8,
    source_path: []const u8,
    out_path: []const u8,
) !struct { passed: bool, message: []const u8 } {
    const result = try runProcess(allocator, &.{
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
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
};

fn runProcess(allocator: Allocator, argv: []const []const u8) !ProcessResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    while (true) {
        var buf: [4096]u8 = undefined;
        const n = child.stdout.?.read(&buf) catch break;
        if (n == 0) break;
        try stdout_buf.appendSlice(allocator, buf[0..n]);
    }

    while (true) {
        var buf: [4096]u8 = undefined;
        const n = child.stderr.?.read(&buf) catch break;
        if (n == 0) break;
        try stderr_buf.appendSlice(allocator, buf[0..n]);
    }

    const result = try child.wait();

    return .{
        .stdout = try stdout_buf.toOwnedSlice(allocator),
        .stderr = try stderr_buf.toOwnedSlice(allocator),
        .exit_code = result.Exited,
    };
}

fn findCompiler(allocator: Allocator) ![]const u8 {
    const local_path = "zig-out/bin/run";
    if (std.fs.cwd().access(local_path, .{})) |_| {
        return try allocator.dupe(u8, local_path);
    } else |_| {}

    return error.CompilerNotFound;
}

fn findExamplesDir() !std.fs.Dir {
    return std.fs.cwd().openDir("examples", .{ .iterate = true });
}
