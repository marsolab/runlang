const std = @import("std");
const Lexer = @import("compiler").Lexer;
const Parser = @import("compiler").Parser;
const Dir = std.Io.Dir;
const File = std.Io.File;

const WARMUP = 3;
const ITERS = 10;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var stdout_file = File.stdout().writer(io, &.{});
    const stdout = &stdout_file.interface;

    try stdout.writeAll("Run Compiler Benchmarks\n");
    try stdout.writeAll("=======================\n\n");

    const sizes = [_]struct { name: []const u8, num_fns: usize }{
        .{ .name = "small", .num_fns = 10 },
        .{ .name = "medium", .num_fns = 100 },
        .{ .name = "large", .num_fns = 1000 },
    };

    // Generate sources
    var sources: [3][]const u8 = undefined;
    for (sizes, 0..) |size, idx| {
        sources[idx] = try generateSource(allocator, size.num_fns);
    }
    defer for (&sources) |s| allocator.free(s);

    // Lexer benchmark
    try stdout.writeAll("Lexer Throughput\n");
    for (sizes, 0..) |size, idx| {
        const source = sources[idx];
        var timings: [ITERS]u64 = undefined;

        // Warmup
        for (0..WARMUP) |_| {
            var lexer = Lexer.init(source);
            while (true) {
                const tok = lexer.next();
                if (tok.tag == .eof) break;
            }
        }

        // Measured
        for (0..ITERS) |iter| {
            const start_ns = std.Io.Clock.awake.now(io).nanoseconds;
            var lexer = Lexer.init(source);
            while (true) {
                const tok = lexer.next();
                if (tok.tag == .eof) break;
            }
            timings[iter] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - start_ns);
        }

        const stats = computeStats(&timings);
        try printResult(stdout, "lexer", size.name, source.len, stats);
    }
    try stdout.writeAll("\n");

    // Parser benchmark
    try stdout.writeAll("Parser Throughput\n");
    for (sizes, 0..) |size, idx| {
        const source = sources[idx];
        var timings: [ITERS]u64 = undefined;

        // Warmup
        for (0..WARMUP) |_| {
            var lexer = Lexer.init(source);
            var tokens = try lexer.tokenize(allocator);
            defer tokens.deinit(allocator);
            var parser = Parser.init(allocator, tokens.items, source);
            defer parser.deinit();
            _ = try parser.parseFile();
        }

        // Measured
        for (0..ITERS) |iter| {
            const start_ns = std.Io.Clock.awake.now(io).nanoseconds;
            var lexer = Lexer.init(source);
            var tokens = try lexer.tokenize(allocator);
            defer tokens.deinit(allocator);
            var parser = Parser.init(allocator, tokens.items, source);
            defer parser.deinit();
            _ = try parser.parseFile();
            timings[iter] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - start_ns);
        }

        const stats = computeStats(&timings);
        try printResult(stdout, "parser", size.name, source.len, stats);
    }
    try stdout.writeAll("\n");

    // Full pipeline benchmark (check mode via subprocess)
    try stdout.writeAll("Pipeline (check mode)\n");
    for (sizes, 0..) |size, idx| {
        const source = sources[idx];
        const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/run_bench_{s}.run", .{size.name});
        defer allocator.free(tmp_path);

        {
            const f = try Dir.cwd().createFile(io, tmp_path, .{});
            defer f.close(io);
            try f.writeStreamingAll(io, source);
        }
        defer Dir.cwd().deleteFile(io, tmp_path) catch {};

        const compiler_path = findCompiler(io, allocator) catch {
            try stdout.writeAll("  (skipped — compiler binary not found, run 'zig build' first)\n");
            break;
        };
        defer allocator.free(compiler_path);

        var timings: [ITERS]u64 = undefined;

        // Warmup
        for (0..WARMUP) |_| {
            _ = runCompilerCheck(io, allocator, compiler_path, tmp_path) catch continue;
        }

        // Measured
        for (0..ITERS) |iter| {
            const start_ns = std.Io.Clock.awake.now(io).nanoseconds;
            _ = runCompilerCheck(io, allocator, compiler_path, tmp_path) catch {
                timings[iter] = 0;
                continue;
            };
            timings[iter] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - start_ns);
        }

        const stats = computeStats(&timings);
        try printResult(stdout, "pipeline", size.name, source.len, stats);
    }
    try stdout.writeAll("\n");
}

const Stats = struct {
    median_ns: u64,
    min_ns: u64,
    max_ns: u64,
};

fn computeStats(timings: []u64) Stats {
    std.mem.sort(u64, timings, {}, std.sort.asc(u64));
    return .{
        .median_ns = timings[timings.len / 2],
        .min_ns = timings[0],
        .max_ns = timings[timings.len - 1],
    };
}

fn printResult(writer: anytype, category: []const u8, size: []const u8, bytes: usize, stats: Stats) !void {
    const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
    const mbs = if (stats.median_ns > 0)
        @as(f64, @floatFromInt(bytes)) / (@as(f64, @floatFromInt(stats.median_ns)) / 1_000_000_000.0) / (1024.0 * 1024.0)
    else
        0.0;

    try writer.print("  bench  {s}/{s}  {d:>7.1}KB  {d:>7.1} MB/s  med={s}  min={s}  max={s}\n", .{
        category,
        size,
        kb,
        mbs,
        formatDuration(stats.median_ns),
        formatDuration(stats.min_ns),
        formatDuration(stats.max_ns),
    });
}

fn formatDuration(ns: u64) [12]u8 {
    var buf: [12]u8 = .{' '} ** 12;
    if (ns < 1_000) {
        _ = std.fmt.bufPrint(&buf, "{d:>8}ns", .{ns}) catch {};
    } else if (ns < 1_000_000) {
        const us = @as(f64, @floatFromInt(ns)) / 1_000.0;
        _ = std.fmt.bufPrint(&buf, "{d:>7.1}us", .{us}) catch {};
    } else if (ns < 1_000_000_000) {
        const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
        _ = std.fmt.bufPrint(&buf, "{d:>7.1}ms", .{ms}) catch {};
    } else {
        const s = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
        _ = std.fmt.bufPrint(&buf, "{d:>7.2}s ", .{s}) catch {};
    }
    return buf;
}

fn generateSource(allocator: std.mem.Allocator, num_fns: usize) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(allocator, "package main\n\nuse \"fmt\"\n\n");

    for (0..num_fns) |i| {
        try buf.print(allocator, "fun func_{d}() {{\n", .{i});
        try buf.appendSlice(allocator, "    let x = 42\n");
        try buf.appendSlice(allocator, "    var y = 10\n");
        try buf.appendSlice(allocator, "    y = y + x\n");
        try buf.appendSlice(allocator, "    if y > 50 {\n");
        try buf.appendSlice(allocator, "        fmt.println(\"big\")\n");
        try buf.appendSlice(allocator, "    } else {\n");
        try buf.appendSlice(allocator, "        fmt.println(\"small\")\n");
        try buf.appendSlice(allocator, "    }\n");
        try buf.appendSlice(allocator, "    var i = 0\n");
        try buf.appendSlice(allocator, "    for i < 3 {\n");
        try buf.appendSlice(allocator, "        i = i + 1\n");
        try buf.appendSlice(allocator, "    }\n");
        try buf.appendSlice(allocator, "    fmt.println(y)\n");
        try buf.appendSlice(allocator, "}\n\n");
    }

    try buf.appendSlice(allocator, "pub fun main() {\n");
    try buf.appendSlice(allocator, "    func_0()\n");
    try buf.appendSlice(allocator, "}\n");

    return buf.toOwnedSlice(allocator);
}

fn findCompiler(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const local_path = "zig-out/bin/run";
    if (Dir.cwd().access(io, local_path, .{})) |_| {
        return try allocator.dupe(u8, local_path);
    } else |_| {}
    return error.CompilerNotFound;
}

fn runCompilerCheck(
    io: std.Io,
    allocator: std.mem.Allocator,
    compiler_path: []const u8,
    source_path: []const u8,
) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ compiler_path, "check", "--no-color", source_path },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (childExitCode(result.term) != 0) return error.CheckFailed;
}

fn childExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| if (@intFromEnum(sig) + 128 <= std.math.maxInt(u8)) @as(u8, @intCast(@intFromEnum(sig) + 128)) else std.math.maxInt(u8),
        .stopped, .unknown => 1,
    };
}
