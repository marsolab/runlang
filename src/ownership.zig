const std = @import("std");
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const null_node = ast_mod.null_node;
const Token = @import("token.zig").Token;
const types = @import("types.zig");
const TypeId = types.TypeId;
const symbol_mod = @import("symbol.zig");
const SymbolTable = symbol_mod.SymbolTable;
const SymbolId = symbol_mod.SymbolId;
const resolve = @import("resolve.zig");
const DiagnosticList = @import("diagnostics.zig").DiagnosticList;

/// Result of ownership analysis.
pub const OwnershipResult = struct {
    diagnostics: DiagnosticList,

    pub fn deinit(self: *OwnershipResult) void {
        self.diagnostics.deinit();
    }
};

/// Run ownership and memory safety analysis on a resolved + type-checked AST.
pub fn analyzeOwnership(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    tokens: []const Token,
    resolve_result: *resolve.ResolveResult,
) !OwnershipResult {
    var analyzer = OwnershipAnalyzer.init(allocator, tree, tokens, resolve_result);
    return analyzer.analyze();
}

const OwnershipAnalyzer = struct {
    tree: *const Ast,
    tokens: []const Token,
    source: []const u8,
    symbols: *SymbolTable,
    resolution_map: []const ?SymbolId,
    diagnostics: DiagnosticList,
    allocator: std.mem.Allocator,

    /// Tracks which declaration nodes have been moved.
    moved_set: std.ArrayList(NodeIndex),
    /// Tracks which declaration nodes hold owned allocations.
    owned_set: std.ArrayList(NodeIndex),
    /// Scope stack for owned_set (stores boundary indices).
    scope_stack: std.ArrayList(usize),

    const AnalysisError = error{OutOfMemory};

    fn init(
        allocator: std.mem.Allocator,
        tree: *const Ast,
        tokens: []const Token,
        resolve_result: *resolve.ResolveResult,
    ) OwnershipAnalyzer {
        return .{
            .tree = tree,
            .tokens = tokens,
            .source = tree.source,
            .symbols = &resolve_result.symbols,
            .resolution_map = resolve_result.resolution_map.items,
            .diagnostics = DiagnosticList.init(allocator),
            .allocator = allocator,
            .moved_set = .empty,
            .owned_set = .empty,
            .scope_stack = .empty,
        };
    }

    fn analyze(self: *OwnershipAnalyzer) !OwnershipResult {
        const root = self.tree.nodes.items[0];
        const start = root.data.lhs;
        const count = root.data.rhs;
        const decl_indices = self.tree.extra_data.items[start .. start + count];

        for (decl_indices) |decl_idx| {
            try self.analyzeTopLevel(decl_idx);
        }

        self.moved_set.deinit(self.allocator);
        self.owned_set.deinit(self.allocator);
        self.scope_stack.deinit(self.allocator);

        return .{
            .diagnostics = self.diagnostics,
        };
    }

    fn analyzeTopLevel(self: *OwnershipAnalyzer, node_idx: NodeIndex) AnalysisError!void {
        if (node_idx == null_node) return;
        const node = self.tree.nodes.items[node_idx];
        switch (node.tag) {
            .pub_decl => try self.analyzeTopLevel(node.data.lhs),
            .fn_decl => try self.analyzeFnDecl(node_idx),
            else => {},
        }
    }

    fn analyzeFnDecl(self: *OwnershipAnalyzer, node_idx: NodeIndex) AnalysisError!void {
        const node = self.tree.nodes.items[node_idx];
        const body = node.data.rhs;
        if (body == null_node) return;

        try self.pushScope();
        try self.analyzeBlock(body);
        try self.popScope();
    }

    fn pushScope(self: *OwnershipAnalyzer) AnalysisError!void {
        try self.scope_stack.append(self.allocator, self.owned_set.items.len);
    }

    fn popScope(self: *OwnershipAnalyzer) AnalysisError!void {
        if (self.scope_stack.items.len > 0) {
            const boundary = self.scope_stack.pop().?;
            // Check for owned resources that were neither freed nor moved.
            // (This is informational — deterministic destruction handles cleanup)
            self.owned_set.shrinkRetainingCapacity(boundary);
        }
    }

    fn analyzeBlock(self: *OwnershipAnalyzer, node_idx: NodeIndex) AnalysisError!void {
        if (node_idx == null_node) return;
        const node = self.tree.nodes.items[node_idx];
        if (node.tag != .block) return;

        const start = node.data.lhs;
        const count = node.data.rhs;
        const stmts = self.tree.extra_data.items[start .. start + count];

        for (stmts) |stmt_idx| {
            try self.analyzeStmt(stmt_idx);
        }
    }

    fn analyzeStmt(self: *OwnershipAnalyzer, node_idx: NodeIndex) AnalysisError!void {
        if (node_idx == null_node) return;
        const node = self.tree.nodes.items[node_idx];
        switch (node.tag) {
            .var_decl, .let_decl => try self.analyzeVarDecl(node_idx),
            .short_var_decl => try self.analyzeShortVarDecl(node_idx),
            .assign => try self.analyzeAssign(node_idx),
            .block => {
                try self.pushScope();
                try self.analyzeBlock(node_idx);
                try self.popScope();
            },
            .if_stmt => try self.analyzeIfStmt(node_idx),
            .for_stmt => try self.analyzeForStmt(node_idx),
            .return_stmt => try self.analyzeReturn(node_idx),
            .expr_stmt => try self.analyzeExpr(node.data.lhs),
            .defer_stmt => {},
            else => {},
        }
    }

    fn analyzeVarDecl(self: *OwnershipAnalyzer, node_idx: NodeIndex) AnalysisError!void {
        const node = self.tree.nodes.items[node_idx];
        const init_node = node.data.rhs;

        if (init_node != null_node) {
            try self.analyzeExpr(init_node);

            // Track ownership for alloc expressions.
            if (self.tree.nodes.items[init_node].tag == .alloc_expr) {
                try self.owned_set.append(self.allocator, node_idx);
            }
        }
    }

    fn analyzeShortVarDecl(self: *OwnershipAnalyzer, node_idx: NodeIndex) AnalysisError!void {
        const node = self.tree.nodes.items[node_idx];
        const init_node = node.data.rhs;

        if (init_node != null_node) {
            try self.analyzeExpr(init_node);

            if (self.tree.nodes.items[init_node].tag == .alloc_expr) {
                try self.owned_set.append(self.allocator, node_idx);
            }
        }
    }

    fn analyzeAssign(self: *OwnershipAnalyzer, node_idx: NodeIndex) AnalysisError!void {
        const node = self.tree.nodes.items[node_idx];
        try self.analyzeExpr(node.data.rhs);

        // Check for use-after-move on the RHS.
        if (node.data.rhs != null_node and self.tree.nodes.items[node.data.rhs].tag == .ident) {
            try self.checkUseAfterMove(node.data.rhs);
        }

        // Track move: if RHS is an owned ident, mark it moved.
        if (node.data.rhs != null_node) {
            const rhs = self.tree.nodes.items[node.data.rhs];
            if (rhs.tag == .ident) {
                if (node.data.rhs < self.resolution_map.len) {
                    if (self.resolution_map[node.data.rhs]) |sym_id| {
                        const sym = self.symbols.getSymbol(sym_id);
                        if (sym.kind == .variable and self.isOwned(sym.decl_node)) {
                            try self.moved_set.append(self.allocator, sym.decl_node);
                        }
                    }
                }
            }
        }
    }

    fn analyzeReturn(self: *OwnershipAnalyzer, node_idx: NodeIndex) AnalysisError!void {
        const node = self.tree.nodes.items[node_idx];
        if (node.data.lhs != null_node) {
            try self.analyzeExpr(node.data.lhs);
        }
    }

    fn analyzeIfStmt(self: *OwnershipAnalyzer, node_idx: NodeIndex) AnalysisError!void {
        const node = self.tree.nodes.items[node_idx];
        const extra = self.tree.extra_data.items;
        try self.analyzeExpr(node.data.lhs);

        const then_block = extra[node.data.rhs];
        const else_node = extra[node.data.rhs + 1];

        try self.pushScope();
        try self.analyzeBlock(then_block);
        try self.popScope();

        if (else_node != null_node) {
            try self.pushScope();
            if (self.tree.nodes.items[else_node].tag == .if_stmt) {
                try self.analyzeIfStmt(else_node);
            } else {
                try self.analyzeBlock(else_node);
            }
            try self.popScope();
        }
    }

    fn analyzeForStmt(self: *OwnershipAnalyzer, node_idx: NodeIndex) AnalysisError!void {
        const node = self.tree.nodes.items[node_idx];
        if (node.data.lhs != null_node) try self.analyzeExpr(node.data.lhs);
        if (node.data.rhs != null_node) {
            try self.pushScope();
            try self.analyzeBlock(node.data.rhs);
            try self.popScope();
        }
    }

    fn analyzeExpr(self: *OwnershipAnalyzer, node_idx: NodeIndex) AnalysisError!void {
        if (node_idx == null_node) return;
        const node = self.tree.nodes.items[node_idx];
        switch (node.tag) {
            .ident => try self.checkUseAfterMove(node_idx),
            .binary_op => {
                try self.analyzeExpr(node.data.lhs);
                try self.analyzeExpr(node.data.rhs);
            },
            .unary_op => try self.analyzeExpr(node.data.lhs),
            .call => {
                try self.analyzeExpr(node.data.lhs);
                const args_start = node.data.rhs;
                const extra = self.tree.extra_data.items;
                var n: u32 = 0;
                while (args_start + n < extra.len) {
                    if (extra[args_start + n] == n) break;
                    n += 1;
                }
                const arg_nodes = extra[args_start .. args_start + n];
                for (arg_nodes) |arg| {
                    try self.analyzeExpr(arg);
                }
            },
            .field_access => try self.analyzeExpr(node.data.lhs),
            .index_access => {
                try self.analyzeExpr(node.data.lhs);
                try self.analyzeExpr(node.data.rhs);
            },
            .addr_of, .addr_of_const => try self.analyzeExpr(node.data.lhs),
            .deref => try self.analyzeExpr(node.data.lhs),
            .try_expr => try self.analyzeExpr(node.data.lhs),
            else => {},
        }
    }

    fn checkUseAfterMove(self: *OwnershipAnalyzer, node_idx: NodeIndex) AnalysisError!void {
        if (node_idx >= self.resolution_map.len) return;
        if (self.resolution_map[node_idx]) |sym_id| {
            const sym = self.symbols.getSymbol(sym_id);
            if (sym.kind == .variable and self.isOwned(sym.decl_node)) {
                if (self.isMoved(sym.decl_node)) {
                    const loc = self.tokenLoc(self.tree.nodes.items[node_idx].main_token);
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "use of moved value '{s}'",
                        .{sym.name},
                    );
                }
            }
        }
    }

    fn isOwned(self: *const OwnershipAnalyzer, decl_node: NodeIndex) bool {
        for (self.owned_set.items) |owned| {
            if (owned == decl_node) return true;
        }
        return false;
    }

    fn isMoved(self: *const OwnershipAnalyzer, decl_node: NodeIndex) bool {
        for (self.moved_set.items) |moved| {
            if (moved == decl_node) return true;
        }
        return false;
    }

    fn tokenSlice(self: *const OwnershipAnalyzer, tok_index: u32) []const u8 {
        const tok = self.tokens[tok_index];
        return self.source[tok.loc.start..tok.loc.end];
    }

    fn tokenLoc(self: *const OwnershipAnalyzer, tok_index: u32) Token.Loc {
        return self.tokens[tok_index].loc;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────────

const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;

fn testOwnership(source: []const u8) !struct { has_errors: bool, error_count: usize } {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(source);
    var token_list = try lexer.tokenize(allocator);
    defer token_list.deinit(allocator);

    var parser = Parser.init(allocator, token_list.items, source);
    defer parser.deinit();
    _ = try parser.parseFile();

    var res = try resolve.resolveNames(allocator, &parser.tree, token_list.items);
    defer res.deinit(allocator);

    var result = try analyzeOwnership(allocator, &parser.tree, token_list.items, &res);
    defer result.deinit();

    return .{
        .has_errors = result.diagnostics.hasErrors(),
        .error_count = result.diagnostics.diagnostics.items.len,
    };
}

fn testOwnershipHasErrorContaining(source: []const u8, needle: []const u8) !bool {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(source);
    var token_list = try lexer.tokenize(allocator);
    defer token_list.deinit(allocator);

    var parser = Parser.init(allocator, token_list.items, source);
    defer parser.deinit();
    _ = try parser.parseFile();

    var res = try resolve.resolveNames(allocator, &parser.tree, token_list.items);
    defer res.deinit(allocator);

    var result = try analyzeOwnership(allocator, &parser.tree, token_list.items, &res);
    defer result.deinit();

    for (result.diagnostics.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

test "ownership: no error for simple function" {
    const result = try testOwnership("fn main() {\n}\n");
    try std.testing.expect(!result.has_errors);
}

test "ownership: no error for alloc without move" {
    const result = try testOwnership(
        \\fn main() {
        \\    let s = alloc([]int, 8)
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "ownership: use-after-move detected" {
    const has_err = try testOwnershipHasErrorContaining(
        \\fn main() {
        \\    var s = alloc([]int, 8)
        \\    var t = 0
        \\    t = s
        \\    var u = s
        \\}
        \\
    , "use of moved value");
    try std.testing.expect(has_err);
}

test "ownership: no error without move" {
    const result = try testOwnership(
        \\fn main() {
        \\    var s = alloc([]int, 8)
        \\    var t = alloc([]int, 4)
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "ownership: nested scope ownership" {
    const result = try testOwnership(
        \\fn main() {
        \\    var outer = alloc([]int, 8)
        \\    {
        \\        var inner = alloc([]int, 4)
        \\    }
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}
