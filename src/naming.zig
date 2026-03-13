const std = @import("std");
const Ast = @import("ast.zig").Ast;
const Token = @import("token.zig").Token;

pub const ViolationTag = enum {
    type_must_be_upper_camel,
    variable_must_be_lower_camel,
    file_must_be_lower_snake,
};

pub const Violation = struct {
    tag: ViolationTag,
    loc: Token.Loc,
    name: []const u8,
};

pub fn checkNaming(
    allocator: std.mem.Allocator,
    path: []const u8,
    tree: *const Ast,
    tokens: []const Token,
) !std.ArrayList(Violation) {
    var violations: std.ArrayList(Violation) = .empty;

    try checkFileName(allocator, path, &violations);

    for (tree.nodes.items) |node| {
        switch (node.tag) {
            .struct_decl, .interface_decl => {
                try checkTypeToken(tree, tokens, node.main_token, &violations);
            },
            .type_decl, .type_alias => {
                try checkTypeToken(tree, tokens, node.main_token + 1, &violations);
            },
            .var_decl, .let_decl => {
                try checkVariableToken(tree, tokens, node.main_token + 1, &violations);
            },
            .param, .variadic_param, .receiver, .field_decl => {
                try checkVariableToken(tree, tokens, node.main_token, &violations);
            },
            .short_var_decl => {
                const lhs_index: usize = @intCast(node.data.lhs);
                if (node.data.lhs != 0 and lhs_index < tree.nodes.items.len) {
                    const lhs = tree.nodes.items[lhs_index];
                    if (lhs.tag == .ident) {
                        try checkVariableToken(tree, tokens, lhs.main_token, &violations);
                    }
                }
            },
            else => {},
        }
    }

    return violations;
}

fn checkFileName(
    allocator: std.mem.Allocator,
    path: []const u8,
    violations: *std.ArrayList(Violation),
) !void {
    const file_name = std.fs.path.basename(path);
    const stem = std.fs.path.stem(file_name);
    if (!isLowerSnake(stem)) {
        try violations.append(allocator, .{
            .tag = .file_must_be_lower_snake,
            .loc = .{ .start = 0, .end = 0 },
            .name = stem,
        });
    }
}

fn checkTypeToken(
    tree: *const Ast,
    tokens: []const Token,
    token_index: u32,
    violations: *std.ArrayList(Violation),
) !void {
    const idx: usize = @intCast(token_index);
    if (idx >= tokens.len) return;
    const tok = tokens[idx];
    if (tok.tag != .identifier) return;
    const name = tok.slice(tree.source);
    if (!isUpperCamel(name)) {
        try violations.append(tree.allocator, .{
            .tag = .type_must_be_upper_camel,
            .loc = tok.loc,
            .name = name,
        });
    }
}

fn checkVariableToken(
    tree: *const Ast,
    tokens: []const Token,
    token_index: u32,
    violations: *std.ArrayList(Violation),
) !void {
    const idx: usize = @intCast(token_index);
    if (idx >= tokens.len) return;
    const tok = tokens[idx];
    if (tok.tag != .identifier) return;
    const name = tok.slice(tree.source);
    if (!isLowerCamel(name)) {
        try violations.append(tree.allocator, .{
            .tag = .variable_must_be_lower_camel,
            .loc = tok.loc,
            .name = name,
        });
    }
}

fn isUpperCamel(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isUpper(name[0])) return false;
    for (name[1..]) |ch| {
        if (ch == '_') return false;
        if (!std.ascii.isAlphanumeric(ch)) return false;
    }
    return true;
}

fn isLowerCamel(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isLower(name[0])) return false;
    for (name[1..]) |ch| {
        if (ch == '_') return false;
        if (!std.ascii.isAlphanumeric(ch)) return false;
    }
    return true;
}

fn isLowerSnake(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isLower(name[0])) return false;
    for (name) |ch| {
        if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    }
    return true;
}

test "naming helpers" {
    try std.testing.expect(isUpperCamel("MyType"));
    try std.testing.expect(!isUpperCamel("myType"));
    try std.testing.expect(!isUpperCamel("My_Type"));

    try std.testing.expect(isLowerCamel("myVar1"));
    try std.testing.expect(!isLowerCamel("MyVar"));
    try std.testing.expect(!isLowerCamel("my_var"));

    try std.testing.expect(isLowerSnake("my_file_name"));
    try std.testing.expect(!isLowerSnake("My_file"));
    try std.testing.expect(!isLowerSnake("myFile"));
}
