const std = @import("std");
const Token = @import("token.zig").Token;
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const naming = @import("naming.zig");
const driver = @import("driver.zig");
const lsp = @import("lsp.zig");
const init_mod = @import("init.zig");

const usage =
    \\Usage: run [command] [options] <file.run>
    \\
    \\Commands:
    \\  build    Compile a .run source file to native binary
    \\  run      Compile and immediately execute
    \\  check    Type-check without generating code
    \\  init     Initialize a new Run project
    \\  lsp      Start the LSP server
    \\  tokens   Dump lexer token stream (debug)
    \\  ast      Dump parsed AST (debug)
    \\
    \\Options:
    \\  -o <file>    Output file name
    \\  --no-dce     Disable dead code elimination
    \\  --force      Overwrite existing files (init)
    \\  -h, --help   Show this help message
    \\
;

const File = std.fs.File;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try File.stderr().writeAll(usage);
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        try File.stdout().writeAll(usage);
        return;
    }

    if (std.mem.eql(u8, command, "tokens")) {
        if (args.len < 3) {
            try File.stderr().writeAll("Error: no input file\n");
            std.process.exit(1);
        }
        try cmdTokens(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, command, "ast")) {
        if (args.len < 3) {
            try File.stderr().writeAll("Error: no input file\n");
            std.process.exit(1);
        }
        try cmdAst(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, command, "lsp")) {
        try lsp.serve(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "init")) {
        cmdInit(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, command, "build") or std.mem.eql(u8, command, "check") or std.mem.eql(u8, command, "run")) {
        try cmdBuild(allocator, args[2..], command);
        return;
    }

    // If the first arg is a .run file, treat it as `run <file>`
    if (std.mem.endsWith(u8, command, ".run")) {
        try cmdBuild(allocator, args[1..], "run");
        return;
    }

    try File.stderr().deprecatedWriter().print("Unknown command: {s}\n", .{command});
    try File.stderr().writeAll(usage);
    std.process.exit(1);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
}

fn cmdTokens(allocator: std.mem.Allocator, path: []const u8) !void {
    const source = try readFile(allocator, path);
    defer allocator.free(source);

    var lexer = Lexer.init(source);
    const stdout = File.stdout().deprecatedWriter();

    while (true) {
        const tok = lexer.next();
        const text = if (tok.loc.start < tok.loc.end) tok.slice(source) else "";
        try stdout.print("{s:20} | {s}\n", .{ @tagName(tok.tag), text });
        if (tok.tag == .eof) break;
    }
}

fn cmdAst(allocator: std.mem.Allocator, path: []const u8) !void {
    const source = try readFile(allocator, path);
    defer allocator.free(source);

    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(allocator);
    defer tokens.deinit(allocator);

    var parser = Parser.init(allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();

    const stdout = File.stdout().deprecatedWriter();

    if (parser.tree.errors.items.len > 0) {
        const stderr = File.stderr().deprecatedWriter();
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

fn cmdBuild(allocator: std.mem.Allocator, remaining_args: []const []const u8, command: []const u8) !void {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var no_dce = false;

    var i: usize = 0;
    while (i < remaining_args.len) : (i += 1) {
        if (std.mem.eql(u8, remaining_args[i], "--no-dce")) {
            no_dce = true;
        } else if (std.mem.eql(u8, remaining_args[i], "-o")) {
            i += 1;
            if (i < remaining_args.len) output_path = remaining_args[i];
        } else {
            input_path = remaining_args[i];
        }
    }

    if (input_path == null) {
        try File.stderr().writeAll("Error: no input file\n");
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
    }) catch |err| switch (err) {
        error.ParseFailed, error.NamingFailed => std.process.exit(1),
        error.CodegenNotImplemented => return,
        else => {
            File.stderr().deprecatedWriter().print("error: {s}\n", .{@errorName(err)}) catch {};
            std.process.exit(1);
        },
    };
}

fn cmdInit(allocator: std.mem.Allocator, remaining_args: []const []const u8) void {
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
        File.stderr().writeAll("Error: missing project name\nUsage: run init <name> [--force]\n       run init . [--force]\n") catch {};
        std.process.exit(1);
    }

    const name = project_name.?;
    const in_place = std.mem.eql(u8, name, ".");

    // For in-place init, derive name from current directory
    const effective_name = if (in_place) blk: {
        const cwd_path = std.fs.cwd().realpathAlloc(allocator, ".") catch {
            File.stderr().writeAll("Error: failed to determine current directory name\n") catch {};
            std.process.exit(1);
        };
        break :blk std.fs.path.basename(cwd_path);
    } else name;

    init_mod.initProject(allocator, .{
        .name = effective_name,
        .force = force,
        .in_place = in_place,
    }) catch |err| switch (err) {
        error.DirectoryExists => std.process.exit(1),
        error.CreateFailed => std.process.exit(1),
        error.OutOfMemory => {
            File.stderr().writeAll("Error: out of memory\n") catch {};
            std.process.exit(1);
        },
    };
}
