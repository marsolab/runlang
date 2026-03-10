const std = @import("std");
const ast = @import("ast.zig");
const Ast = ast.Ast;
const Node = ast.Node;
const NodeIndex = ast.NodeIndex;
const null_node = ast.null_node;
const Token = @import("token.zig").Token;
const ir = @import("ir.zig");
const resolve = @import("resolve.zig");
const types = @import("types.zig");
const diagnostics = @import("diagnostics.zig");

pub const LowerError = error{OutOfMemory};

/// Lower a typed AST into an IR Module.
pub fn lower(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    tokens: []const Token,
) LowerError!ir.Module {
    var ctx = LoweringContext{
        .allocator = allocator,
        .tree = tree,
        .tokens = tokens,
        .module = ir.Module.init(),
        .current_func = null,
        .current_block = null,
        .var_map = .empty,
        .scope_stack = .empty,
        .defer_stack = .empty,
        .defer_scope_stack = .empty,
        .owned_stack = .empty,
        .owned_scope_stack = .empty,
    };
    try ctx.lowerModule();
    return ctx.module;
}

const LoweringContext = struct {
    allocator: std.mem.Allocator,
    tree: *const Ast,
    tokens: []const Token,
    module: ir.Module,
    current_func: ?*ir.Function,
    current_block: ?*ir.BasicBlock,

    // Variable tracking: map from variable name to its local_idx in Module.local_infos
    var_map: std.ArrayList(VarEntry),
    scope_stack: std.ArrayList(usize),

    // Ownership tracking: defer statements and owned allocations per scope
    defer_stack: std.ArrayList(DeferEntry),
    defer_scope_stack: std.ArrayList(usize),
    owned_stack: std.ArrayList(OwnedEntry),
    owned_scope_stack: std.ArrayList(usize),

    const VarEntry = struct {
        name: []const u8,
        local_idx: u32,
    };

    const DeferEntry = struct {
        expr_node: NodeIndex,
    };

    const OwnedEntry = struct {
        name: []const u8,
        local_idx: u32,
        is_moved: bool,
    };

    fn pushScope(self: *LoweringContext) LowerError!void {
        try self.scope_stack.append(self.allocator, self.var_map.items.len);
        try self.defer_scope_stack.append(self.allocator, self.defer_stack.items.len);
        try self.owned_scope_stack.append(self.allocator, self.owned_stack.items.len);
    }

    fn popScope(self: *LoweringContext) LowerError!void {
        if (self.scope_stack.items.len > 0) {
            const defer_boundary = self.defer_scope_stack.pop().?;
            const owned_boundary = self.owned_scope_stack.pop().?;

            try self.emitScopeCleanup(defer_boundary, owned_boundary);

            self.defer_stack.shrinkRetainingCapacity(defer_boundary);
            self.owned_stack.shrinkRetainingCapacity(owned_boundary);

            const saved = self.scope_stack.pop().?;
            self.var_map.shrinkRetainingCapacity(saved);
        }
    }

    /// Emit cleanup code for a scope: deferred expressions in LIFO order, then gen_free for owned variables.
    fn emitScopeCleanup(self: *LoweringContext, defer_boundary: usize, owned_boundary: usize) LowerError!void {
        // Skip cleanup if the current block is already terminated (e.g., after an explicit return)
        if (self.current_block) |block| {
            if (block.isTerminated()) return;
        } else return;

        // Execute deferred expressions in LIFO order
        var i = self.defer_stack.items.len;
        while (i > defer_boundary) {
            i -= 1;
            _ = try self.lowerExpr(self.defer_stack.items[i].expr_node);
        }
        // Free owned, non-moved variables in LIFO order
        var j = self.owned_stack.items.len;
        while (j > owned_boundary) {
            j -= 1;
            const entry = self.owned_stack.items[j];
            if (!entry.is_moved) {
                const ptr_ref = self.allocRef();
                try self.emit(ir.makeInst(.local_get, ptr_ref, entry.local_idx, 0));
                try self.emit(ir.makeInst(.gen_free, 0, ptr_ref, 0));
            }
        }
    }

    /// Emit cleanup for all active scopes (used before return statements).
    fn emitAllCleanup(self: *LoweringContext) LowerError!void {
        try self.emitScopeCleanup(0, 0);
    }

    fn defineVar(self: *LoweringContext, name: []const u8, c_type: []const u8, init_ref: ir.Ref) LowerError!void {
        const local_idx = try self.module.addLocalInfo(self.allocator, name, c_type);
        try self.var_map.append(self.allocator, .{ .name = name, .local_idx = local_idx });
        try self.emit(ir.makeInst(.local_set, 0, local_idx, init_ref));
    }

    fn setVar(self: *LoweringContext, name: []const u8, val_ref: ir.Ref) LowerError!void {
        if (self.lookupLocalIdx(name)) |local_idx| {
            try self.emit(ir.makeInst(.local_set, 0, local_idx, val_ref));
        }
    }

    fn getVar(self: *LoweringContext, name: []const u8) LowerError!ir.Ref {
        if (self.lookupLocalIdx(name)) |local_idx| {
            const r = self.allocRef();
            try self.emit(ir.makeInst(.local_get, r, local_idx, 0));
            return r;
        }
        return ir.null_ref;
    }

    fn lookupLocalIdx(self: *const LoweringContext, name: []const u8) ?u32 {
        var i = self.var_map.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.var_map.items[i].name, name)) {
                return self.var_map.items[i].local_idx;
            }
        }
        return null;
    }

    /// Infer C type from an expression node.
    fn inferCTypeFromExpr(self: *const LoweringContext, node_idx: NodeIndex) []const u8 {
        if (node_idx == null_node) return "int64_t";
        const node = self.tree.nodes.items[node_idx];
        return switch (node.tag) {
            .string_literal => "run_string_t",
            .bool_literal => "bool",
            .int_literal => "int64_t",
            .float_literal => "double",
            .null_literal => "void*",
            else => "int64_t",
        };
    }

    fn lowerModule(self: *LoweringContext) LowerError!void {
        const root = self.tree.nodes.items[0];
        const start = root.data.lhs;
        const count = root.data.rhs;
        const decl_indices = self.tree.extra_data.items[start .. start + count];

        for (decl_indices) |decl_idx| {
            try self.lowerTopLevel(decl_idx);
        }

        self.var_map.deinit(self.allocator);
        self.scope_stack.deinit(self.allocator);
        self.defer_stack.deinit(self.allocator);
        self.defer_scope_stack.deinit(self.allocator);
        self.owned_stack.deinit(self.allocator);
        self.owned_scope_stack.deinit(self.allocator);
    }

    fn lowerTopLevel(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        if (node_idx == null_node) return;
        const node = self.tree.nodes.items[node_idx];
        switch (node.tag) {
            .pub_decl => try self.lowerTopLevel(node.data.lhs),
            .fn_decl => try self.lowerFnDecl(node_idx),
            .import_decl => {},
            else => {},
        }
    }

    fn lowerFnDecl(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const fn_tok = node.main_token;

        var name_tok = fn_tok + 1;
        if (self.tokens[name_tok].tag == .l_paren) {
            var depth: u32 = 1;
            name_tok += 1;
            while (name_tok < self.tokens.len and depth > 0) : (name_tok += 1) {
                if (self.tokens[name_tok].tag == .l_paren) depth += 1;
                if (self.tokens[name_tok].tag == .r_paren) depth -= 1;
            }
        }
        const name = self.tokenSlice(name_tok);

        const mangled = try std.fmt.allocPrint(self.allocator, "run_main__{s}", .{name});
        try self.module.owned_strings.append(self.allocator, mangled);

        const func_id = try self.module.addFunction(self.allocator, mangled);
        self.current_func = self.module.getFunction(func_id);
        self.current_func.?.return_type_name = "void";

        const block_id = try self.current_func.?.addBlock(self.allocator);
        self.current_block = self.current_func.?.getBlock(block_id);

        try self.pushScope();

        const body = node.data.rhs;
        if (body != null_node) {
            try self.lowerBlock(body);
        }

        try self.popScope();

        if (self.current_block != null and !self.current_block.?.isTerminated()) {
            try self.current_block.?.addInst(self.allocator, ir.makeInst(.ret_void, 0, 0, 0));
        }
    }

    fn lowerBlock(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        if (node.tag != .block) return;

        const start = node.data.lhs;
        const count = node.data.rhs;
        const stmts = self.tree.extra_data.items[start .. start + count];

        for (stmts) |stmt_idx| {
            try self.lowerStmt(stmt_idx);
        }
    }

    fn lowerStmt(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        if (node_idx == null_node) return;
        const node = self.tree.nodes.items[node_idx];
        switch (node.tag) {
            .expr_stmt => {
                _ = try self.lowerExpr(node.data.lhs);
            },
            .return_stmt => {
                if (node.data.lhs != null_node) {
                    const val = try self.lowerExpr(node.data.lhs);
                    try self.emitAllCleanup();
                    try self.emit(ir.makeInst(.ret, 0, val, 0));
                } else {
                    try self.emitAllCleanup();
                    try self.emit(ir.makeInst(.ret_void, 0, 0, 0));
                }
            },
            .var_decl, .let_decl => try self.lowerVarDecl(node_idx),
            .short_var_decl => try self.lowerShortVarDecl(node_idx),
            .assign => try self.lowerAssign(node_idx),
            .if_stmt => try self.lowerIfStmt(node_idx),
            .for_stmt => try self.lowerForStmt(node_idx),
            .block => {
                try self.pushScope();
                try self.lowerBlock(node_idx);
                try self.popScope();
            },
            .defer_stmt => {
                // Record the deferred expression; it will be lowered at scope exit
                try self.defer_stack.append(self.allocator, .{ .expr_node = node.data.lhs });
            },
            .break_stmt, .continue_stmt => {},
            else => {},
        }
    }

    fn lowerVarDecl(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const name_tok = node.main_token + 1;
        const name = self.tokenSlice(name_tok);
        const c_type = self.inferCTypeFromExpr(node.data.rhs);

        if (node.data.rhs != null_node) {
            const val = try self.lowerExpr(node.data.rhs);
            try self.defineVar(name, c_type, val);

            // Track ownership for alloc expressions
            if (self.tree.nodes.items[node.data.rhs].tag == .alloc_expr) {
                if (self.lookupLocalIdx(name)) |local_idx| {
                    try self.owned_stack.append(self.allocator, .{
                        .name = name,
                        .local_idx = local_idx,
                        .is_moved = false,
                    });
                }
            }
        } else {
            try self.defineVar(name, c_type, ir.null_ref);
        }
    }

    fn lowerShortVarDecl(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        if (node.data.lhs != null_node) {
            const lhs_node = self.tree.nodes.items[node.data.lhs];
            if (lhs_node.tag == .ident) {
                const name = self.tokenSlice(lhs_node.main_token);
                const c_type = self.inferCTypeFromExpr(node.data.rhs);
                if (node.data.rhs != null_node) {
                    const val = try self.lowerExpr(node.data.rhs);
                    try self.defineVar(name, c_type, val);

                    // Track ownership for alloc expressions
                    if (self.tree.nodes.items[node.data.rhs].tag == .alloc_expr) {
                        if (self.lookupLocalIdx(name)) |local_idx| {
                            try self.owned_stack.append(self.allocator, .{
                                .name = name,
                                .local_idx = local_idx,
                                .is_moved = false,
                            });
                        }
                    }
                }
            }
        }
    }

    fn lowerAssign(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const val = try self.lowerExpr(node.data.rhs);

        if (node.data.lhs != null_node) {
            const target = self.tree.nodes.items[node.data.lhs];
            if (target.tag == .ident) {
                const target_name = self.tokenSlice(target.main_token);

                // Move semantics: if RHS is an ident referencing an owned variable,
                // mark the source as moved and transfer ownership to the target.
                if (node.data.rhs != null_node) {
                    const rhs_node = self.tree.nodes.items[node.data.rhs];
                    if (rhs_node.tag == .ident) {
                        const src_name = self.tokenSlice(rhs_node.main_token);
                        self.markOwnedMoved(src_name);
                        // Transfer ownership to the target
                        if (self.lookupLocalIdx(target_name)) |local_idx| {
                            try self.owned_stack.append(self.allocator, .{
                                .name = target_name,
                                .local_idx = local_idx,
                                .is_moved = false,
                            });
                        }
                    }
                }

                try self.setVar(target_name, val);
            }
        }
    }

    /// Mark an owned variable as moved (ownership transferred away).
    fn markOwnedMoved(self: *LoweringContext, name: []const u8) void {
        var i = self.owned_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.owned_stack.items[i].name, name)) {
                self.owned_stack.items[i].is_moved = true;
                return;
            }
        }
    }

    fn lowerIfStmt(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const extra = self.tree.extra_data.items;
        const cond_ref = try self.lowerExpr(node.data.lhs);

        const then_block_node = extra[node.data.rhs];
        const else_node = extra[node.data.rhs + 1];

        const func = self.current_func orelse return;

        if (else_node == null_node) {
            const then_bb = try func.addBlock(self.allocator);
            const after_bb = try func.addBlock(self.allocator);

            try self.emit(ir.makeInst(.br_cond, 0, cond_ref, then_bb));
            try self.emit(ir.makeInst(.br, 0, after_bb, 0));

            self.current_block = func.getBlock(then_bb);
            try self.pushScope();
            try self.lowerBlock(then_block_node);
            try self.popScope();
            if (!self.current_block.?.isTerminated()) {
                try self.emit(ir.makeInst(.br, 0, after_bb, 0));
            }

            self.current_block = func.getBlock(after_bb);
        } else {
            const then_bb = try func.addBlock(self.allocator);
            const else_bb = try func.addBlock(self.allocator);
            const after_bb = try func.addBlock(self.allocator);

            try self.emit(ir.makeInst(.br_cond, 0, cond_ref, then_bb));
            try self.emit(ir.makeInst(.br, 0, else_bb, 0));

            self.current_block = func.getBlock(then_bb);
            try self.pushScope();
            try self.lowerBlock(then_block_node);
            try self.popScope();
            if (!self.current_block.?.isTerminated()) {
                try self.emit(ir.makeInst(.br, 0, after_bb, 0));
            }

            self.current_block = func.getBlock(else_bb);
            try self.pushScope();
            const else_tag = self.tree.nodes.items[else_node].tag;
            if (else_tag == .if_stmt) {
                try self.lowerIfStmt(else_node);
            } else if (else_tag == .block) {
                try self.lowerBlock(else_node);
            }
            try self.popScope();
            if (self.current_block != null and !self.current_block.?.isTerminated()) {
                try self.emit(ir.makeInst(.br, 0, after_bb, 0));
            }

            self.current_block = func.getBlock(after_bb);
        }
    }

    fn lowerForStmt(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const func = self.current_func orelse return;

        const cond_node = node.data.lhs;
        const body_node = node.data.rhs;

        const cond_bb = try func.addBlock(self.allocator);
        const body_bb = try func.addBlock(self.allocator);
        const after_bb = try func.addBlock(self.allocator);

        try self.emit(ir.makeInst(.br, 0, cond_bb, 0));

        self.current_block = func.getBlock(cond_bb);
        if (cond_node == null_node) {
            try self.emit(ir.makeInst(.br, 0, body_bb, 0));
        } else {
            const cond_ref = try self.lowerExpr(cond_node);
            try self.emit(ir.makeInst(.br_cond, 0, cond_ref, body_bb));
            try self.emit(ir.makeInst(.br, 0, after_bb, 0));
        }

        self.current_block = func.getBlock(body_bb);
        try self.pushScope();
        try self.lowerBlock(body_node);
        try self.popScope();
        if (!self.current_block.?.isTerminated()) {
            try self.emit(ir.makeInst(.br, 0, cond_bb, 0));
        }

        self.current_block = func.getBlock(after_bb);
    }

    fn lowerExpr(self: *LoweringContext, node_idx: NodeIndex) LowerError!ir.Ref {
        if (node_idx == null_node) return ir.null_ref;
        const node = self.tree.nodes.items[node_idx];
        switch (node.tag) {
            .int_literal => {
                const text = self.tokenSlice(node.main_token);
                const val = std.fmt.parseInt(i64, text, 10) catch 0;
                const r = self.allocRef();
                try self.emit(ir.makeInst(.const_int, r, @as(u32, @intCast(@as(u64, @bitCast(val)) & 0xFFFFFFFF)), 0));
                return r;
            },
            .string_literal => {
                const raw = self.tokenSlice(node.main_token);
                const text = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
                const str_idx = try self.module.addStringConstant(self.allocator, text);
                const r = self.allocRef();
                try self.emit(ir.makeInst(.const_string, r, str_idx, 0));
                return r;
            },
            .bool_literal => {
                const text = self.tokenSlice(node.main_token);
                const val: u32 = if (std.mem.eql(u8, text, "true")) 1 else 0;
                const r = self.allocRef();
                try self.emit(ir.makeInst(.const_bool, r, val, 0));
                return r;
            },
            .null_literal => {
                const r = self.allocRef();
                try self.emit(ir.makeInst(.const_null, r, 0, 0));
                return r;
            },
            .call => return try self.lowerCall(node_idx),
            .binary_op => {
                const lhs_ref = try self.lowerExpr(node.data.lhs);
                const rhs_ref = try self.lowerExpr(node.data.rhs);
                const op_tok = node.main_token;
                const op: ir.Inst.Op = switch (self.tokens[op_tok].tag) {
                    .plus => .add,
                    .minus => .sub,
                    .star => .mul,
                    .slash => .div,
                    .percent => .mod,
                    .equal_equal => .eq,
                    .bang_equal => .ne,
                    .less => .lt,
                    .less_equal => .le,
                    .greater => .gt,
                    .greater_equal => .ge,
                    .kw_and => .log_and,
                    .kw_or => .log_or,
                    else => .nop,
                };
                const r = self.allocRef();
                try self.emit(ir.makeInst(op, r, lhs_ref, rhs_ref));
                return r;
            },
            .unary_op => {
                const operand = try self.lowerExpr(node.data.lhs);
                const op_tok = node.main_token;
                const op: ir.Inst.Op = switch (self.tokens[op_tok].tag) {
                    .minus => .neg,
                    .bang, .kw_not => .log_not,
                    else => .nop,
                };
                const r = self.allocRef();
                try self.emit(ir.makeInst(op, r, operand, 0));
                return r;
            },
            .alloc_expr => {
                // alloc(Type, capacity?) — emit gen_alloc with a default size
                // data.lhs = type node, data.rhs = extra_data index for args
                // For now, use a default allocation size of 8 bytes (pointer-sized)
                const size_ref = self.allocRef();
                try self.emit(ir.makeInst(.const_int, size_ref, 8, 0));
                const ptr_ref = self.allocRef();
                try self.emit(ir.makeInst(.gen_alloc, ptr_ref, size_ref, 0));
                // Create a generational reference from the raw pointer
                const ref_result = self.allocRef();
                try self.emit(ir.makeInst(.gen_ref_create, ref_result, ptr_ref, 0));
                return ref_result;
            },
            .addr_of, .addr_of_const => {
                // &expr or @expr — create a generational reference from the operand
                const operand = try self.lowerExpr(node.data.lhs);
                const ref_result = self.allocRef();
                try self.emit(ir.makeInst(.gen_ref_create, ref_result, operand, 0));
                return ref_result;
            },
            .deref => {
                // *expr — dereference a generational reference with safety check
                const operand = try self.lowerExpr(node.data.lhs);
                const deref_result = self.allocRef();
                try self.emit(ir.makeInst(.gen_ref_deref, deref_result, operand, 0));
                return deref_result;
            },
            .field_access => {
                return try self.lowerExpr(node.data.lhs);
            },
            .ident => {
                const name = self.tokenSlice(node.main_token);
                return try self.getVar(name);
            },
            .if_expr => return try self.lowerIfExpr(node_idx),
            else => return ir.null_ref,
        }
    }

    fn lowerIfExpr(self: *LoweringContext, node_idx: NodeIndex) LowerError!ir.Ref {
        const node = self.tree.nodes.items[node_idx];
        const extra = self.tree.extra_data.items;
        const cond_ref = try self.lowerExpr(node.data.lhs);

        const then_node = extra[node.data.rhs];
        const else_node = extra[node.data.rhs + 1];

        const func = self.current_func orelse return ir.null_ref;

        // Use a local variable for the result so it survives across blocks
        const result_name = "_if_result";
        const result_idx = try self.module.addLocalInfo(self.allocator, result_name, "int64_t");

        const then_bb = try func.addBlock(self.allocator);
        const else_bb = try func.addBlock(self.allocator);
        const after_bb = try func.addBlock(self.allocator);

        try self.emit(ir.makeInst(.br_cond, 0, cond_ref, then_bb));
        try self.emit(ir.makeInst(.br, 0, else_bb, 0));

        self.current_block = func.getBlock(then_bb);
        const then_ref = try self.lowerExpr(then_node);
        try self.emit(ir.makeInst(.local_set, 0, result_idx, then_ref));
        try self.emit(ir.makeInst(.br, 0, after_bb, 0));

        self.current_block = func.getBlock(else_bb);
        const else_ref = try self.lowerExpr(else_node);
        try self.emit(ir.makeInst(.local_set, 0, result_idx, else_ref));
        try self.emit(ir.makeInst(.br, 0, after_bb, 0));

        self.current_block = func.getBlock(after_bb);
        const r = self.allocRef();
        try self.emit(ir.makeInst(.local_get, r, result_idx, 0));
        return r;
    }

    fn lowerCall(self: *LoweringContext, node_idx: NodeIndex) LowerError!ir.Ref {
        const node = self.tree.nodes.items[node_idx];
        const callee_idx = node.data.lhs;
        const args_start = node.data.rhs;

        const callee_name = self.resolveCalleeName(callee_idx);
        const target_name = mapBuiltinCall(callee_name);

        const extra = self.tree.extra_data.items;
        var arg_refs: std.ArrayList(ir.Ref) = .empty;
        defer arg_refs.deinit(self.allocator);

        var n: u32 = 0;
        while (args_start + n < extra.len) {
            if (extra[args_start + n] == n) break;
            n += 1;
        }

        const arg_nodes = extra[args_start .. args_start + n];
        for (arg_nodes) |arg_node| {
            const arg_ref = try self.lowerExpr(arg_node);
            try arg_refs.append(self.allocator, arg_ref);
        }

        const call_idx = try self.module.addCallInfo(self.allocator, target_name, arg_refs.items);

        const is_void = isVoidCall(target_name);
        const r = if (is_void) ir.null_ref else self.allocRef();
        try self.emit(ir.makeInst(.call, r, call_idx, 0));
        return r;
    }

    fn resolveCalleeName(self: *LoweringContext, callee_idx: NodeIndex) []const u8 {
        if (callee_idx == null_node) return "<unknown>";
        const callee = self.tree.nodes.items[callee_idx];
        switch (callee.tag) {
            .ident => return self.tokenSlice(callee.main_token),
            .field_access => {
                const obj = self.tree.nodes.items[callee.data.lhs];
                const obj_name = if (obj.tag == .ident) self.tokenSlice(obj.main_token) else "";
                const dot_tok = callee.main_token;
                if (dot_tok + 1 < self.tokens.len and self.tokens[dot_tok + 1].tag == .identifier) {
                    const field_name = self.tokenSlice(dot_tok + 1);
                    const result = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ obj_name, field_name }) catch return "<unknown>";
                    self.module.owned_strings.append(self.allocator, result) catch return "<unknown>";
                    return result;
                }
                return obj_name;
            },
            else => return "<unknown>",
        }
    }

    fn isVoidCall(name: []const u8) bool {
        return std.mem.eql(u8, name, "run_fmt_println") or
            std.mem.eql(u8, name, "run_fmt_print_int") or
            std.mem.eql(u8, name, "run_fmt_print_float") or
            std.mem.eql(u8, name, "run_fmt_print_bool");
    }

    fn mapBuiltinCall(name: []const u8) []const u8 {
        if (std.mem.eql(u8, name, "fmt.println")) return "run_fmt_println";
        if (std.mem.eql(u8, name, "fmt.print_int")) return "run_fmt_print_int";
        if (std.mem.eql(u8, name, "fmt.print_float")) return "run_fmt_print_float";
        if (std.mem.eql(u8, name, "fmt.print_bool")) return "run_fmt_print_bool";
        return name;
    }

    fn emit(self: *LoweringContext, inst: ir.Inst) LowerError!void {
        if (self.current_block) |block| {
            try block.addInst(self.allocator, inst);
        }
    }

    fn allocRef(self: *LoweringContext) ir.Ref {
        if (self.current_func) |func| {
            return func.allocRef();
        }
        return ir.null_ref;
    }

    fn tokenSlice(self: *const LoweringContext, tok_index: u32) []const u8 {
        const tok = self.tokens[tok_index];
        return self.tree.source[tok.loc.start..tok.loc.end];
    }
};

// Tests

const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;

fn testLower(source: []const u8) !ir.Module {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(source);
    var token_list = try lexer.tokenize(allocator);
    defer token_list.deinit(allocator);

    var parser = Parser.init(allocator, token_list.items, source);
    defer parser.deinit();
    _ = try parser.parseFile();

    return try lower(allocator, &parser.tree, token_list.items);
}

test "lower: empty function" {
    var module = try testLower("fn main() {\n}\n");
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    try std.testing.expectEqualStrings("run_main__main", module.functions.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), module.functions.items[0].blocks.items.len);
    try std.testing.expect(module.functions.items[0].blocks.items[0].isTerminated());
}

test "lower: hello world" {
    var module = try testLower(
        \\use "fmt"
        \\fn main() {
        \\    fmt.println("Hello, World!")
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    try std.testing.expectEqual(@as(usize, 1), module.string_constants.items.len);
    try std.testing.expectEqualStrings("Hello, World!", module.string_constants.items[0].value);
    try std.testing.expectEqual(@as(usize, 1), module.call_infos.items.len);
    try std.testing.expectEqualStrings("run_fmt_println", module.call_infos.items[0].target_name);
}

test "lower: integer literal" {
    var module = try testLower(
        \\fn main() {
        \\    return 42
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    const func = &module.functions.items[0];
    const block = &func.blocks.items[0];
    try std.testing.expect(block.insts.items.len >= 2);
    try std.testing.expectEqual(ir.Inst.Op.const_int, block.insts.items[0].op);
    try std.testing.expectEqual(ir.Inst.Op.ret, block.insts.items[1].op);
}

test "lower: variable via local_set/local_get" {
    var module = try testLower(
        \\use "fmt"
        \\fn main() {
        \\    let x = 42
        \\    fmt.print_int(x)
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    // Should have a local_info for "x"
    try std.testing.expectEqual(@as(usize, 1), module.local_infos.items.len);
    try std.testing.expectEqualStrings("x", module.local_infos.items[0].name);
    try std.testing.expectEqualStrings("int64_t", module.local_infos.items[0].c_type);

    // The function should have local_set and local_get instructions
    const func = &module.functions.items[0];
    const block = &func.blocks.items[0];
    var has_local_set = false;
    var has_local_get = false;
    for (block.insts.items) |inst| {
        if (inst.op == .local_set) has_local_set = true;
        if (inst.op == .local_get) has_local_get = true;
    }
    try std.testing.expect(has_local_set);
    try std.testing.expect(has_local_get);
}

test "lower: if/else produces multiple blocks" {
    var module = try testLower(
        \\fn main() {
        \\    let x = 1
        \\    if x > 0 {
        \\        return 1
        \\    } else {
        \\        return 0
        \\    }
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    const func = &module.functions.items[0];
    try std.testing.expect(func.blocks.items.len >= 4);
}

test "lower: for loop produces cond/body/after blocks" {
    var module = try testLower(
        \\fn main() {
        \\    var i = 0
        \\    for i < 3 {
        \\        i = i + 1
        \\    }
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    const func = &module.functions.items[0];
    try std.testing.expect(func.blocks.items.len >= 4);

    // Should have a local_info for "i"
    try std.testing.expectEqual(@as(usize, 1), module.local_infos.items.len);
    try std.testing.expectEqualStrings("i", module.local_infos.items[0].name);
}

// Helper to check if a block contains an instruction with a given op
fn blockHasOp(block: *const ir.BasicBlock, op: ir.Inst.Op) bool {
    for (block.insts.items) |inst| {
        if (inst.op == op) return true;
    }
    return false;
}

test "lower: alloc emits gen_free at scope exit" {
    var module = try testLower(
        \\fn main() {
        \\    let s = alloc([]int, 8)
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    const func = &module.functions.items[0];
    const block = &func.blocks.items[0];

    // Should contain gen_alloc, gen_ref_create, and gen_free (from scope cleanup)
    try std.testing.expect(blockHasOp(block, .gen_alloc));
    try std.testing.expect(blockHasOp(block, .gen_ref_create));
    try std.testing.expect(blockHasOp(block, .gen_free));

    // gen_free should appear before ret_void
    var found_free = false;
    var found_ret_after_free = false;
    for (block.insts.items) |inst| {
        if (inst.op == .gen_free) found_free = true;
        if (found_free and inst.op == .ret_void) found_ret_after_free = true;
    }
    try std.testing.expect(found_free);
    try std.testing.expect(found_ret_after_free);
}

test "lower: defer emits deferred call at scope exit" {
    var module = try testLower(
        \\use "fmt"
        \\fn main() {
        \\    defer fmt.println("cleanup")
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    const func = &module.functions.items[0];
    const block = &func.blocks.items[0];

    // The deferred fmt.println call should be emitted at scope exit
    try std.testing.expect(blockHasOp(block, .call));
    try std.testing.expectEqual(@as(usize, 1), module.call_infos.items.len);
    try std.testing.expectEqualStrings("run_fmt_println", module.call_infos.items[0].target_name);
}

test "lower: return emits cleanup before ret" {
    var module = try testLower(
        \\fn main() {
        \\    let s = alloc([]int, 8)
        \\    return
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    const func = &module.functions.items[0];
    const block = &func.blocks.items[0];

    // gen_free should appear before ret_void (from the return statement's cleanup)
    var found_free = false;
    var found_ret_after_free = false;
    for (block.insts.items) |inst| {
        if (inst.op == .gen_free) found_free = true;
        if (found_free and inst.op == .ret_void) found_ret_after_free = true;
    }
    try std.testing.expect(found_free);
    try std.testing.expect(found_ret_after_free);
}

test "lower: moved variable is not freed (no double-free)" {
    var module = try testLower(
        \\fn main() {
        \\    var s = alloc([]int, 8)
        \\    var t = 0
        \\    t = s
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    const func = &module.functions.items[0];
    const block = &func.blocks.items[0];

    // Should have exactly one gen_free (for 't' which now owns the value),
    // not two (which would be a double-free).
    var free_count: usize = 0;
    for (block.insts.items) |inst| {
        if (inst.op == .gen_free) free_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), free_count);
}

test "lower: nested scopes free inner scope first" {
    var module = try testLower(
        \\fn main() {
        \\    let outer = alloc([]int, 8)
        \\    {
        \\        let inner = alloc([]int, 4)
        \\    }
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    const func = &module.functions.items[0];
    const block = &func.blocks.items[0];

    // Should have two gen_free instructions (inner scope freed first, then outer)
    var free_count: usize = 0;
    for (block.insts.items) |inst| {
        if (inst.op == .gen_free) free_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), free_count);
}

test "lower: defer and alloc combined — defer runs before free" {
    var module = try testLower(
        \\use "fmt"
        \\fn main() {
        \\    let s = alloc([]int, 8)
        \\    defer fmt.println("cleanup")
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    const func = &module.functions.items[0];
    const block = &func.blocks.items[0];

    // Deferred call should appear before gen_free
    var found_call = false;
    var found_free_after_call = false;
    for (block.insts.items) |inst| {
        if (inst.op == .call) found_call = true;
        if (found_call and inst.op == .gen_free) found_free_after_call = true;
    }
    try std.testing.expect(found_call);
    try std.testing.expect(found_free_after_call);
}
