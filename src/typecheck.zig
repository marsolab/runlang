const std = @import("std");
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const null_node = ast_mod.null_node;
const Token = @import("token.zig").Token;
const types = @import("types.zig");
const TypeId = types.TypeId;
const TypePool = types.TypePool;
const symbol_mod = @import("symbol.zig");
const Symbol = symbol_mod.Symbol;
const SymbolId = symbol_mod.SymbolId;
const SymbolTable = symbol_mod.SymbolTable;
const DiagnosticList = @import("diagnostics.zig").DiagnosticList;
const resolve = @import("resolve.zig");

pub const TypeCheckResult = struct {
    diagnostics: DiagnosticList,
    type_map: std.ArrayList(TypeId),
    type_pool: TypePool,

    pub fn deinit(self: *TypeCheckResult, allocator: std.mem.Allocator) void {
        self.diagnostics.deinit();
        self.type_map.deinit(allocator);
        self.type_pool.deinit(allocator);
    }
};

/// Run type checking on a resolved AST.
pub fn typeCheck(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    tokens: []const Token,
    resolve_result: *resolve.ResolveResult,
) !TypeCheckResult {
    var checker = TypeChecker.init(allocator, tree, tokens, resolve_result);
    return checker.check();
}

const TypeChecker = struct {
    tree: *const Ast,
    tokens: []const Token,
    source: []const u8,
    symbols: *SymbolTable,
    resolution_map: []const ?SymbolId,
    type_pool: TypePool,
    type_map: std.ArrayList(TypeId),
    diagnostics: DiagnosticList,
    allocator: std.mem.Allocator,

    const CheckError = error{OutOfMemory};

    fn init(
        allocator: std.mem.Allocator,
        tree: *const Ast,
        tokens: []const Token,
        resolve_result: *resolve.ResolveResult,
    ) TypeChecker {
        var type_map: std.ArrayList(TypeId) = .empty;
        type_map.appendNTimes(allocator, types.null_type, tree.nodes.items.len) catch {};
        return .{
            .tree = tree,
            .tokens = tokens,
            .source = tree.source,
            .symbols = &resolve_result.symbols,
            .resolution_map = resolve_result.resolution_map.items,
            .type_pool = TypePool.init(allocator),
            .type_map = type_map,
            .diagnostics = DiagnosticList.init(allocator),
            .allocator = allocator,
        };
    }

    fn check(self: *TypeChecker) !TypeCheckResult {
        try self.checkTopLevel();
        return .{
            .diagnostics = self.diagnostics,
            .type_map = self.type_map,
            .type_pool = self.type_pool,
        };
    }

    // ── Top-level walking ────────────────────────────────────────────────────

    fn checkTopLevel(self: *TypeChecker) CheckError!void {
        const root = self.tree.nodes.items[0];
        const start = root.data.lhs;
        const count = root.data.rhs;
        const decl_indices = self.tree.extra_data.items[start .. start + count];

        for (decl_indices) |decl_idx| {
            var node = decl_idx;
            if (self.nodeTag(node) == .pub_decl) {
                node = self.nodeData(node).lhs;
            }
            switch (self.nodeTag(node)) {
                .fn_decl => try self.checkFnDecl(node),
                .var_decl => try self.checkVarDecl(node),
                .let_decl => try self.checkVarDecl(node),
                else => {},
            }
        }
    }

    fn checkFnDecl(self: *TypeChecker, node: NodeIndex) CheckError!void {
        const data = self.nodeData(node);
        const body = data.rhs;
        if (body == null_node) return;

        // Type-check the body block.
        try self.checkBlock(body);
    }

    fn checkBlock(self: *TypeChecker, node: NodeIndex) CheckError!void {
        if (node == null_node) return;
        const data = self.nodeData(node);
        const start = data.lhs;
        const count = data.rhs;
        const stmt_indices = self.tree.extra_data.items[start .. start + count];
        for (stmt_indices) |stmt_idx| {
            try self.checkNode(stmt_idx);
        }
    }

    // ── Node dispatch ────────────────────────────────────────────────────────

    fn checkNode(self: *TypeChecker, node: NodeIndex) CheckError!void {
        if (node == null_node) return;
        const tag = self.nodeTag(node);
        switch (tag) {
            .var_decl, .let_decl => try self.checkVarDecl(node),
            .short_var_decl => try self.checkShortVarDecl(node),
            .assign => try self.checkAssign(node),
            .return_stmt => {
                const data = self.nodeData(node);
                if (data.lhs != null_node) {
                    _ = try self.inferExpr(data.lhs);
                }
            },
            .expr_stmt => {
                _ = try self.inferExpr(self.nodeData(node).lhs);
            },
            .defer_stmt => {
                _ = try self.inferExpr(self.nodeData(node).lhs);
            },
            .run_stmt => {
                _ = try self.inferExpr(self.nodeData(node).lhs);
            },
            .block => try self.checkBlock(node),
            .if_stmt => try self.checkIfStmt(node),
            .if_expr => {
                _ = try self.inferIfExpr(node);
            },
            .for_stmt => try self.checkForStmt(node),
            .switch_stmt => try self.checkSwitchStmt(node),
            .chan_send => {
                _ = try self.inferExpr(self.nodeData(node).lhs);
                _ = try self.inferExpr(self.nodeData(node).rhs);
            },
            // Expressions that can appear as statements
            .call, .binary_op, .unary_op, .ident, .field_access,
            .index_access, .try_expr, .chan_recv,
            => {
                _ = try self.inferExpr(node);
            },
            // Literals as statements (rare but valid)
            .int_literal, .float_literal, .string_literal, .bool_literal, .null_literal => {
                _ = try self.inferExpr(node);
            },
            else => {},
        }
    }

    // ── Variable declarations ────────────────────────────────────────────────

    fn checkVarDecl(self: *TypeChecker, node: NodeIndex) CheckError!void {
        const data = self.nodeData(node);
        const main_tok = self.nodeMainToken(node);
        const type_node = data.lhs;
        const init_node = data.rhs;

        var declared_type: TypeId = types.null_type;
        var init_type: TypeId = types.null_type;

        // Resolve declared type annotation.
        if (type_node != null_node) {
            declared_type = self.resolveTypeNode(type_node);
        }

        // Infer initializer type.
        if (init_node != null_node) {
            init_type = try self.inferExpr(init_node);
        }

        // If both declared and init present, check compatibility.
        if (type_node != null_node and init_node != null_node) {
            if (declared_type != types.null_type and init_type != types.null_type) {
                if (!self.typesCompatible(declared_type, init_type)) {
                    const loc = self.tokenLoc(main_tok);
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "type mismatch: expected '{s}', got '{s}'",
                        .{ self.typeName(declared_type), self.typeName(init_type) },
                    );
                }
            }
        }

        // Determine the symbol's type: declared type takes precedence, else inferred.
        const final_type = if (declared_type != types.null_type) declared_type else init_type;

        // Update symbol type_id via resolution_map.
        if (self.resolution_map[node]) |sym_id| {
            self.symbols.getSymbolPtr(sym_id).type_id = final_type;
        }

        self.type_map.items[node] = final_type;
    }

    fn checkShortVarDecl(self: *TypeChecker, node: NodeIndex) CheckError!void {
        const data = self.nodeData(node);
        const init_node = data.rhs;

        var init_type: TypeId = types.null_type;
        if (init_node != null_node) {
            init_type = try self.inferExpr(init_node);
        }

        // Update symbol type_id.
        if (self.resolution_map[node]) |sym_id| {
            self.symbols.getSymbolPtr(sym_id).type_id = init_type;
        }

        self.type_map.items[node] = init_type;
    }

    fn checkAssign(self: *TypeChecker, node: NodeIndex) CheckError!void {
        const data = self.nodeData(node);
        const lhs_type = try self.inferExpr(data.lhs);
        const rhs_type = try self.inferExpr(data.rhs);

        if (lhs_type != types.null_type and rhs_type != types.null_type) {
            if (!self.typesCompatible(lhs_type, rhs_type)) {
                const loc = self.tokenLoc(self.nodeMainToken(node));
                try self.diagnostics.addErrorFmt(
                    loc.start,
                    loc.end,
                    "type mismatch in assignment: expected '{s}', got '{s}'",
                    .{ self.typeName(lhs_type), self.typeName(rhs_type) },
                );
            }
        }
    }

    // ── Control flow ─────────────────────────────────────────────────────────

    fn checkIfStmt(self: *TypeChecker, node: NodeIndex) CheckError!void {
        const data = self.nodeData(node);
        const extra = self.tree.extra_data.items;
        _ = try self.inferExpr(data.lhs); // condition

        const then_block = extra[data.rhs];
        const else_node = extra[data.rhs + 1];

        try self.checkBlock(then_block);
        if (else_node != null_node) {
            if (self.nodeTag(else_node) == .if_stmt) {
                try self.checkIfStmt(else_node);
            } else {
                try self.checkBlock(else_node);
            }
        }
    }

    fn inferIfExpr(self: *TypeChecker, node: NodeIndex) CheckError!TypeId {
        const data = self.nodeData(node);
        const extra = self.tree.extra_data.items;
        _ = try self.inferExpr(data.lhs); // condition
        const then_type = try self.inferExpr(extra[data.rhs]);
        _ = try self.inferExpr(extra[data.rhs + 1]);
        self.type_map.items[node] = then_type;
        return then_type;
    }

    fn checkForStmt(self: *TypeChecker, node: NodeIndex) CheckError!void {
        const data = self.nodeData(node);
        if (data.lhs != null_node) {
            _ = try self.inferExpr(data.lhs);
        }
        if (data.rhs != null_node) {
            try self.checkBlock(data.rhs);
        }
    }

    fn checkSwitchStmt(self: *TypeChecker, node: NodeIndex) CheckError!void {
        const data = self.nodeData(node);
        _ = try self.inferExpr(data.lhs);

        const arms_start = data.rhs;
        const extra = self.tree.extra_data.items;
        const arm_count = self.findTrailingCount(arms_start, extra);
        const arm_nodes = extra[arms_start .. arms_start + arm_count];
        for (arm_nodes) |arm| {
            if (arm == null_node) continue;
            const arm_data = self.nodeData(arm);
            if (arm_data.lhs != null_node) _ = try self.inferExpr(arm_data.lhs);
            if (arm_data.rhs != null_node) {
                if (self.nodeTag(arm_data.rhs) == .block) {
                    try self.checkBlock(arm_data.rhs);
                } else {
                    _ = try self.inferExpr(arm_data.rhs);
                }
            }
        }
    }

    // ── Expression type inference ────────────────────────────────────────────

    fn inferExpr(self: *TypeChecker, node: NodeIndex) CheckError!TypeId {
        if (node == null_node) return types.null_type;

        const tag = self.nodeTag(node);
        const result: TypeId = switch (tag) {
            .int_literal => types.primitives.int_id,
            .float_literal => types.primitives.f64_id,
            .string_literal => types.primitives.string_id,
            .bool_literal => types.primitives.bool_id,
            .null_literal => types.null_type,

            .ident => self.inferIdent(node),

            .binary_op => try self.inferBinaryOp(node),
            .unary_op => try self.inferUnaryOp(node),

            .call => blk: {
                // Infer callee and args, but we can't determine return type yet.
                const data = self.nodeData(node);
                _ = try self.inferExpr(data.lhs);
                const args_start = data.rhs;
                const extra = self.tree.extra_data.items;
                const arg_count = self.findTrailingCount(args_start, extra);
                const arg_nodes = extra[args_start .. args_start + arg_count];
                for (arg_nodes) |arg| {
                    _ = try self.inferExpr(arg);
                }
                break :blk types.null_type;
            },

            .field_access => blk: {
                _ = try self.inferExpr(self.nodeData(node).lhs);
                break :blk types.null_type;
            },

            .index_access => blk: {
                _ = try self.inferExpr(self.nodeData(node).lhs);
                _ = try self.inferExpr(self.nodeData(node).rhs);
                break :blk types.null_type;
            },

            .addr_of, .addr_of_const, .deref, .chan_recv => blk: {
                _ = try self.inferExpr(self.nodeData(node).lhs);
                break :blk types.null_type;
            },

            .try_expr => blk: {
                _ = try self.inferExpr(self.nodeData(node).lhs);
                break :blk types.null_type;
            },

            .range => blk: {
                _ = try self.inferExpr(self.nodeData(node).lhs);
                _ = try self.inferExpr(self.nodeData(node).rhs);
                break :blk types.null_type;
            },

            .if_expr => try self.inferIfExpr(node),

            .struct_literal, .anon_struct_literal => blk: {
                const data = self.nodeData(node);
                if (data.lhs != null_node) _ = try self.inferExpr(data.lhs);
                const fields_start = data.rhs;
                const extra = self.tree.extra_data.items;
                const field_count = self.findTrailingCount(fields_start, extra);
                const field_nodes = extra[fields_start .. fields_start + field_count];
                for (field_nodes) |field| {
                    if (field != null_node) _ = try self.inferExpr(self.nodeData(field).lhs);
                }
                break :blk types.null_type;
            },

            .closure => blk: {
                const data = self.nodeData(node);
                if (data.rhs != null_node) try self.checkBlock(data.rhs);
                break :blk types.null_type;
            },

            .variant => blk: {
                if (self.nodeData(node).lhs != null_node) {
                    _ = try self.inferExpr(self.nodeData(node).lhs);
                }
                break :blk types.null_type;
            },

            else => types.null_type,
        };

        self.type_map.items[node] = result;
        return result;
    }

    fn inferIdent(self: *TypeChecker, node: NodeIndex) TypeId {
        if (self.resolution_map[node]) |sym_id| {
            return self.symbols.getSymbol(sym_id).type_id;
        }
        return types.null_type;
    }

    fn inferBinaryOp(self: *TypeChecker, node: NodeIndex) CheckError!TypeId {
        const data = self.nodeData(node);
        const op_tok = self.nodeMainToken(node);
        const op = self.tokens[op_tok].tag;

        const lhs_type = try self.inferExpr(data.lhs);
        const rhs_type = try self.inferExpr(data.rhs);

        // Skip checking if either side is unknown.
        if (lhs_type == types.null_type or rhs_type == types.null_type) {
            return types.null_type;
        }

        switch (op) {
            // Arithmetic operators
            .plus, .minus, .star, .slash, .percent => {
                if (!self.type_pool.isNumeric(lhs_type)) {
                    const loc = self.tokenLoc(op_tok);
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "operator '{s}' requires numeric operands, got '{s}'",
                        .{ self.tokenSlice(op_tok), self.typeName(lhs_type) },
                    );
                    return types.null_type;
                }
                if (!self.type_pool.isNumeric(rhs_type)) {
                    const loc = self.tokenLoc(op_tok);
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "operator '{s}' requires numeric operands, got '{s}'",
                        .{ self.tokenSlice(op_tok), self.typeName(rhs_type) },
                    );
                    return types.null_type;
                }
                // If one is float and the other is int, result is float.
                if (self.type_pool.isFloat(lhs_type) or self.type_pool.isFloat(rhs_type)) {
                    return if (self.type_pool.isFloat(lhs_type)) lhs_type else rhs_type;
                }
                return lhs_type;
            },

            // Comparison operators
            .equal_equal, .bang_equal, .less, .greater, .less_equal, .greater_equal => {
                // Both operands must be compatible.
                if (!self.typesCompatible(lhs_type, rhs_type)) {
                    const loc = self.tokenLoc(op_tok);
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "cannot compare '{s}' and '{s}'",
                        .{ self.typeName(lhs_type), self.typeName(rhs_type) },
                    );
                }
                return types.primitives.bool_id;
            },

            // Logical operators
            .kw_and, .kw_or => {
                if (!self.type_pool.typeEql(lhs_type, types.primitives.bool_id)) {
                    const loc = self.tokenLoc(op_tok);
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "logical operator requires bool operands, got '{s}'",
                        .{self.typeName(lhs_type)},
                    );
                }
                if (!self.type_pool.typeEql(rhs_type, types.primitives.bool_id)) {
                    const loc = self.tokenLoc(op_tok);
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "logical operator requires bool operands, got '{s}'",
                        .{self.typeName(rhs_type)},
                    );
                }
                return types.primitives.bool_id;
            },

            else => return types.null_type,
        }
    }

    fn inferUnaryOp(self: *TypeChecker, node: NodeIndex) CheckError!TypeId {
        const data = self.nodeData(node);
        const op_tok = self.nodeMainToken(node);
        const op = self.tokens[op_tok].tag;
        const operand_type = try self.inferExpr(data.lhs);

        if (operand_type == types.null_type) return types.null_type;

        switch (op) {
            .minus => {
                if (!self.type_pool.isNumeric(operand_type)) {
                    const loc = self.tokenLoc(op_tok);
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "unary '-' requires numeric operand, got '{s}'",
                        .{self.typeName(operand_type)},
                    );
                    return types.null_type;
                }
                return operand_type;
            },
            .kw_not, .bang => {
                if (!self.type_pool.typeEql(operand_type, types.primitives.bool_id)) {
                    const loc = self.tokenLoc(op_tok);
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "'not' requires bool operand, got '{s}'",
                        .{self.typeName(operand_type)},
                    );
                    return types.null_type;
                }
                return types.primitives.bool_id;
            },
            else => return operand_type,
        }
    }

    // ── Type resolution ──────────────────────────────────────────────────────

    fn resolveTypeNode(self: *TypeChecker, node: NodeIndex) TypeId {
        if (node == null_node) return types.null_type;
        const tag = self.nodeTag(node);
        return switch (tag) {
            .type_name, .ident => {
                const name = self.tokenSlice(self.nodeMainToken(node));
                return TypePool.lookupPrimitive(name) orelse types.null_type;
            },
            else => types.null_type,
        };
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    fn typesCompatible(self: *TypeChecker, a: TypeId, b: TypeId) bool {
        if (a == b) return true;
        // Both numeric types are compatible for comparisons.
        if (self.type_pool.isNumeric(a) and self.type_pool.isNumeric(b)) return true;
        return self.type_pool.typeEql(a, b);
    }

    fn typeName(_: *TypeChecker, type_id: TypeId) []const u8 {
        return switch (type_id) {
            types.primitives.void_id => "void",
            types.primitives.bool_id => "bool",
            types.primitives.int_id => "int",
            types.primitives.uint_id => "uint",
            types.primitives.i32_id => "i32",
            types.primitives.i64_id => "i64",
            types.primitives.u32_id => "u32",
            types.primitives.u64_id => "u64",
            types.primitives.byte_id => "byte",
            types.primitives.f32_id => "f32",
            types.primitives.f64_id => "f64",
            types.primitives.string_id => "string",
            else => "<unknown>",
        };
    }

    fn tokenSlice(self: *const TypeChecker, tok_index: u32) []const u8 {
        const tok = self.tokens[tok_index];
        return self.source[tok.loc.start..tok.loc.end];
    }

    fn tokenLoc(self: *const TypeChecker, tok_index: u32) Token.Loc {
        return self.tokens[tok_index].loc;
    }

    fn nodeMainToken(self: *const TypeChecker, node: NodeIndex) u32 {
        return self.tree.nodes.items[node].main_token;
    }

    fn nodeTag(self: *const TypeChecker, node: NodeIndex) Node.Tag {
        return self.tree.nodes.items[node].tag;
    }

    fn nodeData(self: *const TypeChecker, node: NodeIndex) Node.Data {
        return self.tree.nodes.items[node].data;
    }

    fn findTrailingCount(self: *const TypeChecker, start: u32, extra: []const NodeIndex) u32 {
        _ = self;
        var n: u32 = 0;
        while (start + n < extra.len) {
            if (extra[start + n] == n) {
                return n;
            }
            n += 1;
        }
        return 0;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────────

const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;

fn testTypeCheck(source: []const u8) !struct { has_errors: bool, error_count: usize } {
    const allocator = std.testing.allocator;
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

    return .{
        .has_errors = tc_result.diagnostics.hasErrors(),
        .error_count = tc_result.diagnostics.diagnostics.items.len,
    };
}

test "typecheck: stub passes through" {
    const result = try testTypeCheck("fn main() {\n}\n");
    try std.testing.expect(!result.has_errors);
}

test "typecheck: literal int assignment" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = 42
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: literal string assignment" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var s string = "hello"
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: literal bool assignment" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var b bool = true
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: literal float assignment" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var f f64 = 3.14
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: type mismatch int = string" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = "hello"
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: type mismatch string = int" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    let s string = 42
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: type mismatch bool = int" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var b bool = 42
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: short var decl infers int" {
    // x := 42 infers int, then x = "hello" should fail
    const result = try testTypeCheck(
        \\fn main() {
        \\    x := 42
        \\    x = "hello"
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: short var decl infers string" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    x := "hello"
        \\    x = 42
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: binary op addition valid" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = 1 + 2
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: binary op addition type mismatch" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = 1 + "hello"
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: comparison returns bool" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var b bool = 1 == 2
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: comparison result in int var" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = 1 == 2
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: logical and valid" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var b bool = true and false
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: logical and type mismatch" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var b bool = 1 and 2
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: reassignment valid" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = 1
        \\    x = 2
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: reassignment type mismatch" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = 1
        \\    x = "hello"
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: unary negate valid" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = -42
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: unary not valid" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var b bool = not true
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: unary negate on string" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = -"hello"
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: unary not on int" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var b bool = not 42
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: numeric types are compatible" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = 1
        \\    var y f64 = 3.14
        \\    var z f64 = x + y
        \\}
        \\
    );
    // x is int, y is f64. Arithmetic between numeric types should be fine.
    // z is f64, and int + f64 => f64, so this should pass.
    try std.testing.expect(!result.has_errors);
}

test "typecheck: comparison incompatible types" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var b bool = 1 == "hello"
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: multiple statements" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = 10
        \\    var y int = 20
        \\    var z int = x + y
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: let type mismatch" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    let x int = "hello"
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}
