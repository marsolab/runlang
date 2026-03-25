const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Token = @import("token.zig").Token;
const ast = @import("ast.zig");
const NodeIndex = ast.NodeIndex;
const null_node = ast.null_node;

/// A discovered test case from a .run source file.
pub const TestCase = struct {
    name: []const u8,
    file_path: []const u8,
};

/// Result of running a single test.
pub const TestResult = struct {
    passed: bool,
    message: []const u8,
};

/// Discover test functions in a .run source file.
/// Tests are functions whose names start with "test_".
/// Supports both `fn test_*()` and `pub fn test_*()` declarations.
pub fn discoverTests(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    filter: ?[]const u8,
) !std.ArrayList(TestCase) {
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(allocator);
    defer tokens.deinit(allocator);

    var parser = Parser.init(allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();

    var tests: std.ArrayList(TestCase) = .empty;

    if (parser.tree.errors.items.len > 0) {
        return tests;
    }

    const tree = &parser.tree;
    const root = tree.nodes.items[0];
    const start = root.data.lhs;
    const count = root.data.rhs;
    const decl_indices = tree.extra_data.items[start .. start + count];

    for (decl_indices) |decl_idx| {
        const decl = tree.nodes.items[decl_idx];
        const fn_node = switch (decl.tag) {
            .fn_decl => decl,
            .pub_decl => blk: {
                const inner_idx = decl.data.lhs;
                if (inner_idx == null_node) continue;
                const inner = tree.nodes.items[inner_idx];
                if (inner.tag != .fn_decl) continue;
                break :blk inner;
            },
            .inline_decl => blk: {
                var inner_idx = decl.data.lhs;
                if (inner_idx == null_node) continue;
                var inner = tree.nodes.items[inner_idx];
                if (inner.tag == .pub_decl) {
                    inner_idx = inner.data.lhs;
                    if (inner_idx == null_node) continue;
                    inner = tree.nodes.items[inner_idx];
                }
                if (inner.tag != .fn_decl) continue;
                break :blk inner;
            },
            else => continue,
        };

        // Get function name from token after fn keyword
        const fn_tok = fn_node.main_token;
        if (fn_tok + 1 >= tokens.items.len) continue;
        if (tokens.items[fn_tok + 1].tag != .identifier) continue;

        const fn_name = tokens.items[fn_tok + 1].slice(source);

        if (!std.mem.startsWith(u8, fn_name, "test_")) continue;

        // Apply filter if provided
        if (filter) |f| {
            if (std.mem.indexOf(u8, fn_name, f) == null) continue;
        }

        try tests.append(allocator, .{
            .name = fn_name,
            .file_path = file_path,
        });
    }

    return tests;
}

/// Validate a single discovered test by checking that its containing file
/// passes the semantic analysis pipeline.
/// Test body execution is not implemented yet, so this is compile-only
/// validation rather than a real test harness.
pub fn runSingleTest(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    test_name: []const u8,
) TestResult {
    _ = test_name;

    // Try to compile the file through the check pipeline
    const driver = @import("driver.zig");
    driver.compile(allocator, .{
        .input_path = file_path,
        .command = .check,
        .no_color = true,
    }) catch |err| {
        return .{
            .passed = false,
            .message = switch (err) {
                error.ParseFailed => "parse error",
                error.NamingFailed => "naming error",
                error.ConventionFailed => "convention error",
                else => "compilation error",
            },
        };
    };

    return .{
        .passed = true,
        .message = "",
    };
}

// Tests

test "discoverTests: finds test_ functions" {
    const source = "package main\nfun test_add() {\n}\nfun helper() {\n}";
    var tests = try discoverTests(std.testing.allocator, source, "test.run", null);
    defer tests.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tests.items.len);
    try std.testing.expectEqualStrings("test_add", tests.items[0].name);
}

test "discoverTests: finds pub test_ functions" {
    const source = "package main\npub fun test_sub() {\n}\npub fun main() {\n}";
    var tests = try discoverTests(std.testing.allocator, source, "test.run", null);
    defer tests.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tests.items.len);
    try std.testing.expectEqualStrings("test_sub", tests.items[0].name);
}

test "discoverTests: filter by pattern" {
    const source = "package main\nfun test_add() {\n}\nfun test_sub() {\n}";
    var tests = try discoverTests(std.testing.allocator, source, "test.run", "add");
    defer tests.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), tests.items.len);
    try std.testing.expectEqualStrings("test_add", tests.items[0].name);
}

test "discoverTests: no tests found" {
    const source = "package main\nfun add() {\n}\nfun sub() {\n}";
    var tests = try discoverTests(std.testing.allocator, source, "test.run", null);
    defer tests.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tests.items.len);
}

test "discoverTests: multiple tests" {
    const source = "package main\nfun test_a() {\n}\nfun test_b() {\n}\nfun test_c() {\n}";
    var tests = try discoverTests(std.testing.allocator, source, "test.run", null);
    defer tests.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), tests.items.len);
}
