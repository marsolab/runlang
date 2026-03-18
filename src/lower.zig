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
const TypeId = types.TypeId;
const TypePool = types.TypePool;
const typecheck_mod = @import("typecheck.zig");
const diagnostics = @import("diagnostics.zig");

pub const LowerError = error{OutOfMemory};

/// Lower a typed AST into an IR Module.
pub fn lower(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    tokens: []const Token,
    tc_result: *const typecheck_mod.TypeCheckResult,
) LowerError!ir.Module {
    return lowerWithSource(allocator, tree, tokens, tc_result, null);
}

/// Lower a typed AST into an IR Module, optionally recording source debug info.
pub fn lowerWithSource(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    tokens: []const Token,
    tc_result: *const typecheck_mod.TypeCheckResult,
    source_path: ?[]const u8,
) LowerError!ir.Module {
    var ctx = LoweringContext{
        .allocator = allocator,
        .tree = tree,
        .tokens = tokens,
        .type_map = tc_result.type_map.items,
        .type_pool = &tc_result.type_pool,
        .module = ir.Module.init(),
        .current_func = null,
        .current_block = null,
        .current_src_loc = .{},
        .var_map = .empty,
        .var_lookup = .empty,
        .var_shadow_stack = .empty,
        .var_shadow_scope_stack = .empty,
        .scope_stack = .empty,
        .defer_stack = .empty,
        .defer_scope_stack = .empty,
        .owned_stack = .empty,
        .owned_scope_stack = .empty,
    };
    // Register the source file for debug info
    if (source_path) |path| {
        try ctx.module.source_files.append(allocator, path);
    }
    try ctx.lowerModule();
    return ctx.module;
}

const LoweringContext = struct {
    allocator: std.mem.Allocator,
    tree: *const Ast,
    tokens: []const Token,
    type_map: []const TypeId,
    type_pool: *const TypePool,
    module: ir.Module,
    current_func: ?*ir.Function,
    current_block: ?*ir.BasicBlock,
    /// Current source location for debug info, stamped onto emitted instructions.
    current_src_loc: ir.SrcLoc,

    // Variable tracking: map from variable name to its local_idx in Module.local_infos
    var_map: std.ArrayList(VarEntry),
    var_lookup: std.StringHashMapUnmanaged(u32),
    var_shadow_stack: std.ArrayList(VarShadowEntry),
    var_shadow_scope_stack: std.ArrayList(usize),
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

    const VarShadowEntry = struct {
        name: []const u8,
        had_prev: bool,
        prev_local_idx: u32,
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
        try self.var_shadow_scope_stack.append(self.allocator, self.var_shadow_stack.items.len);
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

            const shadow_boundary = self.var_shadow_scope_stack.pop().?;
            var i = self.var_shadow_stack.items.len;
            while (i > shadow_boundary) {
                i -= 1;
                const shadow = self.var_shadow_stack.items[i];
                if (shadow.had_prev) {
                    try self.var_lookup.put(self.allocator, shadow.name, shadow.prev_local_idx);
                } else {
                    _ = self.var_lookup.remove(shadow.name);
                }
            }
            self.var_shadow_stack.shrinkRetainingCapacity(shadow_boundary);

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

    fn defineVar(self: *LoweringContext, name: []const u8, c_type: []const u8, alignment: u32, init_ref: ir.Ref) LowerError!u32 {
        const prev_local = self.var_lookup.get(name);
        const local_idx = try self.module.addLocalInfoAligned(self.allocator, name, c_type, alignment);
        try self.var_map.append(self.allocator, .{ .name = name, .local_idx = local_idx });
        try self.var_shadow_stack.append(self.allocator, .{
            .name = name,
            .had_prev = prev_local != null,
            .prev_local_idx = prev_local orelse 0,
        });
        try self.var_lookup.put(self.allocator, name, local_idx);
        try self.emit(ir.makeInst(.local_set, 0, local_idx, init_ref));
        return local_idx;
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
        return self.var_lookup.get(name);
    }

    fn typeOfNode(self: *const LoweringContext, node_idx: NodeIndex) TypeId {
        if (node_idx == null_node or node_idx >= self.type_map.len) return types.null_type;
        return self.type_map[node_idx];
    }

    fn simdTypeSuffix(self: *const LoweringContext, type_id: TypeId) []const u8 {
        if (type_id < types.primitives.count) {
            return switch (type_id) {
                types.primitives.v2bool_id => "v2bool",
                types.primitives.v4bool_id => "v4bool",
                types.primitives.v8bool_id => "v8bool",
                types.primitives.v16bool_id => "v16bool",
                types.primitives.v32bool_id => "v32bool",
                types.primitives.v4f32_id => "v4f32",
                types.primitives.v2f64_id => "v2f64",
                types.primitives.v4i32_id => "v4i32",
                types.primitives.v8i16_id => "v8i16",
                types.primitives.v16i8_id => "v16i8",
                types.primitives.v8f32_id => "v8f32",
                types.primitives.v4f64_id => "v4f64",
                types.primitives.v8i32_id => "v8i32",
                types.primitives.v16i16_id => "v16i16",
                types.primitives.v32i8_id => "v32i8",
                else => "<simd>",
            };
        }

        const simd = self.type_pool.getSimd(type_id) orelse return "<simd>";
        return switch (simd.elem_kind) {
            .bool => switch (simd.lanes) {
                2 => "v2bool",
                4 => "v4bool",
                8 => "v8bool",
                16 => "v16bool",
                32 => "v32bool",
                else => "<simd>",
            },
            .float => switch (simd.lanes) {
                2 => "v2f64",
                4 => if (simd.elem_bits == 32) "v4f32" else "v4f64",
                8 => "v8f32",
                else => "<simd>",
            },
            .int => switch (simd.lanes) {
                4 => "v4i32",
                8 => if (simd.elem_bits == 16) "v8i16" else "v8i32",
                16 => if (simd.elem_bits == 8) "v16i8" else "v16i16",
                32 => "v32i8",
                else => "<simd>",
            },
        };
    }

    fn simdCType(self: *const LoweringContext, type_id: TypeId) []const u8 {
        _ = self;
        return switch (type_id) {
            types.primitives.v2bool_id => "run_simd_v2bool_t",
            types.primitives.v4bool_id => "run_simd_v4bool_t",
            types.primitives.v8bool_id => "run_simd_v8bool_t",
            types.primitives.v16bool_id => "run_simd_v16bool_t",
            types.primitives.v32bool_id => "run_simd_v32bool_t",
            types.primitives.v4f32_id => "run_simd_v4f32_t",
            types.primitives.v2f64_id => "run_simd_v2f64_t",
            types.primitives.v4i32_id => "run_simd_v4i32_t",
            types.primitives.v8i16_id => "run_simd_v8i16_t",
            types.primitives.v16i8_id => "run_simd_v16i8_t",
            types.primitives.v8f32_id => "run_simd_v8f32_t",
            types.primitives.v4f64_id => "run_simd_v4f64_t",
            types.primitives.v8i32_id => "run_simd_v8i32_t",
            types.primitives.v16i16_id => "run_simd_v16i16_t",
            types.primitives.v32i8_id => "run_simd_v32i8_t",
            else => "run_simd_v4f32_t",
        };
    }

    fn cTypeForTypeId(self: *const LoweringContext, type_id: TypeId) []const u8 {
        if (type_id == types.null_type or type_id == types.primitives.void_id) return "void";

        if (type_id < types.primitives.count) {
            return switch (type_id) {
                types.primitives.bool_id => "bool",
                types.primitives.int_id, types.primitives.i64_id => "int64_t",
                types.primitives.uint_id, types.primitives.u64_id => "uint64_t",
                types.primitives.i32_id => "int32_t",
                types.primitives.u32_id => "uint32_t",
                types.primitives.byte_id => "uint8_t",
                types.primitives.i8_id => "int8_t",
                types.primitives.i16_id => "int16_t",
                types.primitives.f32_id => "float",
                types.primitives.f64_id => "double",
                types.primitives.string_id => "run_string_t",
                types.primitives.any_id => "run_any_t",
                types.primitives.v2bool_id,
                types.primitives.v4bool_id,
                types.primitives.v8bool_id,
                types.primitives.v16bool_id,
                types.primitives.v32bool_id,
                types.primitives.v4f32_id,
                types.primitives.v2f64_id,
                types.primitives.v4i32_id,
                types.primitives.v8i16_id,
                types.primitives.v16i8_id,
                types.primitives.v8f32_id,
                types.primitives.v4f64_id,
                types.primitives.v8i32_id,
                types.primitives.v16i16_id,
                types.primitives.v32i8_id,
                => self.simdCType(type_id),
                else => "int64_t",
            };
        }

        return switch (self.type_pool.get(type_id)) {
            .ptr_type => "run_gen_ref_t",
            .chan_type => "run_chan_t*",
            .map_type => "run_map_t*",
            .simd_type => self.simdCType(type_id),
            .newtype => |newtype| self.cTypeForTypeId(newtype.underlying),
            else => "int64_t",
        };
    }

    fn cTypeForNode(self: *const LoweringContext, node_idx: NodeIndex) []const u8 {
        const type_id = self.typeOfNode(node_idx);
        if (type_id == types.null_type) return "int64_t";
        return self.cTypeForTypeId(type_id);
    }

    fn alignmentForTypeId(self: *const LoweringContext, type_id: TypeId) u32 {
        return self.type_pool.simdAlignment(type_id) orelse 0;
    }

    fn alignmentForNode(self: *const LoweringContext, node_idx: NodeIndex) u32 {
        return self.alignmentForTypeId(self.typeOfNode(node_idx));
    }

    fn typeNameForTypeId(self: *const LoweringContext, type_id: TypeId) []const u8 {
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
                types.primitives.any_id => "any",
                types.primitives.i8_id => "i8",
                types.primitives.i16_id => "i16",
                else => self.simdTypeSuffix(type_id),
            };
        }
        return switch (self.type_pool.get(type_id)) {
            .ptr_type => "ptr",
            .chan_type => "chan",
            .map_type => "map",
            .simd_type => self.simdTypeSuffix(type_id),
            .newtype => |newtype| newtype.name,
            .struct_type => |st| st.name,
            .interface_type => |it| it.name,
            .sum_type => |st| st.name,
            else => "value",
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
        self.var_lookup.deinit(self.allocator);
        self.var_shadow_stack.deinit(self.allocator);
        self.var_shadow_scope_stack.deinit(self.allocator);
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
        self.setSrcLocFromNode(node_idx);
        const extra = self.tree.extra_data.items;

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

        // Record debug info for function name demangling
        try self.module.func_debug_infos.append(self.allocator, .{
            .mangled_name = mangled,
            .original_name = name,
            .source_byte_offset = self.tokens[fn_tok].loc.start,
        });

        const func_id = try self.module.addFunction(self.allocator, mangled);
        self.current_func = self.module.getFunction(func_id);
        self.current_func.?.return_type_name = "void";
        const params_start = node.data.lhs;
        var param_count: u32 = 0;
        while (params_start + param_count < extra.len) : (param_count += 1) {
            if (extra[params_start + param_count] == param_count) break;
        }
        const param_nodes = extra[params_start .. params_start + param_count];
        const fn_type_id = self.typeOfNode(node_idx);
        var param_refs: [64]ir.Ref = [_]ir.Ref{ir.null_ref} ** 64;
        var param_type_ids: [64]TypeId = [_]TypeId{types.null_type} ** 64;
        if (fn_type_id != types.null_type) {
            switch (self.type_pool.get(fn_type_id)) {
                .fn_type => |fn_type| {
                    self.current_func.?.return_type_name = self.cTypeForTypeId(fn_type.return_type);
                    for (param_nodes, 0..) |param_node, i| {
                        if (param_node == null_node or i >= fn_type.params.len or i >= param_refs.len) continue;
                        const param_name = self.tokenSlice(self.tree.nodes.items[param_node].main_token);
                        const param_type_id = fn_type.params[i];
                        const param_c_type = self.cTypeForTypeId(param_type_id);
                        const param_c_name = try std.fmt.allocPrint(self.allocator, "_param_{s}", .{param_name});
                        try self.module.owned_strings.append(self.allocator, param_c_name);
                        param_refs[i] = try self.current_func.?.addParam(self.allocator, param_c_name, param_c_type);
                        param_type_ids[i] = param_type_id;
                    }
                },
                else => {},
            }
        }

        const block_id = try self.current_func.?.addBlock(self.allocator);
        self.current_block = self.current_func.?.getBlock(block_id);

        try self.pushScope();
        for (param_nodes, 0..) |param_node, i| {
            if (param_node == null_node or i >= param_refs.len or param_refs[i] == ir.null_ref) continue;
            const param_name = self.tokenSlice(self.tree.nodes.items[param_node].main_token);
            _ = try self.defineVar(param_name, self.cTypeForTypeId(param_type_ids[i]), self.alignmentForTypeId(param_type_ids[i]), param_refs[i]);
        }

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
        self.setSrcLocFromNode(node_idx);
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
            .run_stmt => try self.lowerRunStmt(node_idx),
            .chan_send => {
                // ch <- val at statement level (not wrapped in expr_stmt)
                const ch_ref = try self.lowerExpr(node.data.lhs);
                const val_ref = try self.lowerExpr(node.data.rhs);
                try self.emit(ir.makeInst(.chan_send, 0, ch_ref, val_ref));
            },
            .break_stmt, .continue_stmt => {},
            else => {},
        }
    }

    fn lowerVarDecl(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const name_tok = node.main_token + 1;
        const name = self.tokenSlice(name_tok);
        const c_type = self.cTypeForNode(node_idx);
        const alignment = self.alignmentForNode(node_idx);

        if (node.data.rhs != null_node) {
            const val = try self.lowerExpr(node.data.rhs);
            const local_idx = try self.defineVar(name, c_type, alignment, val);

            // Track ownership for alloc expressions
            if (self.tree.nodes.items[node.data.rhs].tag == .alloc_expr) {
                try self.owned_stack.append(self.allocator, .{
                    .name = name,
                    .local_idx = local_idx,
                    .is_moved = false,
                });
            }
        } else {
            _ = try self.defineVar(name, c_type, alignment, ir.null_ref);
        }
    }

    fn lowerShortVarDecl(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        if (node.data.lhs != null_node) {
            const lhs_node = self.tree.nodes.items[node.data.lhs];
            if (lhs_node.tag == .ident) {
                const name = self.tokenSlice(lhs_node.main_token);
                const c_type = self.cTypeForNode(node_idx);
                const alignment = self.alignmentForNode(node_idx);
                if (node.data.rhs != null_node) {
                    const val = try self.lowerExpr(node.data.rhs);
                    const local_idx = try self.defineVar(name, c_type, alignment, val);

                    // Track ownership for alloc expressions
                    if (self.tree.nodes.items[node.data.rhs].tag == .alloc_expr) {
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

    fn lowerAssign(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        if (node.data.lhs != null_node and self.tree.nodes.items[node.data.lhs].tag == .index_access) {
            try self.lowerSimdLaneAssign(node.data.lhs, node.data.rhs);
            return;
        }

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
                const processed = self.processEscapes(text) catch text;
                const str_idx = try self.module.addStringConstant(self.allocator, processed);
                const r = self.allocRef();
                try self.emit(ir.makeInst(.const_string, r, str_idx, 0));
                return r;
            },
            .float_literal => {
                const text = self.tokenSlice(node.main_token);
                // Store float text as a string constant so codegen can emit it directly
                const str_idx = try self.module.addStringConstant(self.allocator, text);
                const r = self.allocRef();
                try self.emit(ir.makeInst(.const_float, r, str_idx, 0));
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
                if (self.type_pool.isSimd(self.typeOfNode(node.data.lhs)) or self.type_pool.isSimd(self.typeOfNode(node_idx))) {
                    return try self.lowerSimdBinaryOp(node_idx);
                }
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
            .simd_literal => return try self.lowerSimdLiteral(node_idx),
            .alloc_expr => {
                // alloc(Type, capacity?) — check if this is a channel allocation
                const type_node_idx = node.data.lhs;
                const extra_start = node.data.rhs;

                // Channel allocation: alloc(chan[T]) or alloc(chan[T], capacity)
                if (type_node_idx != null_node and self.tree.nodes.items[type_node_idx].tag == .type_chan) {
                    // Element size — default to 8 bytes (int64_t)
                    const elem_size_ref = self.allocRef();
                    try self.emit(ir.makeInst(.const_int, elem_size_ref, 8, 0));

                    // Capacity from extra_data (0 for unbuffered)
                    const cap_node = self.tree.extra_data.items[extra_start];
                    var cap_ref: ir.Ref = undefined;
                    if (cap_node != null_node) {
                        cap_ref = try self.lowerExpr(cap_node);
                    } else {
                        cap_ref = self.allocRef();
                        try self.emit(ir.makeInst(.const_int, cap_ref, 0, 0));
                    }

                    const ch_ref = self.allocRef();
                    try self.emit(ir.makeInst(.chan_new, ch_ref, elem_size_ref, cap_ref));
                    return ch_ref;
                }

                // Default: generational allocation
                const alloc_type = self.typeOfNode(node_idx);
                const pointee_type = self.type_pool.unwrapPointer(alloc_type) orelse self.resolveTypeNode(type_node_idx);
                const alloc_size = if (pointee_type != types.null_type) self.sizeOfTypeId(pointee_type) else 8;
                const alloc_alignment = if (pointee_type != types.null_type) self.alignOfTypeId(pointee_type) else 0;
                const size_ref = self.allocRef();
                try self.emit(ir.makeInst(.const_int, size_ref, alloc_size, 0));
                const ptr_ref = if (alloc_alignment > 8) blk: {
                    const align_ref = self.allocRef();
                    try self.emit(ir.makeInst(.const_int, align_ref, alloc_alignment, 0));
                    break :blk try self.emitTypedCall("run_gen_alloc_aligned", &.{ size_ref, align_ref }, "void*", false);
                } else blk: {
                    const raw_ref = self.allocRef();
                    try self.emit(ir.makeInst(.gen_alloc, raw_ref, size_ref, 0));
                    break :blk raw_ref;
                };
                const ref_result = self.allocRef();
                try self.emit(ir.makeInst(.gen_ref_create, ref_result, ptr_ref, 0));
                return ref_result;
            },
            .index_access => {
                if (self.type_pool.isSimd(self.typeOfNode(node.data.lhs))) {
                    return try self.lowerSimdLaneAccess(node_idx);
                }
                return ir.null_ref;
            },
            .addr_of, .addr_of_const => {
                // &ident/@ident should capture the local's storage, not its loaded value.
                const operand_node = node.data.lhs;
                const ptr_ref = blk: {
                    if (operand_node != null_node and self.tree.nodes.items[operand_node].tag == .ident) {
                        const name = self.tokenSlice(self.tree.nodes.items[operand_node].main_token);
                        if (self.lookupLocalIdx(name)) |local_idx| {
                            const local_ptr = self.allocRef();
                            try self.emit(ir.makeInst(.local_addr, local_ptr, local_idx, 0));
                            break :blk local_ptr;
                        }
                    }

                    break :blk try self.lowerExpr(operand_node);
                };
                const ref_result = self.allocRef();
                try self.emit(ir.makeInst(.gen_ref_create, ref_result, ptr_ref, 0));
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
            .chan_send => {
                const ch_ref = try self.lowerExpr(node.data.lhs);
                const val_ref = try self.lowerExpr(node.data.rhs);
                try self.emit(ir.makeInst(.chan_send, 0, ch_ref, val_ref));
                return ir.null_ref;
            },
            .chan_recv => {
                const ch_ref = try self.lowerExpr(node.data.lhs);
                const r = self.allocRef();
                try self.emit(ir.makeInst(.chan_recv, r, ch_ref, 0));
                return r;
            },
            .if_expr => return try self.lowerIfExpr(node_idx),
            .asm_expr => return try self.lowerAsmExpr(node_idx),
            else => return ir.null_ref,
        }
    }

    fn lowerAsmExpr(self: *LoweringContext, node_idx: NodeIndex) LowerError!ir.Ref {
        const node = self.tree.nodes.items[node_idx];
        const extra = self.tree.extra_data.items;
        const extra_start = node.data.lhs;
        const body_node_idx = node.data.rhs;

        // Parse extra_data layout: [input_count, input1..N, clobber_count, clobber1..M, ret_type_node]
        const input_count = extra[extra_start];

        // Lower input expressions and collect register bindings
        var inputs: std.ArrayList(ir.AsmOperand) = .empty;
        defer inputs.deinit(self.allocator);

        var i: u32 = 0;
        while (i < input_count) : (i += 1) {
            const input_node_idx = extra[extra_start + 1 + i];
            const input_node = self.tree.nodes.items[input_node_idx];
            // input_node.tag == .asm_input: lhs = expression, main_token = register name
            const expr_ref = try self.lowerExpr(input_node.data.lhs);
            const reg_name = self.tokenSlice(input_node.main_token);
            try inputs.append(self.allocator, .{ .register = reg_name, .ref = expr_ref });
        }

        // Clobbers
        const clobber_offset = extra_start + 1 + input_count;
        const clobber_count = extra[clobber_offset];
        var clobbers: std.ArrayList([]const u8) = .empty;
        defer clobbers.deinit(self.allocator);

        var j: u32 = 0;
        while (j < clobber_count) : (j += 1) {
            const clobber_node_idx = extra[clobber_offset + 1 + j];
            const clobber_node = self.tree.nodes.items[clobber_node_idx];
            const clobber_name = self.tokenSlice(clobber_node.main_token);
            try clobbers.append(self.allocator, clobber_name);
        }

        // Return type
        const ret_type_offset = clobber_offset + 1 + clobber_count;
        const ret_type_node = extra[ret_type_offset];
        const return_type: []const u8 = if (ret_type_node != null_node) blk: {
            const rt_node = self.tree.nodes.items[ret_type_node];
            const type_name = self.tokenSlice(rt_node.main_token);
            // Map Run types to C types
            break :blk if (std.mem.eql(u8, type_name, "u64") or std.mem.eql(u8, type_name, "i64") or std.mem.eql(u8, type_name, "int"))
                "int64_t"
            else if (std.mem.eql(u8, type_name, "u32") or std.mem.eql(u8, type_name, "i32"))
                "int32_t"
            else if (std.mem.eql(u8, type_name, "f32"))
                "float"
            else if (std.mem.eql(u8, type_name, "f64") or std.mem.eql(u8, type_name, "float"))
                "double"
            else if (std.mem.eql(u8, type_name, "bool"))
                "bool"
            else
                "int64_t";
        } else "void";

        // Extract assembly body text from body node
        var template: []const u8 = "";
        var platform_sections: std.ArrayList(ir.AsmInfo.PlatformSection) = .empty;
        defer platform_sections.deinit(self.allocator);

        if (body_node_idx != null_node) {
            const body_node = self.tree.nodes.items[body_node_idx];
            if (body_node.tag == .asm_body) {
                const body_start = body_node.data.lhs;
                const body_count = body_node.data.rhs;
                var k: u32 = 0;
                while (k < body_count) : (k += 1) {
                    const item_idx = extra[body_start + k];
                    const item = self.tree.nodes.items[item_idx];
                    if (item.tag == .asm_simple_body) {
                        const src_start = item.data.lhs;
                        const src_end = item.data.rhs;
                        if (src_start < src_end and src_end <= self.tree.source.len) {
                            template = self.tree.source[src_start..src_end];
                        }
                    } else if (item.tag == .asm_platform) {
                        // Platform conditional: main_token = hash, main_token+1 = platform name
                        const plat_name = self.tokenSlice(item.main_token + 1);
                        const src_start = item.data.lhs;
                        const src_end = item.data.rhs;
                        var plat_template: []const u8 = "";
                        if (src_start < src_end and src_end <= self.tree.source.len) {
                            plat_template = self.tree.source[src_start..src_end];
                        }
                        try platform_sections.append(self.allocator, .{
                            .platform = plat_name,
                            .template = plat_template,
                        });
                    }
                }
            }
        }

        // Clone lists for AsmInfo (it needs to own the data)
        var info_inputs: std.ArrayList(ir.AsmOperand) = .empty;
        for (inputs.items) |inp| {
            try info_inputs.append(self.allocator, inp);
        }
        var info_clobbers: std.ArrayList([]const u8) = .empty;
        for (clobbers.items) |c| {
            try info_clobbers.append(self.allocator, c);
        }
        var info_platforms: std.ArrayList(ir.AsmInfo.PlatformSection) = .empty;
        for (platform_sections.items) |p| {
            try info_platforms.append(self.allocator, p);
        }

        const asm_info = ir.AsmInfo{
            .template = template,
            .inputs = info_inputs,
            .clobbers = info_clobbers,
            .return_type = return_type,
            .platform_sections = info_platforms,
        };
        const asm_idx = try self.module.addAsmInfo(self.allocator, asm_info);

        const r = self.allocRef();
        try self.emit(ir.makeInst(.inline_asm, r, asm_idx, 0));
        return r;
    }

    fn lowerIfExpr(self: *LoweringContext, node_idx: NodeIndex) LowerError!ir.Ref {
        const node = self.tree.nodes.items[node_idx];
        const extra = self.tree.extra_data.items;
        const cond_ref = try self.lowerExpr(node.data.lhs);

        const then_node = extra[node.data.rhs];
        const else_node = extra[node.data.rhs + 1];

        const func = self.current_func orelse return ir.null_ref;
        const result_type = self.typeOfNode(node_idx);
        const result_c_type = if (result_type == types.null_type) "int64_t" else self.cTypeForTypeId(result_type);
        const result_alignment = self.alignmentForTypeId(result_type);

        // Use a local variable for the result so it survives across blocks
        const result_name = try std.fmt.allocPrint(self.allocator, "_if_result_{d}", .{func.next_ref});
        try self.module.owned_strings.append(self.allocator, result_name);
        const result_idx = try self.module.addLocalInfoAligned(self.allocator, result_name, result_c_type, result_alignment);

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

    fn findTrailingCount(self: *const LoweringContext, start: u32) u32 {
        const extra = self.tree.extra_data.items;
        var n: u32 = 0;
        while (start + n < extra.len) : (n += 1) {
            if (extra[start + n] == n) return n;
        }
        return 0;
    }

    fn resolveTypeNode(self: *LoweringContext, node_idx: NodeIndex) TypeId {
        if (node_idx == null_node) return types.null_type;
        const node = self.tree.nodes.items[node_idx];
        return switch (node.tag) {
            .type_name, .ident => blk: {
                const name = self.tokenSlice(node.main_token);
                if (TypePool.lookupPrimitive(name)) |prim| break :blk prim;
                const typed = self.typeOfNode(node_idx);
                break :blk typed;
            },
            .type_ptr => blk: {
                const inner = self.resolveTypeNode(node.data.lhs);
                if (inner == types.null_type) break :blk types.null_type;
                break :blk @constCast(self.type_pool).intern(self.allocator, .{ .ptr_type = .{
                    .pointee = inner,
                    .is_const = false,
                } }) catch types.null_type;
            },
            .type_const_ptr => blk: {
                const inner = self.resolveTypeNode(node.data.lhs);
                if (inner == types.null_type) break :blk types.null_type;
                break :blk @constCast(self.type_pool).intern(self.allocator, .{ .ptr_type = .{
                    .pointee = inner,
                    .is_const = true,
                } }) catch types.null_type;
            },
            .type_nullable => blk: {
                const inner = self.resolveTypeNode(node.data.lhs);
                if (inner == types.null_type) break :blk types.null_type;
                break :blk @constCast(self.type_pool).intern(self.allocator, .{ .nullable_type = .{
                    .inner = inner,
                } }) catch types.null_type;
            },
            .type_slice => blk: {
                const inner = self.resolveTypeNode(node.data.lhs);
                if (inner == types.null_type) break :blk types.null_type;
                break :blk @constCast(self.type_pool).intern(self.allocator, .{ .slice_type = .{
                    .elem = inner,
                } }) catch types.null_type;
            },
            .type_chan => blk: {
                const inner = self.resolveTypeNode(node.data.lhs);
                if (inner == types.null_type) break :blk types.null_type;
                break :blk @constCast(self.type_pool).intern(self.allocator, .{ .chan_type = .{
                    .elem = inner,
                } }) catch types.null_type;
            },
            .type_map => blk: {
                const extra = self.tree.extra_data.items;
                const key = self.resolveTypeNode(extra[node.data.lhs]);
                const value = self.resolveTypeNode(extra[node.data.lhs + 1]);
                if (key == types.null_type or value == types.null_type) break :blk types.null_type;
                break :blk @constCast(self.type_pool).intern(self.allocator, .{ .map_type = .{
                    .key = key,
                    .value = value,
                } }) catch types.null_type;
            },
            else => self.typeOfNode(node_idx),
        };
    }

    fn resolveTypeArgument(self: *LoweringContext, node_idx: NodeIndex) TypeId {
        const node = self.tree.nodes.items[node_idx];
        return switch (node.tag) {
            .type_name, .ident, .type_ptr, .type_const_ptr, .type_nullable, .type_slice, .type_chan, .type_map => self.resolveTypeNode(node_idx),
            else => self.typeOfNode(node_idx),
        };
    }

    fn sizeOfTypeId(self: *const LoweringContext, type_id: TypeId) u32 {
        if (type_id == types.null_type or type_id == types.primitives.void_id) return 0;
        if (self.type_pool.isSimd(type_id)) {
            const simd = self.type_pool.getSimd(type_id).?;
            return (@as(u32, simd.lanes) * @as(u32, simd.elem_bits) + 7) / 8;
        }
        if (type_id < types.primitives.count) {
            return switch (type_id) {
                types.primitives.bool_id,
                types.primitives.byte_id,
                types.primitives.i8_id,
                => 1,
                types.primitives.i16_id => 2,
                types.primitives.i32_id,
                types.primitives.u32_id,
                types.primitives.f32_id,
                => 4,
                types.primitives.int_id,
                types.primitives.uint_id,
                types.primitives.i64_id,
                types.primitives.u64_id,
                types.primitives.f64_id,
                => 8,
                types.primitives.string_id,
                => 16,
                else => 8,
            };
        }
        return switch (self.type_pool.get(type_id)) {
            .ptr_type, .chan_type, .map_type => 8,
            .newtype => |newtype| self.sizeOfTypeId(newtype.underlying),
            else => 8,
        };
    }

    fn alignOfTypeId(self: *const LoweringContext, type_id: TypeId) u32 {
        if (self.type_pool.simdAlignment(type_id)) |alignment| return alignment;
        if (type_id == types.primitives.string_id) return 8;
        return @max(@as(u32, 1), @min(self.sizeOfTypeId(type_id), @as(u32, 8)));
    }

    fn builtinCallName(self: *LoweringContext, callee_idx: NodeIndex) ?[]const u8 {
        if (callee_idx == null_node) return null;
        const callee = self.tree.nodes.items[callee_idx];
        if (callee.tag != .field_access) return null;
        const object_node = callee.data.lhs;
        if (object_node == null_node or self.tree.nodes.items[object_node].tag != .ident) return null;

        const package_name = self.tokenSlice(self.tree.nodes.items[object_node].main_token);
        const member_name = self.tokenSlice(callee.main_token + 1);

        if (std.mem.eql(u8, package_name, "unsafe") and std.mem.eql(u8, member_name, "alignof")) return "unsafe.alignof";

        if (std.mem.eql(u8, package_name, "numa")) {
            if (std.mem.eql(u8, member_name, "node_count")) return "numa.node_count";
            if (std.mem.eql(u8, member_name, "current_node")) return "numa.current_node";
            if (std.mem.eql(u8, member_name, "distance")) return "numa.distance";
            if (std.mem.eql(u8, member_name, "pin")) return "numa.pin";
            if (std.mem.eql(u8, member_name, "memory_on_node")) return "numa.memory_on_node";
            return null;
        }

        if (!std.mem.eql(u8, package_name, "simd")) return null;
        if (std.mem.eql(u8, member_name, "hadd")) return "simd.hadd";
        if (std.mem.eql(u8, member_name, "dot")) return "simd.dot";
        if (std.mem.eql(u8, member_name, "shuffle")) return "simd.shuffle";
        if (std.mem.eql(u8, member_name, "min")) return "simd.min";
        if (std.mem.eql(u8, member_name, "max")) return "simd.max";
        if (std.mem.eql(u8, member_name, "select")) return "simd.select";
        if (std.mem.eql(u8, member_name, "load")) return "simd.load";
        if (std.mem.eql(u8, member_name, "store")) return "simd.store";
        if (std.mem.eql(u8, member_name, "load_unaligned")) return "simd.load_unaligned";
        if (std.mem.eql(u8, member_name, "width")) return "simd.width";
        if (std.mem.eql(u8, member_name, "sqrt")) return "simd.sqrt";
        if (std.mem.eql(u8, member_name, "abs")) return "simd.abs";
        if (std.mem.eql(u8, member_name, "floor")) return "simd.floor";
        if (std.mem.eql(u8, member_name, "ceil")) return "simd.ceil";
        if (std.mem.eql(u8, member_name, "round")) return "simd.round";
        if (std.mem.eql(u8, member_name, "fma")) return "simd.fma";
        if (std.mem.eql(u8, member_name, "clamp")) return "simd.clamp";
        if (std.mem.eql(u8, member_name, "broadcast")) return "simd.broadcast";
        if (std.mem.eql(u8, member_name, "i32_to_f32")) return "simd.i32_to_f32";
        if (std.mem.eql(u8, member_name, "f32_to_i32")) return "simd.f32_to_i32";
        return null;
    }

    fn targetNameForCall(self: *LoweringContext, callee_name: []const u8) LowerError![]const u8 {
        const builtin_target = mapBuiltinCall(callee_name);
        if (!std.mem.eql(u8, builtin_target, callee_name)) return builtin_target;
        if (std.mem.indexOfScalar(u8, callee_name, '.')) |_| return callee_name;
        if (std.mem.startsWith(u8, callee_name, "run_")) return callee_name;

        const mangled = try std.fmt.allocPrint(self.allocator, "run_main__{s}", .{callee_name});
        try self.module.owned_strings.append(self.allocator, mangled);
        return mangled;
    }

    fn emitTypedCall(self: *LoweringContext, target_name: []const u8, arg_refs: []const ir.Ref, return_type_name: []const u8, is_variadic: bool) LowerError!ir.Ref {
        const call_idx = if (is_variadic)
            try self.module.addTypedVariadicCallInfo(self.allocator, target_name, arg_refs, return_type_name)
        else
            try self.module.addTypedCallInfo(self.allocator, target_name, arg_refs, return_type_name);

        const is_void = std.mem.eql(u8, return_type_name, "void");
        const result = if (is_void) ir.null_ref else self.allocRef();
        try self.emit(ir.makeInst(.call, result, call_idx, 0));
        return result;
    }

    fn lowerSimdBinaryOp(self: *LoweringContext, node_idx: NodeIndex) LowerError!ir.Ref {
        const node = self.tree.nodes.items[node_idx];
        const lhs_type = self.typeOfNode(node.data.lhs);
        const result_type = self.typeOfNode(node_idx);
        const helper_suffix = self.simdTypeSuffix(lhs_type);
        const helper_op = switch (self.tokens[node.main_token].tag) {
            .plus => "add",
            .minus => "sub",
            .star => "mul",
            .slash => "div",
            .equal_equal => "eq",
            .bang_equal => "ne",
            .less => "lt",
            .less_equal => "le",
            .greater => "gt",
            .greater_equal => "ge",
            else => "nop",
        };
        const helper_name = try std.fmt.allocPrint(self.allocator, "run_simd_{s}_{s}", .{ helper_suffix, helper_op });
        try self.module.owned_strings.append(self.allocator, helper_name);

        const lhs_ref = try self.lowerExpr(node.data.lhs);
        const rhs_ref = try self.lowerExpr(node.data.rhs);
        return self.emitTypedCall(helper_name, &.{ lhs_ref, rhs_ref }, self.cTypeForTypeId(result_type), false);
    }

    fn lowerSimdLiteral(self: *LoweringContext, node_idx: NodeIndex) LowerError!ir.Ref {
        const node = self.tree.nodes.items[node_idx];
        const type_id = self.resolveTypeNode(node.data.lhs);
        const lanes_start = node.data.rhs;
        const lane_count = self.findTrailingCount(lanes_start);
        const lane_nodes = self.tree.extra_data.items[lanes_start .. lanes_start + lane_count];

        var arg_refs: std.ArrayList(ir.Ref) = .empty;
        defer arg_refs.deinit(self.allocator);
        for (lane_nodes) |lane_node| {
            try arg_refs.append(self.allocator, try self.lowerExpr(lane_node));
        }

        const helper_name = try std.fmt.allocPrint(self.allocator, "run_simd_{s}_make", .{self.simdTypeSuffix(type_id)});
        try self.module.owned_strings.append(self.allocator, helper_name);
        return self.emitTypedCall(helper_name, arg_refs.items, self.cTypeForTypeId(type_id), false);
    }

    fn lowerSimdLaneAccess(self: *LoweringContext, node_idx: NodeIndex) LowerError!ir.Ref {
        const node = self.tree.nodes.items[node_idx];
        const base_type = self.typeOfNode(node.data.lhs);
        const helper_name = try std.fmt.allocPrint(self.allocator, "run_simd_{s}_get_lane", .{self.simdTypeSuffix(base_type)});
        try self.module.owned_strings.append(self.allocator, helper_name);

        const base_ref = try self.lowerExpr(node.data.lhs);
        const index_ref = try self.lowerExpr(node.data.rhs);
        return self.emitTypedCall(helper_name, &.{ base_ref, index_ref }, self.cTypeForTypeId(self.typeOfNode(node_idx)), false);
    }

    fn lowerSimdLaneAssign(self: *LoweringContext, lhs_idx: NodeIndex, rhs_idx: NodeIndex) LowerError!void {
        const lhs = self.tree.nodes.items[lhs_idx];
        const base_node = lhs.data.lhs;
        if (base_node == null_node or self.tree.nodes.items[base_node].tag != .ident) return;

        const base_name = self.tokenSlice(self.tree.nodes.items[base_node].main_token);
        const base_type = self.typeOfNode(base_node);
        const helper_name = try std.fmt.allocPrint(self.allocator, "run_simd_{s}_set_lane", .{self.simdTypeSuffix(base_type)});
        try self.module.owned_strings.append(self.allocator, helper_name);

        const base_ref = try self.getVar(base_name);
        const index_ref = try self.lowerExpr(lhs.data.rhs);
        const value_ref = try self.lowerExpr(rhs_idx);
        const updated_ref = try self.emitTypedCall(helper_name, &.{ base_ref, index_ref, value_ref }, self.cTypeForTypeId(base_type), false);
        try self.setVar(base_name, updated_ref);
    }

    fn lowerBuiltinCall(self: *LoweringContext, builtin_name: []const u8, node_idx: NodeIndex, arg_nodes: []const NodeIndex) LowerError!ir.Ref {
        if (std.mem.eql(u8, builtin_name, "unsafe.alignof")) {
            const type_id = if (arg_nodes.len > 0) self.resolveTypeArgument(arg_nodes[0]) else types.null_type;
            const alignment = self.alignOfTypeId(type_id);
            const result = self.allocRef();
            try self.emit(ir.makeInst(.const_int, result, alignment, 0));
            return result;
        }

        if (std.mem.eql(u8, builtin_name, "simd.width")) {
            return self.emitTypedCall("run_simd_width", &.{}, "int64_t", false);
        }

        // NUMA builtins
        if (std.mem.startsWith(u8, builtin_name, "numa.")) {
            var numa_arg_refs: std.ArrayList(ir.Ref) = .empty;
            defer numa_arg_refs.deinit(self.allocator);
            for (arg_nodes) |arg_node| {
                try numa_arg_refs.append(self.allocator, try self.lowerExpr(arg_node));
            }
            const target = mapBuiltinCall(builtin_name);
            if (std.mem.eql(u8, builtin_name, "numa.pin")) {
                return self.emitTypedCall(target, numa_arg_refs.items, "void", false);
            }
            // node_count, current_node return uint32_t; distance returns uint32_t; memory_on_node returns uint64_t
            const ret_type = if (std.mem.eql(u8, builtin_name, "numa.memory_on_node")) "uint64_t" else "uint32_t";
            return self.emitTypedCall(target, numa_arg_refs.items, ret_type, false);
        }

        // Broadcast: first arg is type, second is scalar value
        if (std.mem.eql(u8, builtin_name, "simd.broadcast")) {
            const type_id = if (arg_nodes.len > 0) self.resolveTypeArgument(arg_nodes[0]) else types.null_type;
            const scalar_ref = if (arg_nodes.len > 1) try self.lowerExpr(arg_nodes[1]) else ir.null_ref;
            const suffix = self.simdTypeSuffix(type_id);
            const helper_name = try std.fmt.allocPrint(self.allocator, "run_simd_{s}_broadcast", .{suffix});
            try self.module.owned_strings.append(self.allocator, helper_name);
            return self.emitTypedCall(helper_name, &.{scalar_ref}, self.cTypeForTypeId(type_id), false);
        }

        // Conversions: i32_to_f32, f32_to_i32
        if (std.mem.eql(u8, builtin_name, "simd.i32_to_f32") or std.mem.eql(u8, builtin_name, "simd.f32_to_i32")) {
            const arg_ref = if (arg_nodes.len > 0) try self.lowerExpr(arg_nodes[0]) else ir.null_ref;
            const src_type = if (arg_nodes.len > 0) self.typeOfNode(arg_nodes[0]) else types.null_type;
            const dst_type = self.typeOfNode(node_idx);
            const src_suffix = self.simdTypeSuffix(src_type);
            const dst_suffix = self.simdTypeSuffix(dst_type);
            const helper_name = try std.fmt.allocPrint(self.allocator, "run_simd_{s}_to_{s}", .{ src_suffix, dst_suffix });
            try self.module.owned_strings.append(self.allocator, helper_name);
            return self.emitTypedCall(helper_name, &.{arg_ref}, self.cTypeForTypeId(dst_type), false);
        }

        var arg_refs: std.ArrayList(ir.Ref) = .empty;
        defer arg_refs.deinit(self.allocator);
        for (arg_nodes) |arg_node| {
            try arg_refs.append(self.allocator, try self.lowerExpr(arg_node));
        }

        const result_type = self.typeOfNode(node_idx);
        const helper_type = switch (builtin_name[5]) {
            'h' => self.typeOfNode(arg_nodes[0]),
            'd' => self.typeOfNode(arg_nodes[0]),
            'm' => self.typeOfNode(arg_nodes[0]),
            's' => if (std.mem.eql(u8, builtin_name, "simd.select")) result_type else self.typeOfNode(arg_nodes[0]),
            'l' => result_type,
            'a' => self.typeOfNode(arg_nodes[0]),
            'f' => self.typeOfNode(arg_nodes[0]),
            'c' => self.typeOfNode(arg_nodes[0]),
            'r' => self.typeOfNode(arg_nodes[0]),
            else => result_type,
        };

        const helper_name = blk: {
            if (std.mem.eql(u8, builtin_name, "simd.hadd")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_hadd", .{self.simdTypeSuffix(helper_type)});
            if (std.mem.eql(u8, builtin_name, "simd.dot")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_dot", .{self.simdTypeSuffix(helper_type)});
            if (std.mem.eql(u8, builtin_name, "simd.shuffle")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_shuffle", .{self.simdTypeSuffix(helper_type)});
            if (std.mem.eql(u8, builtin_name, "simd.min")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_min", .{self.simdTypeSuffix(helper_type)});
            if (std.mem.eql(u8, builtin_name, "simd.max")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_max", .{self.simdTypeSuffix(helper_type)});
            if (std.mem.eql(u8, builtin_name, "simd.select")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_select", .{self.simdTypeSuffix(helper_type)});
            if (std.mem.eql(u8, builtin_name, "simd.load")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_load", .{self.simdTypeSuffix(helper_type)});
            if (std.mem.eql(u8, builtin_name, "simd.load_unaligned")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_load_unaligned", .{self.simdTypeSuffix(helper_type)});
            if (std.mem.eql(u8, builtin_name, "simd.store")) {
                const ptr_type = if (arg_nodes.len > 0) self.typeOfNode(arg_nodes[0]) else types.null_type;
                const pointee = self.type_pool.unwrapPointer(ptr_type) orelse types.null_type;
                break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_store", .{self.simdTypeSuffix(pointee)});
            }
            if (std.mem.eql(u8, builtin_name, "simd.sqrt")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_sqrt", .{self.simdTypeSuffix(helper_type)});
            if (std.mem.eql(u8, builtin_name, "simd.abs")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_abs", .{self.simdTypeSuffix(helper_type)});
            if (std.mem.eql(u8, builtin_name, "simd.floor")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_floor", .{self.simdTypeSuffix(helper_type)});
            if (std.mem.eql(u8, builtin_name, "simd.ceil")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_ceil", .{self.simdTypeSuffix(helper_type)});
            if (std.mem.eql(u8, builtin_name, "simd.round")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_round", .{self.simdTypeSuffix(helper_type)});
            if (std.mem.eql(u8, builtin_name, "simd.fma")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_fma", .{self.simdTypeSuffix(helper_type)});
            if (std.mem.eql(u8, builtin_name, "simd.clamp")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_clamp", .{self.simdTypeSuffix(helper_type)});
            break :blk try std.fmt.allocPrint(self.allocator, "{s}", .{builtin_name});
        };
        try self.module.owned_strings.append(self.allocator, helper_name);

        const return_type_name = if (std.mem.eql(u8, builtin_name, "simd.store")) "void" else self.cTypeForTypeId(result_type);
        return self.emitTypedCall(helper_name, arg_refs.items, return_type_name, false);
    }

    fn lowerRunStmt(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const call_idx = node.data.lhs;
        if (call_idx == null_node) return;

        const call_node = self.tree.nodes.items[call_idx];
        if (call_node.tag != .call) return;

        // Get the target function name and mangle it
        const callee_name = self.resolveCalleeName(call_node.data.lhs);
        const target_name = try self.targetNameForCall(callee_name);

        // Lower arguments (same pattern as lowerCall)
        const args_start = call_node.data.rhs;
        var arg_refs: std.ArrayList(ir.Ref) = .empty;
        defer arg_refs.deinit(self.allocator);

        const n = self.findTrailingCount(args_start);
        for (self.tree.extra_data.items[args_start .. args_start + n]) |arg_node| {
            const arg_ref = try self.lowerExpr(arg_node);
            try arg_refs.append(self.allocator, arg_ref);
        }

        // Store spawn info in call_info so codegen can emit the function name as a symbol
        const spawn_info = try self.module.addTypedCallInfo(self.allocator, target_name, arg_refs.items, "void");

        // Check for NUMA node affinity (rhs != null_node means run(node: N) syntax)
        const node_expr_idx = node.data.rhs;
        if (node_expr_idx != null_node) {
            const node_ref = try self.lowerExpr(node_expr_idx);
            try self.emit(ir.makeInst(.spawn_on_node, 0, spawn_info, node_ref));
        } else {
            try self.emit(ir.makeInst(.spawn, 0, spawn_info, 0));
        }
    }

    fn lowerCall(self: *LoweringContext, node_idx: NodeIndex) LowerError!ir.Ref {
        const node = self.tree.nodes.items[node_idx];
        const callee_idx = node.data.lhs;
        const args_start = node.data.rhs;
        const arg_count = self.findTrailingCount(args_start);
        const arg_nodes = self.tree.extra_data.items[args_start .. args_start + arg_count];
        if (self.builtinCallName(callee_idx)) |builtin_name| {
            return try self.lowerBuiltinCall(builtin_name, node_idx, arg_nodes);
        }

        const callee_name = self.resolveCalleeName(callee_idx);
        const target_name = try self.targetNameForCall(callee_name);

        var arg_refs: std.ArrayList(ir.Ref) = .empty;
        defer arg_refs.deinit(self.allocator);
        for (arg_nodes) |arg_node| {
            const arg_ref = try self.lowerExpr(arg_node);
            try arg_refs.append(self.allocator, arg_ref);
        }

        var return_type_name = self.cTypeForNode(node_idx);
        if (self.typeOfNode(node_idx) == types.null_type) {
            if (isVoidCall(target_name)) {
                return_type_name = "void";
            } else if (std.mem.startsWith(u8, target_name, "run_fmt_sprint")) {
                return_type_name = "run_string_t";
            } else {
                return_type_name = "int64_t";
            }
        }
        return self.emitTypedCall(target_name, arg_refs.items, return_type_name, isVariadicFmtCall(target_name));
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
        return std.mem.eql(u8, name, "run_fmt_println_args") or
            std.mem.eql(u8, name, "run_fmt_print_args") or
            std.mem.eql(u8, name, "run_fmt_printf_args") or
            std.mem.eql(u8, name, "run_fmt_println") or
            std.mem.eql(u8, name, "run_fmt_print") or
            std.mem.eql(u8, name, "run_fmt_print_int") or
            std.mem.eql(u8, name, "run_fmt_print_float") or
            std.mem.eql(u8, name, "run_fmt_print_bool") or
            std.mem.eql(u8, name, "run_chan_close");
    }

    fn isVariadicFmtCall(name: []const u8) bool {
        return std.mem.eql(u8, name, "run_fmt_println_args") or
            std.mem.eql(u8, name, "run_fmt_print_args") or
            std.mem.eql(u8, name, "run_fmt_printf_args") or
            std.mem.eql(u8, name, "run_fmt_sprintf_args") or
            std.mem.eql(u8, name, "run_fmt_sprint_args") or
            std.mem.eql(u8, name, "run_fmt_sprintln_args");
    }

    fn mapBuiltinCall(name: []const u8) []const u8 {
        if (std.mem.eql(u8, name, "fmt.println")) return "run_fmt_println_args";
        if (std.mem.eql(u8, name, "fmt.print")) return "run_fmt_print_args";
        if (std.mem.eql(u8, name, "fmt.printf")) return "run_fmt_printf_args";
        if (std.mem.eql(u8, name, "fmt.sprintf")) return "run_fmt_sprintf_args";
        if (std.mem.eql(u8, name, "fmt.sprint")) return "run_fmt_sprint_args";
        if (std.mem.eql(u8, name, "fmt.sprintln")) return "run_fmt_sprintln_args";
        if (std.mem.eql(u8, name, "close")) return "run_chan_close";
        if (std.mem.eql(u8, name, "numa.node_count")) return "run_numa_node_count";
        if (std.mem.eql(u8, name, "numa.current_node")) return "run_numa_current_node";
        if (std.mem.eql(u8, name, "numa.distance")) return "run_numa_distance";
        if (std.mem.eql(u8, name, "numa.pin")) return "run_numa_pin";
        if (std.mem.eql(u8, name, "numa.memory_on_node")) return "run_numa_memory_on_node";
        return name;
    }

    fn emit(self: *LoweringContext, inst: ir.Inst) LowerError!void {
        if (self.current_block) |block| {
            var located = inst;
            if (located.src_loc.byte_offset == 0) {
                located.src_loc = self.current_src_loc;
            }
            try block.addInst(self.allocator, located);
        }
    }

    /// Set current source location from an AST node's main token.
    fn setSrcLocFromNode(self: *LoweringContext, node_idx: NodeIndex) void {
        if (node_idx == null_node) return;
        const node = self.tree.nodes.items[node_idx];
        if (node.main_token < self.tokens.len) {
            self.current_src_loc = .{
                .byte_offset = self.tokens[node.main_token].loc.start,
                .file_index = 0,
            };
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

    /// Process escape sequences in a string literal (e.g. \n → newline, \t → tab).
    fn processEscapes(self: *LoweringContext, text: []const u8) ![]const u8 {
        // Quick check: if no backslashes, return as-is
        if (std.mem.indexOf(u8, text, "\\") == null) return text;

        var buf = std.ArrayList(u8).empty;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\\' and i + 1 < text.len) {
                switch (text[i + 1]) {
                    'n' => try buf.append(self.allocator, '\n'),
                    't' => try buf.append(self.allocator, '\t'),
                    'r' => try buf.append(self.allocator, '\r'),
                    '\\' => try buf.append(self.allocator, '\\'),
                    '"' => try buf.append(self.allocator, '"'),
                    '0' => try buf.append(self.allocator, 0),
                    else => {
                        try buf.append(self.allocator, text[i]);
                        try buf.append(self.allocator, text[i + 1]);
                    },
                }
                i += 2;
            } else {
                try buf.append(self.allocator, text[i]);
                i += 1;
            }
        }
        // Track the allocation so it gets freed with the module
        try self.module.owned_strings.append(self.allocator, buf.items);
        return buf.items;
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

    var resolve_result = try resolve.resolveNames(allocator, &parser.tree, token_list.items);
    defer resolve_result.deinit(allocator);
    try std.testing.expect(!resolve_result.diagnostics.hasErrors());

    var tc_result = try typecheck_mod.typeCheck(allocator, &parser.tree, token_list.items, &resolve_result);
    defer tc_result.deinit(allocator);
    try std.testing.expect(!tc_result.diagnostics.hasErrors());

    return try lower(allocator, &parser.tree, token_list.items, &tc_result);
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
    try std.testing.expectEqualStrings("run_fmt_println_args", module.call_infos.items[0].target_name);
}

test "lower: fmt.print maps to runtime print" {
    var module = try testLower(
        \\use "fmt"
        \\fn main() {
        \\    fmt.print("a", "b")
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), module.call_infos.items.len);
    try std.testing.expectEqualStrings("run_fmt_print_args", module.call_infos.items[0].target_name);
    try std.testing.expectEqual(@as(usize, 2), module.call_infos.items[0].args.items.len);
}

test "lower: integer literal" {
    var module = try testLower(
        \\fn main() int {
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
        \\fn main() int {
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

fn moduleHasCallTarget(module: *const ir.Module, target_name: []const u8) bool {
    for (module.call_infos.items) |info| {
        if (std.mem.eql(u8, info.target_name, target_name)) return true;
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
    try std.testing.expectEqualStrings("run_fmt_println_args", module.call_infos.items[0].target_name);
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
        \\    var t &[]int
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

test "lower: nested scope lookup keeps outer local binding" {
    var module = try testLower(
        \\use "fmt"
        \\fn main() {
        \\    let x = 1
        \\    {
        \\        let y = 2
        \\    }
        \\    fmt.print_int(x)
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    // The outer local binding should still exist after nested scope traversal.
    try std.testing.expectEqual(@as(usize, 2), module.local_infos.items.len);
    try std.testing.expectEqualStrings("x", module.local_infos.items[0].name);

    const func = &module.functions.items[0];
    try std.testing.expect(func.blocks.items.len >= 1);
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

test "lower: run statement emits spawn" {
    var module = try testLower(
        \\fn say() {
        \\}
        \\fn main() {
        \\    run say()
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    // main is the second function
    const func = &module.functions.items[1];
    const block = &func.blocks.items[0];
    try std.testing.expect(blockHasOp(block, .spawn));

    // The spawn should reference a call_info with the mangled function name
    var found_spawn = false;
    for (block.insts.items) |inst| {
        if (inst.op == .spawn) {
            found_spawn = true;
            const info_idx = inst.arg1;
            try std.testing.expect(info_idx < module.call_infos.items.len);
            try std.testing.expectEqualStrings("run_main__say", module.call_infos.items[info_idx].target_name);
        }
    }
    try std.testing.expect(found_spawn);
}

test "lower: channel alloc emits chan_new" {
    var module = try testLower(
        \\fn main() {
        \\    var ch = alloc(chan[int])
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    const func = &module.functions.items[0];
    const block = &func.blocks.items[0];
    try std.testing.expect(blockHasOp(block, .chan_new));
    // Should NOT have gen_alloc (channels use chan_new, not gen_alloc)
    try std.testing.expect(!blockHasOp(block, .gen_alloc));

    // Variable should be typed as run_chan_t*
    try std.testing.expect(module.local_infos.items.len >= 1);
    try std.testing.expectEqualStrings("run_chan_t*", module.local_infos.items[0].c_type);
}

test "lower: channel alloc with capacity" {
    var module = try testLower(
        \\fn main() {
        \\    var ch = alloc(chan[int], 10)
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    const func = &module.functions.items[0];
    const block = &func.blocks.items[0];
    try std.testing.expect(blockHasOp(block, .chan_new));
    try std.testing.expect(blockHasOp(block, .const_int));
}

test "lower: channel send emits chan_send" {
    var module = try testLower(
        \\fn main() {
        \\    var ch = alloc(chan[int])
        \\    ch <- 42
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    const func = &module.functions.items[0];
    const block = &func.blocks.items[0];
    try std.testing.expect(blockHasOp(block, .chan_new));
    try std.testing.expect(blockHasOp(block, .chan_send));
}

test "lower: channel recv emits chan_recv" {
    var module = try testLower(
        \\fn main() {
        \\    var ch = alloc(chan[int])
        \\    var val = <-ch
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    const func = &module.functions.items[0];
    const block = &func.blocks.items[0];
    try std.testing.expect(blockHasOp(block, .chan_new));
    try std.testing.expect(blockHasOp(block, .chan_recv));
}

test "lower: close emits chan_close call" {
    var module = try testLower(
        \\fn main() {
        \\    var ch = alloc(chan[int])
        \\    close(ch)
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    // close(ch) should be lowered as a call to run_chan_close
    var found_close = false;
    for (module.call_infos.items) |info| {
        if (std.mem.eql(u8, info.target_name, "run_chan_close")) {
            found_close = true;
        }
    }
    try std.testing.expect(found_close);
}

test "lower: SIMD helpers are emitted as typed calls" {
    var module = try testLower(
        \\fn main() {
        \\    let a = v4f32{ 1.0, 2.0, 3.0, 4.0 }
        \\    let b = v4f32{ 10.0, 20.0, 30.0, 40.0 }
        \\    let c = a + b
        \\    let m = c < b
        \\    let d = simd.select(m, c, b)
        \\    let s = simd.hadd(d)
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(moduleHasCallTarget(&module, "run_simd_v4f32_make"));
    try std.testing.expect(moduleHasCallTarget(&module, "run_simd_v4f32_add"));
    try std.testing.expect(moduleHasCallTarget(&module, "run_simd_v4f32_lt"));
    try std.testing.expect(moduleHasCallTarget(&module, "run_simd_v4f32_select"));
    try std.testing.expect(moduleHasCallTarget(&module, "run_simd_v4f32_hadd"));

    var saw_aligned_local = false;
    for (module.local_infos.items) |info| {
        if (std.mem.eql(u8, info.name, "a")) {
            saw_aligned_local = info.alignment == 16 and std.mem.eql(u8, info.c_type, "run_simd_v4f32_t");
        }
    }
    try std.testing.expect(saw_aligned_local);
}

test "lower: SIMD lane assignment uses set_lane helper" {
    var module = try testLower(
        \\fn main() {
        \\    var v = v4i32{ 1, 2, 3, 4 }
        \\    v[1] = 9
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(moduleHasCallTarget(&module, "run_simd_v4i32_set_lane"));
}

test "lower: SIMD alloc uses aligned runtime helper for wide vectors" {
    var module = try testLower(
        \\fn main() {
        \\    var ptr = alloc(v8f32)
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(moduleHasCallTarget(&module, "run_gen_alloc_aligned"));
}

test "lower: addr_of local emits local storage address" {
    var module = try testLower(
        \\fn main() {
        \\    var v = v4f32{ 1.0, 2.0, 3.0, 4.0 }
        \\    let ptr = &v
        \\    simd.store(ptr, v)
        \\}
        \\
    );
    defer module.deinit(std.testing.allocator);

    var saw_local_addr = false;
    for (module.functions.items) |func| {
        for (func.blocks.items) |block| {
            for (block.insts.items) |inst| {
                if (inst.op == .local_addr) saw_local_addr = true;
            }
        }
    }

    try std.testing.expect(saw_local_addr);
    try std.testing.expect(moduleHasCallTarget(&module, "run_simd_v4f32_store"));
}
