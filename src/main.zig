const std = @import("std");
const build_options = @import("build_options");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const driver = @import("driver.zig");
const lsp = @import("lsp.zig");
const dap = @import("dap.zig");
const init_mod = @import("init.zig");
const formatter = @import("formatter.zig");
const test_runner = @import("test_runner.zig");

const usage =
    \\Usage: run [command] [options] <file.run>
    \\
    \\Commands:
    \\  build    Compile a .run source file to native binary
    \\  run      Compile and immediately execute
    \\  check    Type-check without generating code
    \\  debug    Start a DAP debug server (for IDEs and AI agents)
    \\  init     Initialize a new Run project
    \\  lsp      Start the LSP server
    \\  fmt      Format .run source files
    \\  test     Discover and validate test functions (compile-only)
    \\  tokens   Dump lexer token stream (debug)
    \\  ast      Dump parsed AST (debug)
    \\
    \\Options:
    \\  -o <file>    Output file name
    \\  --no-dce     Disable dead code elimination
    \\  --force      Overwrite existing files (init)
    \\  --no-color   Disable colored output
    \\  -g           Compile with debug symbols
    \\  -V, --version  Show version
    \\  -h, --help     Show this help message
    \\
;

const File = std.Io.File;
const Dir = std.Io.Dir;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_iter.deinit();
    var stdout_file = File.stdout().writer(io, &.{});
    const stdout = &stdout_file.interface;
    var stderr_file = File.stderr().writer(io, &.{});
    const stderr = &stderr_file.interface;

    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    while (arg_iter.next()) |arg| {
        try args.append(allocator, try allocator.dupe(u8, arg));
    }

    if (args.items.len < 2) {
        try stderr.writeAll(usage);
        std.process.exit(1);
    }

    const command = args.items[1];

    if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        try stdout.writeAll(usage);
        return;
    }

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-V")) {
        try stdout.writeAll("run " ++ build_options.version ++ "\n");
        return;
    }

    if (std.mem.eql(u8, command, "tokens")) {
        if (args.items.len < 3) {
            try stderr.writeAll("Error: no input file\n");
            std.process.exit(1);
        }
        try cmdTokens(io, allocator, args.items[2]);
        return;
    }

    if (std.mem.eql(u8, command, "ast")) {
        if (args.items.len < 3) {
            try stderr.writeAll("Error: no input file\n");
            std.process.exit(1);
        }
        try cmdAst(io, allocator, args.items[2]);
        return;
    }

    if (std.mem.eql(u8, command, "lsp")) {
        try lsp.serve(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "debug")) {
        try dap.serve(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "init")) {
        cmdInit(io, allocator, args.items[2..]);
        return;
    }

    if (std.mem.eql(u8, command, "fmt")) {
        try cmdFmt(io, allocator, args.items[2..]);
        return;
    }

    if (std.mem.eql(u8, command, "test")) {
        try cmdTest(io, allocator, args.items[2..]);
        return;
    }

    if (std.mem.eql(u8, command, "build") or std.mem.eql(u8, command, "check") or std.mem.eql(u8, command, "run")) {
        try cmdBuild(io, allocator, args.items[2..], command);
        return;
    }

    // If the first arg is a .run file, treat it as `run <file>`
    if (std.mem.endsWith(u8, command, ".run")) {
        try cmdBuild(io, allocator, args.items[1..], "run");
        return;
    }

    try stderr.print("Unknown command: {s}\n", .{command});
    try stderr.writeAll(usage);
    std.process.exit(1);
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return Dir.cwd().readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024));
}

fn cmdTokens(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const source = try readFile(io, allocator, path);
    defer allocator.free(source);

    var lexer = Lexer.init(source);
    var stdout_file = File.stdout().writer(io, &.{});
    const stdout = &stdout_file.interface;

    while (true) {
        const tok = lexer.next();
        const text = if (tok.loc.start < tok.loc.end) tok.slice(source) else "";
        try stdout.print("{s:20} | {s}\n", .{ @tagName(tok.tag), text });
        if (tok.tag == .eof) break;
    }
}

fn cmdAst(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const source = try readFile(io, allocator, path);
    defer allocator.free(source);

    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(allocator);
    defer tokens.deinit(allocator);

    var parser = Parser.init(allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();

    var stdout_file = File.stdout().writer(io, &.{});
    const stdout = &stdout_file.interface;

    if (parser.tree.errors.items.len > 0) {
        var stderr_file = File.stderr().writer(io, &.{});
        const stderr = &stderr_file.interface;
        for (parser.tree.errors.items) |err| {
            try stderr.print("error: {s} at offset {d}\n", .{ @tagName(err.tag), err.loc.start });
        }
    }

    // Print all nodes
    for (parser.tree.nodes.items, 0..) |node, i| {
        const text = if (node.main_token < tokens.items.len and
            tokens.items[node.main_token].loc.start < tokens.items[node.main_token].loc.end)
            tokens.items[node.main_token].slice(source)
        else
            "";
        try stdout.print("[{d:4}] {s:20} token={s:15} lhs={d} rhs={d}\n", .{
            i,
            @tagName(node.tag),
            text,
            node.data.lhs,
            node.data.rhs,
        });
    }
}

fn cmdBuild(io: std.Io, allocator: std.mem.Allocator, remaining_args: []const []const u8, command: []const u8) !void {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var no_dce = false;
    var no_color = false;
    var debug_mode = false;

    var i: usize = 0;
    while (i < remaining_args.len) : (i += 1) {
        if (std.mem.eql(u8, remaining_args[i], "--no-dce")) {
            no_dce = true;
        } else if (std.mem.eql(u8, remaining_args[i], "--no-color")) {
            no_color = true;
        } else if (std.mem.eql(u8, remaining_args[i], "-g")) {
            debug_mode = true;
        } else if (std.mem.eql(u8, remaining_args[i], "-o")) {
            i += 1;
            if (i < remaining_args.len) output_path = remaining_args[i];
        } else {
            input_path = remaining_args[i];
        }
    }

    if (input_path == null) {
        var stderr_file = File.stderr().writer(io, &.{});
        try stderr_file.interface.writeAll("Error: no input file\n");
        std.process.exit(1);
    }

    const cmd = if (std.mem.eql(u8, command, "check"))
        driver.Command.check
    else if (std.mem.eql(u8, command, "run"))
        driver.Command.run
    else
        driver.Command.build;

    driver.compile(allocator, .{
        .input_path = input_path.?,
        .output_path = output_path,
        .command = cmd,
        .enable_dce = !no_dce,
        .no_color = no_color,
        .debug = debug_mode,
    }) catch |err| switch (err) {
        error.ParseFailed, error.NamingFailed => std.process.exit(1),
        error.CodegenNotImplemented => return,
        else => {
            var stderr_file = File.stderr().writer(io, &.{});
            stderr_file.interface.print("error: {s}\n", .{@errorName(err)}) catch {};
            std.process.exit(1);
        },
    };
}

fn cmdInit(io: std.Io, allocator: std.mem.Allocator, remaining_args: []const []const u8) void {
    var project_name: ?[]const u8 = null;
    var force = false;

    for (remaining_args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else {
            project_name = arg;
        }
    }

    if (project_name == null) {
        var stderr_file = File.stderr().writer(io, &.{});
        stderr_file.interface.writeAll("Error: missing project name\nUsage: run init <name> [--force]\n       run init . [--force]\n") catch {};
        std.process.exit(1);
    }

    const name = project_name.?;
    const in_place = std.mem.eql(u8, name, ".");
    var cwd_path: ?[:0]u8 = null;
    defer if (cwd_path) |path| allocator.free(path);

    // For in-place init, derive name from current directory
    const effective_name = if (in_place) blk: {
        cwd_path = std.process.currentPathAlloc(io, allocator) catch {
            var stderr_file = File.stderr().writer(io, &.{});
            stderr_file.interface.writeAll("Error: failed to determine current directory name\n") catch {};
            std.process.exit(1);
        };
        break :blk std.fs.path.basename(cwd_path.?);
    } else name;

    init_mod.initProject(io, allocator, .{
        .name = effective_name,
        .force = force,
        .in_place = in_place,
    }) catch |err| switch (err) {
        error.DirectoryExists => std.process.exit(1),
        error.CreateFailed => std.process.exit(1),
        error.OutOfMemory => {
            var stderr_file = File.stderr().writer(io, &.{});
            stderr_file.interface.writeAll("Error: out of memory\n") catch {};
            std.process.exit(1);
        },
    };
}

fn cmdFmt(io: std.Io, allocator: std.mem.Allocator, remaining_args: []const []const u8) !void {
    var check_mode = false;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    for (remaining_args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_mode = true;
        } else {
            try paths.append(allocator, arg);
        }
    }

    if (paths.items.len == 0) {
        var stderr_file = File.stderr().writer(io, &.{});
        try stderr_file.interface.writeAll("Error: no input file or directory\n");
        std.process.exit(1);
    }

    var stderr_file = File.stderr().writer(io, &.{});
    const stderr = &stderr_file.interface;
    var stdout_file = File.stdout().writer(io, &.{});
    const stdout = &stdout_file.interface;
    var any_diff = false;
    const cwd = Dir.cwd();

    for (paths.items) |path| {
        const stat = cwd.statFile(io, path, .{}) catch {
            // Try as directory
            formatDirectory(io, allocator, path, check_mode, &any_diff, stderr, stdout) catch |err| {
                stderr.print("error: could not process '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
            };
            continue;
        };
        if (stat.kind == .directory) {
            formatDirectory(io, allocator, path, check_mode, &any_diff, stderr, stdout) catch |err| {
                stderr.print("error: could not process '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
            };
            continue;
        }
        formatSingleFile(io, allocator, path, check_mode, &any_diff, stderr, stdout) catch |err| {
            stderr.print("error: could not format '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
        };
    }

    if (check_mode and any_diff) {
        std.process.exit(1);
    }
}

fn formatSingleFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    check_mode: bool,
    any_diff: *bool,
    stderr: anytype,
    stdout: anytype,
) !void {
    const source = readFile(io, allocator, path) catch {
        try stderr.print("error: could not read '{s}'\n", .{path});
        return;
    };
    defer allocator.free(source);

    const formatted = formatter.formatSource(allocator, source) catch {
        try stderr.print("error: could not parse '{s}'\n", .{path});
        return;
    };
    defer allocator.free(formatted);

    if (check_mode) {
        if (!std.mem.eql(u8, source, formatted)) {
            try stdout.print("{s}\n", .{path});
            any_diff.* = true;
        }
    } else {
        if (!std.mem.eql(u8, source, formatted)) {
            const file = try Dir.cwd().createFile(io, path, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, formatted);
            try stdout.print("formatted: {s}\n", .{path});
        }
    }
}

fn formatDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    check_mode: bool,
    any_diff: *bool,
    stderr: anytype,
    stdout: anytype,
) !void {
    var dir = try Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".run")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(full_path);
        formatSingleFile(io, allocator, full_path, check_mode, any_diff, stderr, stdout) catch {};
    }
}

fn cmdTest(io: std.Io, allocator: std.mem.Allocator, remaining_args: []const []const u8) !void {
    var filter: ?[]const u8 = null;
    var verbose = false;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    var i: usize = 0;
    while (i < remaining_args.len) : (i += 1) {
        if (std.mem.eql(u8, remaining_args[i], "--filter")) {
            i += 1;
            if (i < remaining_args.len) filter = remaining_args[i];
        } else if (std.mem.eql(u8, remaining_args[i], "--verbose")) {
            verbose = true;
        } else {
            try paths.append(allocator, remaining_args[i]);
        }
    }

    if (paths.items.len == 0) {
        var stderr_file = File.stderr().writer(io, &.{});
        try stderr_file.interface.writeAll("Error: no input file or directory\n");
        std.process.exit(1);
    }

    var stderr_file = File.stderr().writer(io, &.{});
    const stderr = &stderr_file.interface;
    var stdout_file = File.stdout().writer(io, &.{});
    const stdout = &stdout_file.interface;
    try stdout.writeAll("note: `run test` currently validates that discovered `test_*` functions compile; executing test bodies is not implemented yet.\n\n");

    var all_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (all_files.items) |f| allocator.free(f);
        all_files.deinit(allocator);
    }

    for (paths.items) |path| {
        if (std.mem.endsWith(u8, path, ".run")) {
            const owned = try allocator.dupe(u8, path);
            try all_files.append(allocator, owned);
        } else {
            // Treat as directory
            collectRunFiles(io, allocator, path, &all_files) catch |err| {
                stderr.print("error: could not read directory '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
            };
        }
    }

    var total: u32 = 0;
    var passed: u32 = 0;
    var failed: u32 = 0;

    const start_ns = std.Io.Clock.awake.now(io).nanoseconds;

    for (all_files.items) |file_path| {
        const source = readFile(io, allocator, file_path) catch {
            stderr.print("error: could not read '{s}'\n", .{file_path}) catch {};
            continue;
        };
        defer allocator.free(source);

        var tests = test_runner.discoverTests(allocator, source, file_path, filter) catch {
            stderr.print("error: could not parse '{s}'\n", .{file_path}) catch {};
            continue;
        };
        defer tests.deinit(allocator);

        for (tests.items) |t| {
            total += 1;

            // Run the test through the compilation pipeline
            const test_result = test_runner.runSingleTest(allocator, file_path, t.name);

            if (test_result.passed) {
                passed += 1;
                if (verbose) {
                    stdout.print("  PASS  {s}::{s}\n", .{ file_path, t.name }) catch {};
                }
            } else {
                failed += 1;
                stdout.print("  FAIL  {s}::{s}", .{ file_path, t.name }) catch {};
                if (test_result.message.len > 0) {
                    stdout.print(" — {s}", .{test_result.message}) catch {};
                }
                stdout.print("\n", .{}) catch {};
            }
        }
    }

    // Summary
    const elapsed_ns: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - start_ns);
    const elapsed_ms = elapsed_ns / 1_000_000;

    try stdout.print("\n{d} passed, {d} failed, {d} total ({d}ms)\n", .{
        passed, failed, total, elapsed_ms,
    });

    if (failed > 0) {
        std.process.exit(1);
    }
}

fn collectRunFiles(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8, files: *std.ArrayList([]const u8)) !void {
    var dir = try Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".run")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        try files.append(allocator, full_path);
    }
}
