const std = @import("std");
const Ast = @import("ast.zig").Ast;
const Token = @import("token.zig").Token;
const types = @import("types.zig");
const symbol = @import("symbol.zig");
const diagnostics = @import("diagnostics.zig");
const resolve = @import("resolve.zig");

pub const TypeCheckResult = struct {
    diagnostics: diagnostics.DiagnosticList,

    pub fn deinit(self: *TypeCheckResult, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.diagnostics.deinit();
    }
};

/// Run type checking on a resolved AST.
/// Currently a minimal stub that passes through without checking.
pub fn typeCheck(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    tokens: []const Token,
    resolve_result: *const resolve.ResolveResult,
) !TypeCheckResult {
    _ = tree;
    _ = tokens;
    _ = resolve_result;
    return .{
        .diagnostics = diagnostics.DiagnosticList.init(allocator),
    };
}

test "typecheck: stub passes through" {
    const allocator = std.testing.allocator;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;

    const source = "fn main() {\n}\n";
    var lexer = Lexer.init(source);
    var token_list = try lexer.tokenize(allocator);
    defer token_list.deinit(allocator);

    var parser = Parser.init(allocator, token_list.items, source);
    defer parser.deinit();
    _ = try parser.parseFile();

    var res = try resolve.resolveNames(allocator, &parser.tree, token_list.items);
    defer res.deinit(allocator);

    var tc_result = try typeCheck(allocator, &parser.tree, token_list.items, &res);
    defer tc_result.deinit(allocator);

    try std.testing.expect(!tc_result.diagnostics.hasErrors());
}
