const std = @import("std");
const Token = @import("token.zig").Token;
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const naming = @import("naming.zig");

const usage =
    \\Usage: run [command] [options] <file.run>
    \\
    \\Commands:
    \\  build    Compile a .run source file to native binary
    \\  run      Compile and immediately execute
    \\  check    Type-check without generating code
    \\  tokens   Dump lexer token stream (debug)
    \\  ast      Dump parsed AST (debug)
    \\
    \\Options:
    \\  -o <file>    Output file name
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

    if (std.mem.eql(u8, command, "build") or std.mem.eql(u8, command, "check")) {
        if (args.len < 3) {
            try File.stderr().writeAll("Error: no input file\n");
            std.process.exit(1);
        }
        try cmdBuild(allocator, args[2], command);
        return;
    }

    // If the first arg is a .run file, treat it as `run <file>`
    if (std.mem.endsWith(u8, command, ".run")) {
        try cmdBuild(allocator, command, "run");
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

fn cmdBuild(allocator: std.mem.Allocator, path: []const u8, command: []const u8) !void {
    const source = try readFile(allocator, path);
    defer allocator.free(source);

    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(allocator);
    defer tokens.deinit(allocator);

    var parser = Parser.init(allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();

    const stderr = File.stderr().deprecatedWriter();

    if (parser.tree.errors.items.len > 0) {
        for (parser.tree.errors.items) |err| {
            try stderr.print("error: {s} at offset {d}\n", .{ @tagName(err.tag), err.loc.start });
        }
        std.process.exit(1);
    }

    var naming_violations = try naming.checkNaming(allocator, path, &parser.tree, tokens.items);
    defer naming_violations.deinit(allocator);

    if (naming_violations.items.len > 0) {
        for (naming_violations.items) |violation| {
            const rule = switch (violation.tag) {
                .type_must_be_upper_camel => "type names must start with an uppercase letter and use CamelCase",
                .variable_must_be_lower_camel => "variable names must start with a lowercase letter and use camelCase",
                .file_must_be_lower_snake => "file names must start with a lowercase letter and use snake_case",
            };
            if (violation.loc.start == 0 and violation.loc.end == 0) {
                try stderr.print("error: naming violation: {s}: '{s}' ({s})\n", .{ rule, violation.name, path });
            } else {
                try stderr.print("error: naming violation at offset {d}: {s}: '{s}'\n", .{ violation.loc.start, rule, violation.name });
            }
        }
        std.process.exit(1);
    }

    const stdout = File.stdout().deprecatedWriter();
    if (std.mem.eql(u8, command, "check")) {
        try stdout.print("check: {s} OK ({d} nodes)\n", .{ path, parser.tree.nodes.items.len });
    } else {
        try stdout.print("parse: {s} OK ({d} nodes)\n", .{ path, parser.tree.nodes.items.len });
        try stderr.writeAll("note: codegen not yet implemented\n");
    }
}
