const std = @import("std");
const compiler = @import("compiler");

const Lexer = compiler.Lexer;
const Parser = compiler.Parser;

const WARMUP = 3;
const ITERS = 10;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.fs.File.stdout().deprecatedWriter();

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
            var timer = try std.time.Timer.start();
            var lexer = Lexer.init(source);
            while (true) {
                const tok = lexer.next();
                if (tok.tag == .eof) break;
            }
            timings[iter] = timer.read();
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
            var timer = try std.time.Timer.start();
            var lexer = Lexer.init(source);
            var tokens = try lexer.tokenize(allocator);
            defer tokens.deinit(allocator);
            var parser = Parser.init(allocator, tokens.items, source);
            defer parser.deinit();
            _ = try parser.parseFile();
            timings[iter] = timer.read();
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
            const f = try std.fs.cwd().createFile(tmp_path, .{});
            defer f.close();
            try f.writeAll(source);
        }
        defer std.fs.cwd().deleteFile(tmp_path) catch {};

        const compiler_path = findCompiler(allocator) catch {
            try stdout.writeAll("  (skipped — compiler binary not found, run 'zig build' first)\n");
            break;
        };
        defer allocator.free(compiler_path);

        var timings: [ITERS]u64 = undefined;

        // Warmup
        for (0..WARMUP) |_| {
            _ = runCompilerCheck(allocator, compiler_path, tmp_path) catch continue;
        }

        // Measured
        for (0..ITERS) |iter| {
            var timer = try std.time.Timer.start();
            _ = runCompilerCheck(allocator, compiler_path, tmp_path) catch {
                timings[iter] = 0;
                continue;
            };
            timings[iter] = timer.read();
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
    const writer = buf.writer(allocator);
    try writer.writeAll("package main\n\nuse \"fmt\"\n\n");

    for (0..num_fns) |i| {
        try writer.print("fun func_{d}() {{\n", .{i});
        try writer.writeAll("    let x = 42\n");
        try writer.writeAll("    var y = 10\n");
        try writer.writeAll("    y = y + x\n");
        try writer.writeAll("    if y > 50 {\n");
        try writer.writeAll("        fmt.println(\"big\")\n");
        try writer.writeAll("    } else {\n");
        try writer.writeAll("        fmt.println(\"small\")\n");
        try writer.writeAll("    }\n");
        try writer.writeAll("    var i = 0\n");
        try writer.writeAll("    for i < 3 {\n");
        try writer.writeAll("        i = i + 1\n");
        try writer.writeAll("    }\n");
        try writer.writeAll("    fmt.println(y)\n");
        try writer.writeAll("}\n\n");
    }

    try writer.writeAll("pub fun main() {\n");
    try writer.writeAll("    func_0()\n");
    try writer.writeAll("}\n");

    return buf.toOwnedSlice(allocator);
}

fn findCompiler(allocator: std.mem.Allocator) ![]const u8 {
    const local_path = "zig-out/bin/run";
    if (std.fs.cwd().access(local_path, .{})) |_| {
        return try allocator.dupe(u8, local_path);
    } else |_| {}
    return error.CompilerNotFound;
}

fn runCompilerCheck(
    allocator: std.mem.Allocator,
    compiler_path: []const u8,
    source_path: []const u8,
) !void {
    var child = std.process.Child.init(&.{ compiler_path, "check", "--no-color", source_path }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    // Drain output
    while (true) {
        var buf: [4096]u8 = undefined;
        const n = child.stdout.?.read(&buf) catch break;
        if (n == 0) break;
    }
    while (true) {
        var buf: [4096]u8 = undefined;
        const n = child.stderr.?.read(&buf) catch break;
        if (n == 0) break;
    }

    const result = try child.wait();
    if (result.Exited != 0) return error.CheckFailed;
}
