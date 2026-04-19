const std = @import("std");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const File = std.Io.File;

const Expectations = struct {
    expected_lines: std.ArrayList([]const u8),
    expected_exit_code: u8,
    is_compile_error_test: bool,
    compile_error_text: ?[]const u8,

    fn deinit(self: *Expectations, allocator: Allocator) void {
        self.expected_lines.deinit(allocator);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var stdout_file = File.stdout().writer(io, &.{});
    const stdout = &stdout_file.interface;

    // Parse --filter arg
    var filter: ?[]u8 = null;
    defer if (filter) |f| allocator.free(f);
    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_iter.deinit();
    _ = arg_iter.next();
    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--filter")) {
            const value = arg_iter.next() orelse break;
            if (filter) |previous| allocator.free(previous);
            filter = try allocator.dupe(u8, value);
        }
    }

    // Find the compiler binary
    const compiler_path = findCompiler(io, allocator) catch {
        try stdout.writeAll("error: could not find 'run' compiler binary. Run 'zig build' first.\n");
        std.process.exit(1);
    };
    defer allocator.free(compiler_path);

    // Discover test files
    var test_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (test_files.items) |f| allocator.free(f);
        test_files.deinit(allocator);
    }

    var cases_dir = findCasesDir(io) catch {
        try stdout.writeAll("error: could not find tests/e2e/cases/ directory\n");
        std.process.exit(1);
    };
    defer cases_dir.close(io);

    var iter = cases_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".run")) continue;
        if (filter) |f| {
            if (std.mem.indexOf(u8, entry.name, f) == null) continue;
        }
        try test_files.append(allocator, try allocator.dupe(u8, entry.name));
    }

    // Sort for deterministic ordering
    std.mem.sort([]const u8, test_files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    if (test_files.items.len == 0) {
        try stdout.writeAll("No test files found.\n");
        std.process.exit(1);
    }

    const start_ns = std.Io.Clock.awake.now(io).nanoseconds;

    var passed: usize = 0;
    var failed: usize = 0;

    for (test_files.items) |test_file| {
        const test_path = try std.fmt.allocPrint(allocator, "tests/e2e/cases/{s}", .{test_file});
        defer allocator.free(test_path);

        const source = try Dir.cwd().readFileAlloc(io, test_path, allocator, .limited(10 * 1024 * 1024));
        defer allocator.free(source);

        var expect = parseExpectations(allocator, source);
        defer expect.deinit(allocator);

        const result = runTest(io, allocator, compiler_path, test_path, &expect) catch |err| {
            try stdout.print("FAIL {s}: runner error: {s}\n", .{ test_file, @errorName(err) });
            failed += 1;
            continue;
        };
        defer allocator.free(result.message);

        if (result.passed) {
            try stdout.print("PASS {s}\n", .{test_file});
            passed += 1;
        } else {
            try stdout.print("FAIL {s}: {s}\n", .{ test_file, result.message });
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

fn parseExpectations(allocator: Allocator, source: []const u8) Expectations {
    var expect = Expectations{
        .expected_lines = .empty,
        .expected_exit_code = 0,
        .is_compile_error_test = false,
        .compile_error_text = null,
    };

    var line_iter = std.mem.splitScalar(u8, source, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (std.mem.startsWith(u8, trimmed, "// expect: ")) {
            const text = trimmed["// expect: ".len..];
            expect.expected_lines.append(allocator, text) catch {};
        } else if (std.mem.startsWith(u8, trimmed, "// expect-exit: ")) {
            const code_str = trimmed["// expect-exit: ".len..];
            expect.expected_exit_code = std.fmt.parseInt(u8, code_str, 10) catch 0;
        } else if (std.mem.startsWith(u8, trimmed, "// compile-error: ")) {
            expect.is_compile_error_test = true;
            expect.compile_error_text = trimmed["// compile-error: ".len..];
        } else if (std.mem.eql(u8, trimmed, "// compile-error")) {
            expect.is_compile_error_test = true;
        }
    }

    return expect;
}

fn runTest(
    io: std.Io,
    allocator: Allocator,
    compiler_path: []const u8,
    test_path: []const u8,
    expect: *const Expectations,
) !struct { passed: bool, message: []const u8 } {
    // Generate unique output path
    const stem = std.fs.path.stem(test_path);
    const out_path = try std.fmt.allocPrint(allocator, "/tmp/e2e_{s}", .{stem});
    defer allocator.free(out_path);

    // Compile the test file
    const compile_result = try runProcess(io, allocator, &.{
        compiler_path, "build", "-o", out_path, "--no-color", test_path,
    });
    defer {
        allocator.free(compile_result.stdout);
        allocator.free(compile_result.stderr);
    }

    if (expect.is_compile_error_test) {
        // Expect compilation to fail
        if (compile_result.exit_code == 0) {
            // Clean up the unexpectedly compiled binary
            Dir.cwd().deleteFile(io, out_path) catch {};
            return .{ .passed = false, .message = try allocator.dupe(u8, "expected compilation to fail but it succeeded") };
        }
        if (expect.compile_error_text) |expected_text| {
            if (std.mem.indexOf(u8, compile_result.stderr, expected_text) == null) {
                return .{
                    .passed = false,
                    .message = try std.fmt.allocPrint(allocator, "expected stderr to contain \"{s}\", got: \"{s}\"", .{
                        expected_text,
                        if (compile_result.stderr.len > 200) compile_result.stderr[0..200] else compile_result.stderr,
                    }),
                };
            }
        }
        return .{ .passed = true, .message = try allocator.dupe(u8, "") };
    }

    // Expect compilation to succeed
    if (compile_result.exit_code != 0) {
        return .{
            .passed = false,
            .message = try std.fmt.allocPrint(allocator, "compilation failed (exit {d}): {s}", .{
                compile_result.exit_code,
                if (compile_result.stderr.len > 300) compile_result.stderr[0..300] else compile_result.stderr,
            }),
        };
    }

    // Clean up binary after running
    defer Dir.cwd().deleteFile(io, out_path) catch {};

    // Run the compiled binary
    const run_result = try runProcess(io, allocator, &.{out_path});
    defer {
        allocator.free(run_result.stdout);
        allocator.free(run_result.stderr);
    }

    // Check exit code
    if (run_result.exit_code != expect.expected_exit_code) {
        return .{
            .passed = false,
            .message = try std.fmt.allocPrint(allocator, "expected exit code {d}, got {d}", .{
                expect.expected_exit_code,
                run_result.exit_code,
            }),
        };
    }

    // Check stdout lines
    if (expect.expected_lines.items.len > 0) {
        var actual_lines: std.ArrayList([]const u8) = .empty;
        defer actual_lines.deinit(allocator);

        var line_iter = std.mem.splitScalar(u8, run_result.stdout, '\n');
        while (line_iter.next()) |line| {
            // Skip trailing empty line from final newline
            if (line.len == 0 and line_iter.peek() == null) continue;
            try actual_lines.append(allocator, line);
        }

        if (actual_lines.items.len != expect.expected_lines.items.len) {
            return .{
                .passed = false,
                .message = try std.fmt.allocPrint(allocator, "expected {d} output lines, got {d}.\nExpected:\n{s}\nActual:\n{s}", .{
                    expect.expected_lines.items.len,
                    actual_lines.items.len,
                    formatLines(allocator, expect.expected_lines.items) catch "?",
                    formatLines(allocator, actual_lines.items) catch "?",
                }),
            };
        }

        for (expect.expected_lines.items, 0..) |expected, idx| {
            if (idx >= actual_lines.items.len) break;
            if (!std.mem.eql(u8, actual_lines.items[idx], expected)) {
                return .{
                    .passed = false,
                    .message = try std.fmt.allocPrint(allocator, "line {d}: expected \"{s}\", got \"{s}\"", .{
                        idx + 1,
                        expected,
                        actual_lines.items[idx],
                    }),
                };
            }
        }
    }

    return .{ .passed = true, .message = try allocator.dupe(u8, "") };
}

fn formatLines(allocator: Allocator, lines: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (lines) |line| {
        try buf.appendSlice(allocator, "  ");
        try buf.appendSlice(allocator, line);
        try buf.append(allocator, '\n');
    }
    return buf.toOwnedSlice(allocator);
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
    // Try zig-out/bin/run relative to cwd
    const local_path = "zig-out/bin/run";
    if (Dir.cwd().access(io, local_path, .{})) |_| {
        return try allocator.dupe(u8, local_path);
    } else |_| {}

    return error.CompilerNotFound;
}

fn findCasesDir(io: std.Io) !Dir {
    return Dir.cwd().openDir(io, "tests/e2e/cases", .{ .iterate = true });
}
