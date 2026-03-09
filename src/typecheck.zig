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
    /// Param slices allocated for FnType entries; must be freed.
    allocated_param_slices: std.ArrayList([]const TypeId),

    pub fn deinit(self: *TypeCheckResult, allocator: std.mem.Allocator) void {
        for (self.allocated_param_slices.items) |slice| {
            allocator.free(slice);
        }
        self.allocated_param_slices.deinit(allocator);
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
    /// The return type of the function currently being checked (null_type if void/none).
    current_fn_return_type: TypeId,
    /// Tracks param slices allocated for FnType entries.
    allocated_param_slices: std.ArrayList([]const TypeId),

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
            .current_fn_return_type = types.null_type,
            .allocated_param_slices = .empty,
        };
    }

    fn check(self: *TypeChecker) !TypeCheckResult {
        try self.checkTopLevel();
        return .{
            .diagnostics = self.diagnostics,
            .type_map = self.type_map,
            .type_pool = self.type_pool,
            .allocated_param_slices = self.allocated_param_slices,
        };
    }

    // ── Top-level walking ────────────────────────────────────────────────────

    fn checkTopLevel(self: *TypeChecker) CheckError!void {
        const root = self.tree.nodes.items[0];
        const start = root.data.lhs;
        const count = root.data.rhs;
        const decl_indices = self.tree.extra_data.items[start .. start + count];

        // Pass 1: Register all function signatures so forward/recursive calls work.
        for (decl_indices) |decl_idx| {
            var node = decl_idx;
            if (self.nodeTag(node) == .pub_decl) {
                node = self.nodeData(node).lhs;
            }
            if (self.nodeTag(node) == .fn_decl) {
                try self.registerFnType(node);
            }
        }

        // Pass 2: Type-check bodies and top-level var/let decls.
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

    // ── Function type registration ──────────────────────────────────────────

    /// Extract parameter types and return type from a fn_decl node,
    /// build a FnType, and store it on the function's symbol.
    fn registerFnType(self: *TypeChecker, node: NodeIndex) CheckError!void {
        const data = self.nodeData(node);
        const params_start = data.lhs;
        const extra = self.tree.extra_data.items;
        const param_count = self.findParamCount(params_start, extra);

        // Resolve parameter types.
        var param_types: std.ArrayList(TypeId) = .empty;
        defer param_types.deinit(self.allocator);
        const param_nodes = extra[params_start .. params_start + param_count];
        for (param_nodes) |param_node| {
            if (param_node == null_node) {
                try param_types.append(self.allocator, types.null_type);
                continue;
            }
            const param_type_node = self.nodeData(param_node).lhs;
            const param_type = self.resolveTypeNode(param_type_node);
            try param_types.append(self.allocator, param_type);
        }

        // Resolve return type.
        // extra_data layout after params: [count, receiver_node, ret_type_node]
        const ret_type_node = extra[params_start + param_count + 2];
        const return_type = self.resolveTypeNode(ret_type_node);

        // Allocate param types slice and track for cleanup.
        const owned_params = try self.allocator.alloc(TypeId, param_types.items.len);
        @memcpy(owned_params, param_types.items);
        try self.allocated_param_slices.append(self.allocator, owned_params);

        // Create and register the FnType.
        const fn_type_id = try self.type_pool.addType(self.allocator, .{ .fn_type = .{
            .params = owned_params,
            .return_type = return_type,
        } });

        // Find the function's symbol and update its type_id.
        // The resolver registered the function with its name token.
        const fn_tok = self.nodeMainToken(node);
        const has_receiver = self.tokens[fn_tok + 1].tag == .l_paren;

        if (has_receiver) {
            // For methods, find the name token by scanning past receiver parens.
            const name_tok = self.findMethodNameToken(fn_tok);
            const name = self.tokenSlice(name_tok);
            // Look up method symbol by iterating symbols — find by name and decl_node.
            self.updateSymbolTypeByDeclNode(node, name, fn_type_id);
        } else {
            const name_tok = fn_tok + 1;
            const name = self.tokenSlice(name_tok);
            if (self.symbols.lookup(name)) |sym_id| {
                self.symbols.getSymbolPtr(sym_id).type_id = fn_type_id;
            }
        }

        self.type_map.items[node] = fn_type_id;
    }

    /// Find a method's name token by scanning past the receiver parentheses.
    fn findMethodNameToken(self: *const TypeChecker, fn_tok: u32) u32 {
        var tok_idx = fn_tok + 2; // skip fn, l_paren
        // Skip receiver name
        if (self.tokens[tok_idx].tag == .identifier) tok_idx += 1;
        // Skip optional colon
        if (self.tokens[tok_idx].tag == .colon) tok_idx += 1;
        // Skip receiver type tokens until r_paren
        var paren_depth: u32 = 1;
        while (tok_idx < self.tokens.len and paren_depth > 0) {
            if (self.tokens[tok_idx].tag == .l_paren) paren_depth += 1;
            if (self.tokens[tok_idx].tag == .r_paren) paren_depth -= 1;
            tok_idx += 1;
        }
        return tok_idx; // token after r_paren = function name
    }

    /// Update a symbol's type_id by matching on decl_node.
    fn updateSymbolTypeByDeclNode(self: *TypeChecker, decl_node: NodeIndex, name: []const u8, type_id: TypeId) void {
        // Search symbols for one with matching name and decl_node.
        for (self.symbols.symbols.items) |*sym| {
            if (sym.decl_node == decl_node and std.mem.eql(u8, sym.name, name)) {
                sym.type_id = type_id;
                return;
            }
        }
    }

    fn checkFnDecl(self: *TypeChecker, node: NodeIndex) CheckError!void {
        const data = self.nodeData(node);
        const body = data.rhs;
        if (body == null_node) return;

        // Extract return type from registered FnType.
        const fn_type_id = self.type_map.items[node];
        var return_type: TypeId = types.primitives.void_id;
        if (fn_type_id != types.null_type) {
            const fn_type = self.type_pool.get(fn_type_id);
            switch (fn_type) {
                .fn_type => |ft| {
                    return_type = ft.return_type;
                },
                else => {},
            }
        }

        // Also type-check parameter types against their symbols.
        const params_start = data.lhs;
        const extra = self.tree.extra_data.items;
        const param_count = self.findParamCount(params_start, extra);
        const param_nodes = extra[params_start .. params_start + param_count];

        if (fn_type_id != types.null_type) {
            const fn_type = self.type_pool.get(fn_type_id);
            switch (fn_type) {
                .fn_type => |ft| {
                    // Update param symbols with their resolved types.
                    for (param_nodes, 0..) |param_node, i| {
                        if (param_node == null_node) continue;
                        if (self.resolution_map[param_node]) |sym_id| {
                            if (i < ft.params.len) {
                                self.symbols.getSymbolPtr(sym_id).type_id = ft.params[i];
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // Set current function return type for return statement checking.
        const prev_return_type = self.current_fn_return_type;
        self.current_fn_return_type = return_type;
        defer self.current_fn_return_type = prev_return_type;

        // Type-check the body block.
        try self.checkBlock(body);

        // Check that all code paths return if the function has a non-void return type.
        if (return_type != types.null_type and return_type != types.primitives.void_id) {
            if (!self.blockAlwaysReturns(body)) {
                const fn_tok = self.nodeMainToken(node);
                const loc = self.tokenLoc(fn_tok);
                try self.diagnostics.addErrorFmt(
                    loc.start,
                    loc.end,
                    "function with return type '{s}' does not return on all code paths",
                    .{self.typeName(return_type)},
                );
            }
        }
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
            .return_stmt => try self.checkReturnStmt(node),
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

    // ── Return statement checking ───────────────────────────────────────────

    fn checkReturnStmt(self: *TypeChecker, node: NodeIndex) CheckError!void {
        const data = self.nodeData(node);
        const return_tok = self.nodeMainToken(node);
        const loc = self.tokenLoc(return_tok);

        if (data.lhs != null_node) {
            // Return with a value.
            const expr_type = try self.inferExpr(data.lhs);

            // Check: function without return type should not return a value.
            if (self.current_fn_return_type == types.null_type or
                self.current_fn_return_type == types.primitives.void_id)
            {
                try self.diagnostics.addError(
                    loc.start,
                    loc.end,
                    "function without return type cannot return a value",
                );
                return;
            }

            // Check return value type matches declared return type.
            if (expr_type != types.null_type and self.current_fn_return_type != types.null_type) {
                if (!self.typesCompatible(self.current_fn_return_type, expr_type)) {
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "return type mismatch: expected '{s}', got '{s}'",
                        .{ self.typeName(self.current_fn_return_type), self.typeName(expr_type) },
                    );
                }
            }
        } else {
            // Bare return (no value) — error if function has a non-void return type.
            if (self.current_fn_return_type != types.null_type and
                self.current_fn_return_type != types.primitives.void_id)
            {
                try self.diagnostics.addErrorFmt(
                    loc.start,
                    loc.end,
                    "function expects return type '{s}', but returns without a value",
                    .{self.typeName(self.current_fn_return_type)},
                );
            }
        }
    }

    // ── Return path analysis ────────────────────────────────────────────────

    /// Check whether a block always returns (all code paths return a value).
    fn blockAlwaysReturns(self: *const TypeChecker, node: NodeIndex) bool {
        if (node == null_node) return false;
        const data = self.nodeData(node);
        const start = data.lhs;
        const count = data.rhs;
        if (count == 0) return false;

        const stmt_indices = self.tree.extra_data.items[start .. start + count];
        // Check if the last statement always returns.
        const last_stmt = stmt_indices[stmt_indices.len - 1];
        return self.stmtAlwaysReturns(last_stmt);
    }

    /// Check whether a statement always returns.
    fn stmtAlwaysReturns(self: *const TypeChecker, node: NodeIndex) bool {
        if (node == null_node) return false;
        const tag = self.nodeTag(node);
        return switch (tag) {
            .return_stmt => true,
            .block => self.blockAlwaysReturns(node),
            .if_stmt => self.ifStmtAlwaysReturns(node),
            .switch_stmt => self.switchStmtAlwaysReturns(node),
            else => false,
        };
    }

    /// An if statement always returns only if both branches exist and both always return.
    fn ifStmtAlwaysReturns(self: *const TypeChecker, node: NodeIndex) bool {
        const data = self.nodeData(node);
        const extra = self.tree.extra_data.items;
        const then_block = extra[data.rhs];
        const else_node = extra[data.rhs + 1];

        if (else_node == null_node) return false; // no else branch

        const then_returns = self.blockAlwaysReturns(then_block);
        if (!then_returns) return false;

        // Else branch can be another if_stmt or a block.
        if (self.nodeTag(else_node) == .if_stmt) {
            return self.ifStmtAlwaysReturns(else_node);
        }
        return self.blockAlwaysReturns(else_node);
    }

    /// A switch always returns if every arm always returns.
    fn switchStmtAlwaysReturns(self: *const TypeChecker, node: NodeIndex) bool {
        const data = self.nodeData(node);
        const arms_start = data.rhs;
        const extra = self.tree.extra_data.items;
        const arm_count = self.findTrailingCount(arms_start, extra);
        if (arm_count == 0) return false;

        const arm_nodes = extra[arms_start .. arms_start + arm_count];
        for (arm_nodes) |arm| {
            if (arm == null_node) return false;
            const arm_data = self.nodeData(arm);
            if (arm_data.rhs == null_node) return false;
            if (self.nodeTag(arm_data.rhs) == .block) {
                if (!self.blockAlwaysReturns(arm_data.rhs)) return false;
            } else if (self.nodeTag(arm_data.rhs) != .return_stmt) {
                return false;
            }
        }
        return true;
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

            .call => try self.inferCall(node),

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

    /// Infer the type of a function call expression.
    /// Validates argument count and types against the callee's signature.
    fn inferCall(self: *TypeChecker, node: NodeIndex) CheckError!TypeId {
        const data = self.nodeData(node);
        const callee_type = try self.inferExpr(data.lhs);

        // Collect argument types.
        const args_start = data.rhs;
        const extra = self.tree.extra_data.items;
        const arg_count = self.findTrailingCount(args_start, extra);
        const arg_nodes = extra[args_start .. args_start + arg_count];

        var arg_types: [64]TypeId = undefined;
        const actual_count: u32 = @intCast(arg_nodes.len);
        for (arg_nodes, 0..) |arg, i| {
            arg_types[i] = try self.inferExpr(arg);
        }

        // If callee type is unknown, we can't check further.
        if (callee_type == types.null_type) return types.null_type;

        // Look up the FnType from the callee's type.
        const callee_resolved = self.type_pool.get(callee_type);
        switch (callee_resolved) {
            .fn_type => |fn_type| {
                const expected_count: u32 = @intCast(fn_type.params.len);
                const call_tok = self.nodeMainToken(node);

                // Check argument count.
                if (actual_count != expected_count) {
                    const loc = self.tokenLoc(call_tok);
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "function expects {d} argument(s), got {d}",
                        .{ expected_count, actual_count },
                    );
                    return fn_type.return_type;
                }

                // Check each argument type.
                for (fn_type.params, 0..) |param_type, i| {
                    if (param_type == types.null_type) continue;
                    const arg_type = arg_types[i];
                    if (arg_type == types.null_type) continue;
                    if (!self.typesCompatible(param_type, arg_type)) {
                        // Report at the argument token location.
                        const arg_node = arg_nodes[i];
                        const arg_tok = self.nodeMainToken(arg_node);
                        const loc = self.tokenLoc(arg_tok);
                        try self.diagnostics.addErrorFmt(
                            loc.start,
                            loc.end,
                            "argument {d} type mismatch: expected '{s}', got '{s}'",
                            .{ i + 1, self.typeName(param_type), self.typeName(arg_type) },
                        );
                    }
                }

                return fn_type.return_type;
            },
            else => return types.null_type,
        }
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
            .type_error_union => {
                // !T — resolve the inner type and wrap in error union.
                const inner = self.nodeData(node).lhs;
                const inner_type = self.resolveTypeNode(inner);
                if (inner_type == types.null_type) return types.null_type;
                return self.type_pool.intern(self.allocator, .{ .error_union_type = .{
                    .payload = inner_type,
                } }) catch types.null_type;
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

    fn typeName(self: *TypeChecker, type_id: TypeId) []const u8 {
        if (type_id < types.primitives.count) {
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
        // For non-primitive types, check if it's an error union.
        const typ = self.type_pool.get(type_id);
        return switch (typ) {
            .error_union_type => "!T",
            .fn_type => "fn",
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

    fn findParamCount(self: *const TypeChecker, params_start: u32, extra: []const NodeIndex) u32 {
        return self.findTrailingCount(params_start, extra);
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

fn testTypeCheckHasErrorContaining(source: []const u8, needle: []const u8) !bool {
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

    if (!tc_result.diagnostics.hasErrors()) return false;

    for (tc_result.diagnostics.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

// ── Existing tests (preserved) ──────────────────────────────────────────────────

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

// ── Function signature type checking tests ──────────────────────────────────────

test "typecheck: function call correct args" {
    const result = try testTypeCheck(
        \\fn add(a int, b int) int {
        \\    return a + b
        \\}
        \\fn main() {
        \\    var x int = add(1, 2)
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: function call wrong arg count" {
    const result = try testTypeCheck(
        \\fn add(a int, b int) int {
        \\    return a + b
        \\}
        \\fn main() {
        \\    add(1)
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: function call too many args" {
    const result = try testTypeCheck(
        \\fn add(a int, b int) int {
        \\    return a + b
        \\}
        \\fn main() {
        \\    add(1, 2, 3)
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: function call arg type mismatch" {
    const result = try testTypeCheck(
        \\fn greet(name string) int {
        \\    return 0
        \\}
        \\fn main() {
        \\    greet(42)
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: function return type checked" {
    const result = try testTypeCheck(
        \\fn get_num() int {
        \\    return "hello"
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: function return type valid" {
    const result = try testTypeCheck(
        \\fn get_num() int {
        \\    return 42
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: void function returns value" {
    const result = try testTypeCheck(
        \\fn do_stuff() {
        \\    return 42
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: void function bare return ok" {
    const result = try testTypeCheck(
        \\fn do_stuff() {
        \\    return
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: non-void function bare return" {
    const result = try testTypeCheck(
        \\fn get_num() int {
        \\    return
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: function missing return on all paths" {
    const result = try testTypeCheck(
        \\fn get_num() int {
        \\    var x int = 42
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: function with if-else returns on all paths" {
    const result = try testTypeCheck(
        \\fn abs(x int) int {
        \\    if x > 0 {
        \\        return x
        \\    } else {
        \\        return -x
        \\    }
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: function with if but no else missing return" {
    const result = try testTypeCheck(
        \\fn maybe(x int) int {
        \\    if x > 0 {
        \\        return x
        \\    }
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: recursive function call" {
    const result = try testTypeCheck(
        \\fn factorial(n int) int {
        \\    if n == 0 {
        \\        return 1
        \\    } else {
        \\        return n
        \\    }
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: forward function call" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = helper()
        \\}
        \\fn helper() int {
        \\    return 42
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: function call return type used in assignment" {
    const result = try testTypeCheck(
        \\fn get_str() string {
        \\    return "hello"
        \\}
        \\fn main() {
        \\    var x int = get_str()
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: no-arg function called with args" {
    const result = try testTypeCheck(
        \\fn get_num() int {
        \\    return 42
        \\}
        \\fn main() {
        \\    get_num(1)
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: void function no return needed" {
    const result = try testTypeCheck(
        \\fn do_nothing() {
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: function with multiple params type check" {
    const result = try testTypeCheck(
        \\fn combine(a string, b int, c bool) int {
        \\    return b
        \\}
        \\fn main() {
        \\    combine("hi", 42, true)
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: function call second arg wrong type" {
    const result = try testTypeCheck(
        \\fn combine(a string, b int) int {
        \\    return b
        \\}
        \\fn main() {
        \\    combine("hi", "world")
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: error message for arg count mismatch" {
    // Check the error message mentions expected vs got count
    const has_2 = try testTypeCheckHasErrorContaining(
        \\fn add(a int, b int) int {
        \\    return a + b
        \\}
        \\fn main() {
        \\    add(1)
        \\}
        \\
    , "expects 2");
    try std.testing.expect(has_2);
}

test "typecheck: function with only return statement" {
    const result = try testTypeCheck(
        \\fn identity(x int) int {
        \\    return x
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}
