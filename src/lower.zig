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
    return lowerProgram(allocator, tree, tokens, tc_result, null, null);
}

/// Lower a typed AST into an IR Module, optionally recording source debug info.
pub fn lowerWithSource(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    tokens: []const Token,
    tc_result: *const typecheck_mod.TypeCheckResult,
    source_path: ?[]const u8,
) LowerError!ir.Module {
    return lowerProgram(allocator, tree, tokens, tc_result, source_path, null);
}

/// Lower a typed AST into an IR Module. Constructs that have no lowering yet
/// are reported into `diags` (when provided) instead of being silently
/// dropped — a program must never compile to wrong code.
pub fn lowerProgram(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    tokens: []const Token,
    tc_result: *const typecheck_mod.TypeCheckResult,
    source_path: ?[]const u8,
    diags: ?*diagnostics.DiagnosticList,
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
        .next_fn_is_inline = false,
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
        .loop_stack = .empty,
        .diags = diags,
        .struct_c_names = .empty,
        .func_local_names = .empty,
        .closure_ctx_node = null_node,
        .current_fn_return_type_id = types.null_type,
        .methods = .empty,
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
    next_fn_is_inline: bool,
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

    // Enclosing loops, innermost last — break/continue jump targets.
    loop_stack: std.ArrayList(LoopInfo),

    // Destination for "not supported yet" errors; null in legacy callers.
    diags: ?*diagnostics.DiagnosticList,

    // C typedef names for struct TypeIds (registered before lowering bodies).
    struct_c_names: std.AutoHashMapUnmanaged(TypeId, []const u8),

    // Source names already used as C locals in the current function.
    func_local_names: std.StringHashMapUnmanaged(void),

    // Non-zero while lowering a closure body: the closure's AST node, used
    // to report capture attempts (closures see a fresh variable space).
    closure_ctx_node: NodeIndex,

    // Return type of the function currently being lowered (null_type when
    // void/unknown) — drives error-union return/try propagation.
    current_fn_return_type_id: TypeId,

    // Methods discovered in a prepass: (receiver struct TypeId, name) →
    // mangled C name + receiver kind, so call sites can dispatch regardless
    // of declaration order.
    methods: std.ArrayList(MethodInfo),

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
        kind: OwnedKind = .gen_ptr,
    };

    const OwnedKind = enum { gen_ptr, slice };

    const LoopInfo = struct {
        break_bb: ir.BlockId,
        continue_bb: ir.BlockId,
        /// Defer/owned stack depths at loop entry, so break/continue can run
        /// cleanup for scopes opened inside the loop before jumping out.
        defer_depth: usize,
        owned_depth: usize,
    };

    const ReceiverKind = enum { value, ptr, const_ptr };

    const MethodInfo = struct {
        struct_type: TypeId,
        name: []const u8,
        mangled: []const u8,
        receiver_kind: ReceiverKind,
    };

    /// Report a construct that has no lowering yet. Without a diagnostics
    /// sink this is silent for legacy callers, but the driver always wires
    /// one so user-facing compiles fail instead of miscompiling.
    fn unsupported(self: *LoweringContext, node_idx: NodeIndex, comptime what: []const u8) LowerError!void {
        const dl = self.diags orelse return;
        const tok = self.tree.nodes.items[node_idx].main_token;
        const loc = self.tokens[tok].loc;
        try dl.addError(loc.start, loc.end, what ++ " is not supported by the compiler yet");
    }

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
            if (entry.is_moved) continue;
            switch (entry.kind) {
                .gen_ptr => {
                    const ptr_ref = self.allocRef();
                    try self.emit(ir.makeInst(.local_get, ptr_ref, entry.local_idx, 0));
                    try self.emit(ir.makeInst(.gen_free, 0, ptr_ref, 0));
                },
                .slice => {
                    const addr_ref = self.allocRef();
                    try self.emit(ir.makeInst(.local_addr, addr_ref, entry.local_idx, 0));
                    _ = try self.emitTypedCall("run_slice_free", &.{addr_ref}, "void", false);
                },
            }
        }
    }

    /// Emit cleanup for all active scopes (used before return statements).
    fn emitAllCleanup(self: *LoweringContext) LowerError!void {
        try self.emitScopeCleanup(0, 0);
    }

    fn defineVar(self: *LoweringContext, name: []const u8, c_type: []const u8, alignment: u32, init_ref: ir.Ref) LowerError!u32 {
        const prev_local = self.var_lookup.get(name);
        // Uniquify the emitted C name within the current function so that
        // shadowed locals don't collapse into one C declaration.
        var c_name = name;
        if (self.func_local_names.contains(name)) {
            c_name = try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ name, self.module.local_infos.items.len });
            try self.module.owned_strings.append(self.allocator, c_name);
        } else {
            try self.func_local_names.put(self.allocator, name, {});
        }
        const local_idx = try self.module.addLocalInfoAligned(self.allocator, c_name, c_type, alignment);
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
        // Closures lower with a fresh variable space, so a name that misses
        // here but resolved earlier is a capture of an outer variable.
        if (self.closure_ctx_node != null_node) {
            try self.unsupported(self.closure_ctx_node, "closures that capture outer variables");
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
            .struct_type => self.struct_c_names.get(type_id) orelse "int64_t",
            .error_union_type => self.struct_c_names.get(type_id) orelse "int64_t",
            .nullable_type => self.struct_c_names.get(type_id) orelse "int64_t",
            .slice_type => "run_slice_t",
            // Function values are generic pointers; calls cast to the
            // concrete signature (see call_ptr).
            .fn_type => "void*",
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

        try self.registerStructTypes();
        for (decl_indices) |decl_idx| {
            try self.registerMethodDecl(decl_idx);
        }

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
        self.loop_stack.deinit(self.allocator);
        self.struct_c_names.deinit(self.allocator);
        self.func_local_names.deinit(self.allocator);
        self.methods.deinit(self.allocator);
    }

    /// Register a C typedef for every struct type in the pool. Two passes:
    /// names first so fields referencing other structs resolve regardless of
    /// declaration order.
    fn registerStructTypes(self: *LoweringContext) LowerError!void {
        const pool_len: TypeId = @intCast(self.type_pool.types.items.len);
        var id: TypeId = 0;
        while (id < pool_len) : (id += 1) {
            switch (self.type_pool.get(id)) {
                .struct_type => |st| {
                    const c_name = try std.fmt.allocPrint(self.allocator, "run_type_{s}", .{st.name});
                    try self.module.owned_strings.append(self.allocator, c_name);
                    try self.struct_c_names.put(self.allocator, id, c_name);
                },
                else => {},
            }
        }

        // Error unions get C names too:
        // { bool is_error; run_string_t error_msg; T value; }
        id = 0;
        while (id < pool_len) : (id += 1) {
            switch (self.type_pool.get(id)) {
                .error_union_type => |eu| {
                    const payload_c = if (eu.payload == types.null_type or eu.payload == types.primitives.void_id)
                        "void"
                    else
                        self.cTypeForTypeId(eu.payload);
                    const c_name = try self.sanitizedTypeName("run_err_", payload_c);
                    try self.struct_c_names.put(self.allocator, id, c_name);
                },
                .nullable_type => |nt| {
                    const payload_c = if (nt.inner == types.null_type)
                        "void"
                    else
                        self.cTypeForTypeId(nt.inner);
                    const c_name = try self.sanitizedTypeName("run_opt_", payload_c);
                    try self.struct_c_names.put(self.allocator, id, c_name);
                },
                else => {},
            }
        }

        id = 0;
        while (id < pool_len) : (id += 1) {
            switch (self.type_pool.get(id)) {
                .struct_type => |st| {
                    const c_name = self.struct_c_names.get(id).?;
                    // The pool can contain a placeholder entry and a final
                    // entry for the same nominal struct: keep one typedef,
                    // preferring the one that has the fields.
                    var existing: ?*ir.StructInfo = null;
                    for (self.module.struct_infos.items) |*si| {
                        if (std.mem.eql(u8, si.c_name, c_name)) {
                            existing = si;
                            break;
                        }
                    }
                    if (existing) |si| {
                        if (si.fields.items.len == 0 and st.fields.len > 0) {
                            for (st.fields) |f| {
                                try si.fields.append(self.allocator, .{
                                    .name = f.name,
                                    .c_type = self.cTypeForTypeId(f.type_id),
                                });
                            }
                        }
                        continue;
                    }
                    var info = ir.StructInfo{ .c_name = c_name, .fields = .empty };
                    for (st.fields) |f| {
                        try info.fields.append(self.allocator, .{
                            .name = f.name,
                            .c_type = self.cTypeForTypeId(f.type_id),
                        });
                    }
                    try self.module.struct_infos.append(self.allocator, info);
                },
                else => {},
            }
        }

        // Emit nullable typedefs after struct typedefs so payload fields can
        // reference run_type_* by name: { bool has_value; T value; }
        id = 0;
        while (id < pool_len) : (id += 1) {
            switch (self.type_pool.get(id)) {
                .nullable_type => |nt| {
                    const c_name = self.struct_c_names.get(id).?;
                    var already = false;
                    for (self.module.struct_infos.items) |si| {
                        if (std.mem.eql(u8, si.c_name, c_name)) {
                            already = true;
                            break;
                        }
                    }
                    if (already) continue;
                    var info = ir.StructInfo{ .c_name = c_name, .fields = .empty };
                    try info.fields.append(self.allocator, .{ .name = "has_value", .c_type = "bool" });
                    if (nt.inner != types.null_type) {
                        try info.fields.append(self.allocator, .{ .name = "value", .c_type = self.cTypeForTypeId(nt.inner) });
                    }
                    try self.module.struct_infos.append(self.allocator, info);
                },
                else => {},
            }
        }

        // Emit error-union typedefs after struct typedefs so payload fields
        // can reference run_type_* by name.
        id = 0;
        while (id < pool_len) : (id += 1) {
            switch (self.type_pool.get(id)) {
                .error_union_type => |eu| {
                    const c_name = self.struct_c_names.get(id).?;
                    var already = false;
                    for (self.module.struct_infos.items) |si| {
                        if (std.mem.eql(u8, si.c_name, c_name)) {
                            already = true;
                            break;
                        }
                    }
                    if (already) continue;
                    var info = ir.StructInfo{ .c_name = c_name, .fields = .empty };
                    try info.fields.append(self.allocator, .{ .name = "is_error", .c_type = "bool" });
                    try info.fields.append(self.allocator, .{ .name = "error_msg", .c_type = "run_string_t" });
                    if (eu.payload != types.null_type and eu.payload != types.primitives.void_id) {
                        try info.fields.append(self.allocator, .{ .name = "value", .c_type = self.cTypeForTypeId(eu.payload) });
                    }
                    try self.module.struct_infos.append(self.allocator, info);
                },
                else => {},
            }
        }
    }

    /// Build an identifier-safe C type name with the given prefix, e.g.
    /// "run_err_" + "run_chan_t*" -> "run_err_run_chan_t_ptr".
    fn sanitizedTypeName(self: *LoweringContext, comptime prefix: []const u8, c_type: []const u8) LowerError![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, prefix);
        for (c_type) |ch| {
            switch (ch) {
                '*' => try buf.appendSlice(self.allocator, "_ptr"),
                ' ' => try buf.append(self.allocator, '_'),
                else => try buf.append(self.allocator, ch),
            }
        }
        const owned = try buf.toOwnedSlice(self.allocator);
        try self.module.owned_strings.append(self.allocator, owned);
        return owned;
    }

    /// Locate a fn_decl's receiver node, or null_node for plain functions.
    /// fn_decl extra layout: [param1..paramN, count, receiver_node, ret_type]
    fn fnDeclReceiver(self: *const LoweringContext, fn_node: NodeIndex) NodeIndex {
        const node = self.tree.nodes.items[fn_node];
        const extra = self.tree.extra_data.items;
        const params_start = node.data.lhs;
        var param_count: u32 = 0;
        while (params_start + param_count < extra.len) : (param_count += 1) {
            if (extra[params_start + param_count] == param_count) break;
        }
        const recv_pos = params_start + param_count + 1;
        if (recv_pos >= extra.len) return null_node;
        return extra[recv_pos];
    }

    /// Prepass: record (struct type, method name) → mangled C name for each
    /// method declaration so call sites can dispatch in any order.
    fn registerMethodDecl(self: *LoweringContext, decl_idx: NodeIndex) LowerError!void {
        if (decl_idx == null_node) return;
        const node = self.tree.nodes.items[decl_idx];
        switch (node.tag) {
            .pub_decl, .inline_decl => return self.registerMethodDecl(node.data.lhs),
            .fn_decl => {},
            else => return,
        }

        const receiver_node = self.fnDeclReceiver(decl_idx);
        if (receiver_node == null_node) return;
        const recv = self.tree.nodes.items[receiver_node];
        const recv_type_node = recv.data.lhs;
        if (recv_type_node == null_node) return;

        const kind: ReceiverKind = switch (self.tree.nodes.items[recv_type_node].tag) {
            .type_ptr => .ptr,
            .type_const_ptr => .const_ptr,
            else => .value,
        };
        const recv_type_raw = self.resolveTypeNode(recv_type_node);
        const struct_type = self.type_pool.unwrapPointer(recv_type_raw) orelse recv_type_raw;
        if (struct_type == types.null_type) return;
        const struct_name = switch (self.type_pool.get(struct_type)) {
            .struct_type => |st| st.name,
            else => return,
        };

        const method_name = self.methodNameSlice(decl_idx);
        const mangled = try std.fmt.allocPrint(self.allocator, "run_main__{s}__{s}", .{ struct_name, method_name });
        try self.module.owned_strings.append(self.allocator, mangled);
        try self.methods.append(self.allocator, .{
            .struct_type = struct_type,
            .name = method_name,
            .mangled = mangled,
            .receiver_kind = kind,
        });
    }

    /// The declared name of a fn_decl, skipping a receiver clause if present.
    fn methodNameSlice(self: *const LoweringContext, fn_node: NodeIndex) []const u8 {
        const fn_tok = self.tree.nodes.items[fn_node].main_token;
        var name_tok = fn_tok + 1;
        if (self.tokens[name_tok].tag == .l_paren) {
            var depth: u32 = 1;
            name_tok += 1;
            while (name_tok < self.tokens.len and depth > 0) : (name_tok += 1) {
                if (self.tokens[name_tok].tag == .l_paren) depth += 1;
                if (self.tokens[name_tok].tag == .r_paren) depth -= 1;
            }
        }
        return self.tokenSlice(name_tok);
    }

    fn lookupMethodInfo(self: *const LoweringContext, struct_type: TypeId, name: []const u8) ?MethodInfo {
        for (self.methods.items) |mi| {
            if (std.mem.eql(u8, mi.name, name) and self.type_pool.typeEql(mi.struct_type, struct_type)) {
                return mi;
            }
        }
        return null;
    }

    fn lowerTopLevel(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        if (node_idx == null_node) return;
        const node = self.tree.nodes.items[node_idx];
        switch (node.tag) {
            .pub_decl => try self.lowerTopLevel(node.data.lhs),
            .inline_decl => {
                self.next_fn_is_inline = true;
                try self.lowerTopLevel(node.data.lhs);
            },
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

        const name = self.methodNameSlice(node_idx);

        // Methods (declarations with a receiver) were registered in the
        // prepass; reuse their mangled name so call sites match.
        const receiver_node = self.fnDeclReceiver(node_idx);
        var receiver_kind: ReceiverKind = .value;
        var receiver_struct_type: TypeId = types.null_type;
        const mangled = blk: {
            if (receiver_node != null_node) {
                const recv_type_node = self.tree.nodes.items[receiver_node].data.lhs;
                if (recv_type_node != null_node) {
                    receiver_kind = switch (self.tree.nodes.items[recv_type_node].tag) {
                        .type_ptr => .ptr,
                        .type_const_ptr => .const_ptr,
                        else => .value,
                    };
                    const recv_type_raw = self.resolveTypeNode(recv_type_node);
                    receiver_struct_type = self.type_pool.unwrapPointer(recv_type_raw) orelse recv_type_raw;
                    if (receiver_struct_type != types.null_type) {
                        if (self.lookupMethodInfo(receiver_struct_type, name)) |mi| {
                            break :blk mi.mangled;
                        }
                    }
                }
            }
            const plain = try std.fmt.allocPrint(self.allocator, "run_main__{s}", .{name});
            try self.module.owned_strings.append(self.allocator, plain);
            break :blk plain;
        };

        // Record debug info for function name demangling
        try self.module.func_debug_infos.append(self.allocator, .{
            .mangled_name = mangled,
            .original_name = name,
            .source_byte_offset = self.tokens[fn_tok].loc.start,
        });

        const func_id = try self.module.addFunction(self.allocator, mangled);
        self.current_func = self.module.getFunction(func_id);
        self.func_local_names.clearRetainingCapacity();
        self.current_fn_return_type_id = types.null_type;
        if (self.next_fn_is_inline) {
            self.current_func.?.is_inline = true;
            self.next_fn_is_inline = false;
        }
        self.current_func.?.return_type_name = "void";
        const params_start = node.data.lhs;
        var param_count: u32 = 0;
        while (params_start + param_count < extra.len) : (param_count += 1) {
            if (extra[params_start + param_count] == param_count) break;
        }
        const param_nodes = extra[params_start .. params_start + param_count];
        const fn_type_id = self.typeOfNode(node_idx);

        // The receiver becomes the first C parameter: a generational
        // reference for &T/@T receivers, the struct value for T receivers.
        var recv_ref: ir.Ref = ir.null_ref;
        var recv_name: []const u8 = "";
        var recv_c_type: []const u8 = "int64_t";
        if (receiver_node != null_node and receiver_struct_type != types.null_type) {
            recv_name = self.tokenSlice(self.tree.nodes.items[receiver_node].main_token);
            recv_c_type = switch (receiver_kind) {
                .ptr, .const_ptr => "run_gen_ref_t",
                .value => self.cTypeForTypeId(receiver_struct_type),
            };
            const recv_param_name = try std.fmt.allocPrint(self.allocator, "_param_{s}", .{recv_name});
            try self.module.owned_strings.append(self.allocator, recv_param_name);
            recv_ref = try self.current_func.?.addParam(self.allocator, recv_param_name, recv_c_type);
        }

        var param_refs: [64]ir.Ref = [_]ir.Ref{ir.null_ref} ** 64;
        var param_type_ids: [64]TypeId = [_]TypeId{types.null_type} ** 64;
        if (fn_type_id != types.null_type) {
            switch (self.type_pool.get(fn_type_id)) {
                .fn_type => |fn_type| {
                    self.current_func.?.return_type_name = self.cTypeForTypeId(fn_type.return_type);
                    self.current_fn_return_type_id = fn_type.return_type;
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
        if (recv_ref != ir.null_ref and recv_name.len > 0) {
            _ = try self.defineVar(recv_name, recv_c_type, 0, recv_ref);
        }
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
            if (self.isErrorUnion(self.current_fn_return_type_id)) {
                // Falling off the end of a `!`-returning function yields ok.
                const ok_ref = try self.buildErrUnionValue(self.current_fn_return_type_id, ir.null_ref, ir.null_ref);
                try self.emitAllCleanup();
                try self.emit(ir.makeInst(.ret, 0, ok_ref, 0));
            } else {
                try self.current_block.?.addInst(self.allocator, ir.makeInst(.ret_void, 0, 0, 0));
            }
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
            .return_stmt => try self.lowerReturnStmt(node_idx),
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
            .break_stmt => {
                if (self.loop_stack.items.len > 0) {
                    const li = self.loop_stack.items[self.loop_stack.items.len - 1];
                    try self.emitScopeCleanup(li.defer_depth, li.owned_depth);
                    try self.emit(ir.makeInst(.br, 0, li.break_bb, 0));
                }
            },
            .continue_stmt => {
                if (self.loop_stack.items.len > 0) {
                    const li = self.loop_stack.items[self.loop_stack.items.len - 1];
                    try self.emitScopeCleanup(li.defer_depth, li.owned_depth);
                    try self.emit(ir.makeInst(.br, 0, li.continue_bb, 0));
                }
            },
            .for_range_stmt => try self.lowerForIndexValue(node_idx),
            .switch_stmt => try self.lowerSwitchStmt(node_idx),
            else => try self.unsupported(node_idx, "this statement"),
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

            // Track ownership for alloc expressions. Channels are shared
            // across green threads and must not be freed at scope exit;
            // slices free through run_slice_free.
            if (self.tree.nodes.items[node.data.rhs].tag == .alloc_expr) {
                if (self.allocOwnedKind(node.data.rhs)) |kind| {
                    try self.owned_stack.append(self.allocator, .{
                        .name = name,
                        .local_idx = local_idx,
                        .is_moved = false,
                        .kind = kind,
                    });
                }
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

                    // Track ownership for alloc expressions (see lowerVarDecl).
                    if (self.tree.nodes.items[node.data.rhs].tag == .alloc_expr) {
                        if (self.allocOwnedKind(node.data.rhs)) |kind| {
                            try self.owned_stack.append(self.allocator, .{
                                .name = name,
                                .local_idx = local_idx,
                                .is_moved = false,
                                .kind = kind,
                            });
                        }
                    }
                }
            }
        }
    }

    fn lowerAssign(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        if (node.data.lhs != null_node and self.tree.nodes.items[node.data.lhs].tag == .index_access) {
            const base_idx = self.tree.nodes.items[node.data.lhs].data.lhs;
            if (self.isSliceType(self.typeOfNode(base_idx))) {
                const val_ref = try self.lowerExpr(node.data.rhs);
                try self.lowerSliceIndexAssign(node.data.lhs, val_ref);
                return;
            }
            if (self.isMapType(self.typeOfNode(base_idx))) {
                const val_ref = try self.lowerExpr(node.data.rhs);
                try self.lowerMapIndexAssign(node.data.lhs, val_ref);
                return;
            }
            try self.lowerSimdLaneAssign(node.data.lhs, node.data.rhs);
            return;
        }

        const val = try self.lowerExpr(node.data.rhs);

        if (node.data.lhs != null_node) {
            const target = self.tree.nodes.items[node.data.lhs];
            if (target.tag == .field_access) {
                try self.lowerFieldAssign(node.data.lhs, val);
                return;
            }
            if (target.tag == .ident) {
                const target_name = self.tokenSlice(target.main_token);

                // Move semantics: if RHS is an ident referencing an owned variable,
                // mark the source as moved and transfer ownership to the target.
                if (node.data.rhs != null_node) {
                    const rhs_node = self.tree.nodes.items[node.data.rhs];
                    if (rhs_node.tag == .ident) {
                        const src_name = self.tokenSlice(rhs_node.main_token);
                        if (self.markOwnedMoved(src_name)) |src_kind| {
                            // Transfer ownership (and its cleanup kind).
                            if (self.lookupLocalIdx(target_name)) |local_idx| {
                                try self.owned_stack.append(self.allocator, .{
                                    .name = target_name,
                                    .local_idx = local_idx,
                                    .is_moved = false,
                                    .kind = src_kind,
                                });
                            }
                        }
                    }
                }

                try self.setVar(target_name, val);
            }
        }
    }

    /// Mark an owned variable as moved (ownership transferred away).
    /// Returns the moved entry's cleanup kind, or null if `name` wasn't owned.
    fn markOwnedMoved(self: *LoweringContext, name: []const u8) ?OwnedKind {
        var i = self.owned_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.owned_stack.items[i].name, name)) {
                self.owned_stack.items[i].is_moved = true;
                return self.owned_stack.items[i].kind;
            }
        }
        return null;
    }

    fn lowerIfStmt(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const extra = self.tree.extra_data.items;
        const cond_ref = try self.lowerExpr(node.data.lhs);

        const then_block_node = extra[node.data.rhs];
        const else_node = extra[node.data.rhs + 1];

        const func = self.current_func orelse return;
        const current_bb = self.currentBlockId() orelse return;

        if (else_node == null_node) {
            const then_bb = try func.addBlock(self.allocator);
            const after_bb = try func.addBlock(self.allocator);

            self.current_block = func.getBlock(current_bb);
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

            self.current_block = func.getBlock(current_bb);
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

        // `for item in iterable { }` — the parser keeps the loop variable
        // only in the token stream: `for` IDENT `in` ... (same trick as
        // resolve.zig uses).
        const main_tok = node.main_token;
        const is_for_in = (main_tok + 2 < self.tokens.len and
            self.tokens[main_tok + 1].tag == .identifier and
            self.tokens[main_tok + 2].tag == .kw_in);
        if (is_for_in) {
            const iter_node = node.data.lhs;
            if (iter_node != null_node and self.tree.nodes.items[iter_node].tag == .range) {
                return self.lowerForRange(node_idx);
            }
            if (iter_node != null_node and self.isSliceType(self.typeOfNode(iter_node))) {
                return self.lowerForSlice(node_idx);
            }
            return self.unsupported(node_idx, "'for ... in' over a non-range iterable");
        }

        const current_bb = self.currentBlockId() orelse return;

        const cond_node = node.data.lhs;
        const body_node = node.data.rhs;

        const cond_bb = try func.addBlock(self.allocator);
        const body_bb = try func.addBlock(self.allocator);
        const after_bb = try func.addBlock(self.allocator);

        self.current_block = func.getBlock(current_bb);
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
        try self.loop_stack.append(self.allocator, .{
            .break_bb = after_bb,
            .continue_bb = cond_bb,
            .defer_depth = self.defer_stack.items.len,
            .owned_depth = self.owned_stack.items.len,
        });
        try self.pushScope();
        try self.lowerBlock(body_node);
        try self.popScope();
        _ = self.loop_stack.pop();
        if (!self.current_block.?.isTerminated()) {
            try self.emit(ir.makeInst(.br, 0, cond_bb, 0));
        }

        self.current_block = func.getBlock(after_bb);
    }

    /// Lower `for i in start..end { body }` as a counted loop. The loop
    /// variable and the (once-evaluated) end bound live in named locals so
    /// they survive across basic blocks.
    fn lowerForRange(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const func = self.current_func orelse return;
        const range_node = self.tree.nodes.items[node.data.lhs];
        const body_node = node.data.rhs;
        const var_name = self.tokenSlice(node.main_token + 1);

        const start_ref = try self.lowerExpr(range_node.data.lhs);
        const end_ref = try self.lowerExpr(range_node.data.rhs);
        const end_name = try std.fmt.allocPrint(self.allocator, "_for_end_{d}", .{func.next_ref});
        try self.module.owned_strings.append(self.allocator, end_name);
        const end_idx = try self.module.addLocalInfoAligned(self.allocator, end_name, "int64_t", 0);
        try self.emit(ir.makeInst(.local_set, 0, end_idx, end_ref));

        try self.pushScope();
        const var_idx = try self.defineVar(var_name, "int64_t", 0, start_ref);

        // Capture the entry block id only after all subexpressions are
        // lowered (they can move the current block), and re-fetch the
        // pointer after addBlock calls (they can reallocate the array).
        const entry_bb = self.currentBlockId() orelse return;
        const cond_bb = try func.addBlock(self.allocator);
        const body_bb = try func.addBlock(self.allocator);
        const step_bb = try func.addBlock(self.allocator);
        const after_bb = try func.addBlock(self.allocator);
        self.current_block = func.getBlock(entry_bb);
        try self.emit(ir.makeInst(.br, 0, cond_bb, 0));

        self.current_block = func.getBlock(cond_bb);
        const i_ref = self.allocRef();
        try self.emit(ir.makeInst(.local_get, i_ref, var_idx, 0));
        const e_ref = self.allocRef();
        try self.emit(ir.makeInst(.local_get, e_ref, end_idx, 0));
        const cmp_ref = self.allocRef();
        try self.emit(ir.makeInst(.lt, cmp_ref, i_ref, e_ref));
        try self.emit(ir.makeInst(.br_cond, 0, cmp_ref, body_bb));
        try self.emit(ir.makeInst(.br, 0, after_bb, 0));

        self.current_block = func.getBlock(body_bb);
        try self.loop_stack.append(self.allocator, .{
            .break_bb = after_bb,
            .continue_bb = step_bb,
            .defer_depth = self.defer_stack.items.len,
            .owned_depth = self.owned_stack.items.len,
        });
        try self.pushScope();
        try self.lowerBlock(body_node);
        try self.popScope();
        _ = self.loop_stack.pop();
        if (!self.current_block.?.isTerminated()) {
            try self.emit(ir.makeInst(.br, 0, step_bb, 0));
        }

        self.current_block = func.getBlock(step_bb);
        const cur_ref = self.allocRef();
        try self.emit(ir.makeInst(.local_get, cur_ref, var_idx, 0));
        const one_ref = self.allocRef();
        try self.emit(ir.makeConstInt(one_ref, 1));
        const next_ref = self.allocRef();
        try self.emit(ir.makeInst(.add, next_ref, cur_ref, one_ref));
        try self.emit(ir.makeInst(.local_set, 0, var_idx, next_ref));
        try self.emit(ir.makeInst(.br, 0, cond_bb, 0));

        try self.popScope();
        self.current_block = func.getBlock(after_bb);
    }

    /// Resolve a struct field by name. Returns its type id, or null.
    fn structFieldType(self: *const LoweringContext, struct_type: TypeId, field_name: []const u8) ?TypeId {
        switch (self.type_pool.get(struct_type)) {
            .struct_type => |st| {
                for (st.fields) |f| {
                    if (std.mem.eql(u8, f.name, field_name)) return f.type_id;
                }
            },
            else => {},
        }
        return null;
    }

    fn isStructType(self: *const LoweringContext, type_id: TypeId) bool {
        if (type_id == types.null_type or type_id < types.primitives.count) return false;
        return switch (self.type_pool.get(type_id)) {
            .struct_type => true,
            else => false,
        };
    }

    /// Make a fresh named local and return its index.
    fn makeTempLocal(self: *LoweringContext, comptime prefix: []const u8, c_type: []const u8, alignment: u32) LowerError!u32 {
        const func = self.current_func orelse return error.OutOfMemory;
        const name = try std.fmt.allocPrint(self.allocator, prefix ++ "_{d}_{d}", .{ self.module.local_infos.items.len, func.next_ref });
        try self.module.owned_strings.append(self.allocator, name);
        return self.module.addLocalInfoAligned(self.allocator, name, c_type, alignment);
    }

    /// Lower a struct-typed base expression to a named local holding the
    /// value, so fields can be read with `.field`. Reuses the existing local
    /// when the base is a plain identifier.
    fn lowerStructBaseToLocal(self: *LoweringContext, base_idx: NodeIndex, struct_type: TypeId) LowerError!?u32 {
        const base = self.tree.nodes.items[base_idx];
        if (base.tag == .ident) {
            const name = self.tokenSlice(base.main_token);
            if (self.lookupLocalIdx(name)) |local_idx| return local_idx;
        }
        const c_type = self.cTypeForTypeId(struct_type);
        const val_ref = try self.lowerExpr(base_idx);
        if (val_ref == ir.null_ref) return null;
        const tmp_idx = try self.makeTempLocal("_sval", c_type, self.alignmentForTypeId(struct_type));
        try self.emit(ir.makeInst(.local_set, 0, tmp_idx, val_ref));
        return tmp_idx;
    }

    /// Field access on a struct value or pointer-to-struct.
    fn lowerFieldAccess(self: *LoweringContext, node_idx: NodeIndex) LowerError!ir.Ref {
        const node = self.tree.nodes.items[node_idx];
        const base_idx = node.data.lhs;
        const field_name = self.tokenSlice(node.main_token + 1);
        const base_type = self.typeOfNode(base_idx);

        if (self.isStructType(base_type)) {
            const field_type = self.structFieldType(base_type, field_name) orelse {
                try self.unsupported(node_idx, "this field access");
                return ir.null_ref;
            };
            const struct_c = self.struct_c_names.get(base_type) orelse "int64_t";
            const fi = try self.module.addFieldInfo(self.allocator, struct_c, field_name, self.cTypeForTypeId(field_type));
            const local_idx = (try self.lowerStructBaseToLocal(base_idx, base_type)) orelse {
                try self.unsupported(node_idx, "field access on this expression");
                return ir.null_ref;
            };
            const r = self.allocRef();
            try self.emit(ir.makeInst(.local_field_get, r, local_idx, fi));
            return r;
        }

        if (self.type_pool.unwrapPointer(base_type)) |pointee| {
            if (self.isStructType(pointee)) {
                const field_type = self.structFieldType(pointee, field_name) orelse {
                    try self.unsupported(node_idx, "this field access");
                    return ir.null_ref;
                };
                const struct_c = self.struct_c_names.get(pointee) orelse "int64_t";
                const fi = try self.module.addFieldInfo(self.allocator, struct_c, field_name, self.cTypeForTypeId(field_type));
                const ref_val = try self.lowerExpr(base_idx);
                const ptr = self.allocRef();
                try self.emit(ir.makeInst(.gen_ref_deref, ptr, ref_val, 0));
                const r = self.allocRef();
                try self.emit(ir.makeInst(.ptr_field_get, r, ptr, fi));
                return r;
            }
        }

        try self.unsupported(node_idx, "field access on this expression");
        return ir.null_ref;
    }

    /// `base.field = value` for struct locals and pointers-to-struct.
    fn lowerFieldAssign(self: *LoweringContext, lhs_idx: NodeIndex, val_ref: ir.Ref) LowerError!void {
        const lhs = self.tree.nodes.items[lhs_idx];
        const base_idx = lhs.data.lhs;
        const field_name = self.tokenSlice(lhs.main_token + 1);
        const base_type = self.typeOfNode(base_idx);

        if (self.isStructType(base_type)) {
            const base = self.tree.nodes.items[base_idx];
            if (base.tag == .ident) {
                const name = self.tokenSlice(base.main_token);
                if (self.lookupLocalIdx(name)) |local_idx| {
                    const field_type = self.structFieldType(base_type, field_name) orelse {
                        return self.unsupported(lhs_idx, "assignment to this field");
                    };
                    const struct_c = self.struct_c_names.get(base_type) orelse "int64_t";
                    const fi = try self.module.addFieldInfo(self.allocator, struct_c, field_name, self.cTypeForTypeId(field_type));
                    try self.emit(ir.makeInst(.local_field_set, val_ref, local_idx, fi));
                    return;
                }
            }
            return self.unsupported(lhs_idx, "assignment to a field of this expression");
        }

        if (self.type_pool.unwrapPointer(base_type)) |pointee| {
            if (self.isStructType(pointee)) {
                const field_type = self.structFieldType(pointee, field_name) orelse {
                    return self.unsupported(lhs_idx, "assignment to this field");
                };
                const struct_c = self.struct_c_names.get(pointee) orelse "int64_t";
                const fi = try self.module.addFieldInfo(self.allocator, struct_c, field_name, self.cTypeForTypeId(field_type));
                const ref_val = try self.lowerExpr(base_idx);
                const ptr = self.allocRef();
                try self.emit(ir.makeInst(.gen_ref_deref, ptr, ref_val, 0));
                try self.emit(ir.makeInst(.ptr_field_set, val_ref, ptr, fi));
                return;
            }
        }

        return self.unsupported(lhs_idx, "assignment to a field of this expression");
    }

    /// `Type{ field: value, ... }` — zero a temp local, set fields, load it.
    fn lowerStructLiteral(self: *LoweringContext, node_idx: NodeIndex) LowerError!ir.Ref {
        const node = self.tree.nodes.items[node_idx];
        const struct_type = self.typeOfNode(node_idx);
        if (!self.isStructType(struct_type)) {
            try self.unsupported(node_idx, "this struct literal");
            return ir.null_ref;
        }
        const struct_c = self.struct_c_names.get(struct_type) orelse "int64_t";
        const tmp_idx = try self.makeTempLocal("_slit", struct_c, self.alignmentForTypeId(struct_type));
        try self.emit(ir.makeInst(.local_zero, 0, tmp_idx, 0));

        const extra = self.tree.extra_data.items;
        const fields_start = node.data.rhs;
        const field_count = self.findTrailingCount(fields_start);
        const field_nodes = extra[fields_start .. fields_start + field_count];
        for (field_nodes) |field_node| {
            if (field_node == null_node) continue;
            const fnode = self.tree.nodes.items[field_node];
            const fname = self.tokenSlice(fnode.main_token);
            const field_type = self.structFieldType(struct_type, fname) orelse continue;
            const fi = try self.module.addFieldInfo(self.allocator, struct_c, fname, self.cTypeForTypeId(field_type));
            const val_ref = try self.lowerExpr(fnode.data.lhs);
            try self.emit(ir.makeInst(.local_field_set, val_ref, tmp_idx, fi));
        }

        const r = self.allocRef();
        try self.emit(ir.makeInst(.local_get, r, tmp_idx, 0));
        return r;
    }

    /// Lower `base.method(args)` to a call of the mangled method with the
    /// receiver as first argument.
    fn lowerMethodCall(
        self: *LoweringContext,
        call_idx: NodeIndex,
        mi: MethodInfo,
        base_idx: NodeIndex,
        arg_nodes: []const NodeIndex,
    ) LowerError!ir.Ref {
        const base_type = self.typeOfNode(base_idx);
        const base_is_ptr = self.type_pool.unwrapPointer(base_type) != null;

        const recv_ref = switch (mi.receiver_kind) {
            .ptr, .const_ptr => blk: {
                if (base_is_ptr) {
                    break :blk try self.lowerExpr(base_idx);
                }
                // Auto address-of: methods on a local take its storage.
                const local_idx = (try self.lowerStructBaseToLocal(base_idx, mi.struct_type)) orelse {
                    try self.unsupported(call_idx, "method call on this expression");
                    return ir.null_ref;
                };
                const addr = self.allocRef();
                try self.emit(ir.makeInst(.local_addr, addr, local_idx, 0));
                const ref = self.allocRef();
                try self.emit(ir.makeInst(.gen_ref_stack, ref, addr, 0));
                break :blk ref;
            },
            .value => blk: {
                if (base_is_ptr) {
                    const ref_val = try self.lowerExpr(base_idx);
                    const ptr = self.allocRef();
                    try self.emit(ir.makeInst(.gen_ref_deref, ptr, ref_val, 0));
                    const type_idx = try self.module.addValueTypeName(self.allocator, self.cTypeForTypeId(mi.struct_type));
                    const val = self.allocRef();
                    try self.emit(ir.makeInst(.ptr_load_value, val, ptr, type_idx));
                    break :blk val;
                }
                break :blk try self.lowerExpr(base_idx);
            },
        };

        var arg_refs: std.ArrayList(ir.Ref) = .empty;
        defer arg_refs.deinit(self.allocator);
        try arg_refs.append(self.allocator, recv_ref);
        for (arg_nodes) |arg_node| {
            try arg_refs.append(self.allocator, try self.lowerExpr(arg_node));
        }

        const result_type = self.typeOfNode(call_idx);
        const return_type_name = if (result_type == types.null_type) "void" else self.cTypeForTypeId(result_type);
        return self.emitTypedCall(mi.mangled, arg_refs.items, return_type_name, false);
    }

    /// True when a type id is an error union.
    fn isErrorUnion(self: *const LoweringContext, type_id: TypeId) bool {
        if (type_id == types.null_type or type_id < types.primitives.count) return false;
        return switch (self.type_pool.get(type_id)) {
            .error_union_type => true,
            else => false,
        };
    }

    /// Payload type of an error union (null_type for bare `!`).
    fn errUnionPayload(self: *const LoweringContext, eu_type: TypeId) TypeId {
        return switch (self.type_pool.get(eu_type)) {
            .error_union_type => |eu| eu.payload,
            else => types.null_type,
        };
    }

    /// True when the AST node is a call to `errors.new(...)`.
    fn isErrorsNewCall(self: *const LoweringContext, node_idx: NodeIndex) bool {
        if (node_idx == null_node) return false;
        const node = self.tree.nodes.items[node_idx];
        if (node.tag != .call) return false;
        const callee_idx = node.data.lhs;
        if (callee_idx == null_node) return false;
        const callee = self.tree.nodes.items[callee_idx];
        if (callee.tag != .field_access) return false;
        const obj = self.tree.nodes.items[callee.data.lhs];
        if (obj.tag != .ident) return false;
        if (!std.mem.eql(u8, self.tokenSlice(obj.main_token), "errors")) return false;
        const member_tok = callee.main_token + 1;
        return member_tok < self.tokens.len and std.mem.eql(u8, self.tokenSlice(member_tok), "new");
    }

    /// Build an error-union value in a fresh temp local. With `error_msg_ref`
    /// set, the value is an error; otherwise `payload_ref` (or nothing, for
    /// bare `!`) fills the success value. Returns the loaded struct value.
    fn buildErrUnionValue(
        self: *LoweringContext,
        eu_type: TypeId,
        payload_ref: ir.Ref,
        error_msg_ref: ir.Ref,
    ) LowerError!ir.Ref {
        const eu_c = self.struct_c_names.get(eu_type) orelse "int64_t";
        const tmp_idx = try self.makeTempLocal("_err", eu_c, 0);
        try self.emit(ir.makeInst(.local_zero, 0, tmp_idx, 0));
        if (error_msg_ref != ir.null_ref) {
            const true_ref = self.allocRef();
            try self.emit(ir.makeInst(.const_bool, true_ref, 1, 0));
            const fi_err = try self.module.addFieldInfo(self.allocator, eu_c, "is_error", "bool");
            try self.emit(ir.makeInst(.local_field_set, true_ref, tmp_idx, fi_err));
            const fi_msg = try self.module.addFieldInfo(self.allocator, eu_c, "error_msg", "run_string_t");
            try self.emit(ir.makeInst(.local_field_set, error_msg_ref, tmp_idx, fi_msg));
        } else if (payload_ref != ir.null_ref) {
            const payload = self.errUnionPayload(eu_type);
            const fi_val = try self.module.addFieldInfo(self.allocator, eu_c, "value", self.cTypeForTypeId(payload));
            try self.emit(ir.makeInst(.local_field_set, payload_ref, tmp_idx, fi_val));
        }
        const r = self.allocRef();
        try self.emit(ir.makeInst(.local_get, r, tmp_idx, 0));
        return r;
    }

    fn lowerReturnStmt(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const value_node = node.data.lhs;

        // Functions returning !T wrap the payload (or an errors.new call)
        // into the error-union struct.
        if (self.isErrorUnion(self.current_fn_return_type_id)) {
            const eu_type = self.current_fn_return_type_id;
            var result_ref: ir.Ref = ir.null_ref;
            if (self.isErrorsNewCall(value_node)) {
                const call_node = self.tree.nodes.items[value_node];
                const args_start = call_node.data.rhs;
                const arg_count = self.findTrailingCount(args_start);
                const msg_ref = if (arg_count > 0)
                    try self.lowerExpr(self.tree.extra_data.items[args_start])
                else
                    ir.null_ref;
                result_ref = try self.buildErrUnionValue(eu_type, ir.null_ref, msg_ref);
            } else if (value_node != null_node) {
                const val = try self.lowerExpr(value_node);
                result_ref = try self.buildErrUnionValue(eu_type, val, ir.null_ref);
            } else {
                result_ref = try self.buildErrUnionValue(eu_type, ir.null_ref, ir.null_ref);
            }
            try self.emitAllCleanup();
            try self.emit(ir.makeInst(.ret, 0, result_ref, 0));
            return;
        }

        if (value_node != null_node) {
            const val = try self.lowerExpr(value_node);
            try self.emitAllCleanup();
            try self.emit(ir.makeInst(.ret, 0, val, 0));
        } else {
            try self.emitAllCleanup();
            try self.emit(ir.makeInst(.ret_void, 0, 0, 0));
        }
    }

    /// `try expr` — unwrap on success, propagate the error to the caller on
    /// failure (the enclosing function must return an error union).
    fn lowerTryExpr(self: *LoweringContext, node_idx: NodeIndex) LowerError!ir.Ref {
        const node = self.tree.nodes.items[node_idx];
        const func = self.current_func orelse return ir.null_ref;
        const operand_type = self.typeOfNode(node.data.lhs);
        if (!self.isErrorUnion(operand_type) or !self.isErrorUnion(self.current_fn_return_type_id)) {
            try self.unsupported(node_idx, "'try' on this expression");
            return ir.null_ref;
        }
        const eu_c = self.struct_c_names.get(operand_type) orelse "int64_t";
        const payload = self.errUnionPayload(operand_type);

        const operand_ref = try self.lowerExpr(node.data.lhs);
        const tmp_idx = try self.makeTempLocal("_try", eu_c, 0);
        try self.emit(ir.makeInst(.local_set, 0, tmp_idx, operand_ref));
        const fi_err = try self.module.addFieldInfo(self.allocator, eu_c, "is_error", "bool");
        const is_err_ref = self.allocRef();
        try self.emit(ir.makeInst(.local_field_get, is_err_ref, tmp_idx, fi_err));

        const entry_bb = self.currentBlockId() orelse return ir.null_ref;
        const err_bb = try func.addBlock(self.allocator);
        const ok_bb = try func.addBlock(self.allocator);
        self.current_block = func.getBlock(entry_bb);
        try self.emit(ir.makeInst(.br_cond, 0, is_err_ref, err_bb));
        try self.emit(ir.makeInst(.br, 0, ok_bb, 0));

        // Error path: re-wrap the message in the enclosing return type,
        // prefixing the optional `:: "context"` (Go convention: "ctx: msg").
        self.current_block = func.getBlock(err_bb);
        const fi_msg = try self.module.addFieldInfo(self.allocator, eu_c, "error_msg", "run_string_t");
        var msg_ref = self.allocRef();
        try self.emit(ir.makeInst(.local_field_get, msg_ref, tmp_idx, fi_msg));
        if (node.data.rhs != null_node) {
            const ctx_ref = try self.lowerExpr(node.data.rhs);
            const sep_idx = try self.module.addStringConstant(self.allocator, ": ");
            const sep_ref = self.allocRef();
            try self.emit(ir.makeInst(.const_string, sep_ref, sep_idx, 0));
            const prefixed = try self.emitTypedCall("run_string_concat", &.{ ctx_ref, sep_ref }, "run_string_t", false);
            msg_ref = try self.emitTypedCall("run_string_concat", &.{ prefixed, msg_ref }, "run_string_t", false);
        }
        const propagated = try self.buildErrUnionValue(self.current_fn_return_type_id, ir.null_ref, msg_ref);
        try self.emitAllCleanup();
        try self.emit(ir.makeInst(.ret, 0, propagated, 0));

        // Success path: unwrap the payload.
        self.current_block = func.getBlock(ok_bb);
        if (payload == types.null_type or payload == types.primitives.void_id) {
            return ir.null_ref;
        }
        const fi_val = try self.module.addFieldInfo(self.allocator, eu_c, "value", self.cTypeForTypeId(payload));
        const val_ref = self.allocRef();
        try self.emit(ir.makeInst(.local_field_get, val_ref, tmp_idx, fi_val));
        return val_ref;
    }

    /// What kind of cleanup an `alloc(...)` initializer needs at scope exit,
    /// or null when it must not be auto-freed (channels are shared across
    /// green threads).
    fn allocOwnedKind(self: *const LoweringContext, alloc_node: NodeIndex) ?OwnedKind {
        const type_node = self.tree.nodes.items[alloc_node].data.lhs;
        if (type_node == null_node) return .gen_ptr;
        return switch (self.tree.nodes.items[type_node].tag) {
            .type_chan => null,
            .type_map => null,
            .type_slice => .slice,
            else => .gen_ptr,
        };
    }

    fn isSliceType(self: *const LoweringContext, type_id: TypeId) bool {
        if (type_id == types.null_type or type_id < types.primitives.count) return false;
        return switch (self.type_pool.get(type_id)) {
            .slice_type => true,
            else => false,
        };
    }

    fn isMapType(self: *const LoweringContext, type_id: TypeId) bool {
        if (type_id == types.null_type or type_id < types.primitives.count) return false;
        return switch (self.type_pool.get(type_id)) {
            .map_type => true,
            else => false,
        };
    }

    fn mapKeyValueTypes(self: *const LoweringContext, type_id: TypeId) struct { key: TypeId, value: TypeId } {
        return switch (self.type_pool.get(type_id)) {
            .map_type => |m| .{ .key = m.key, .value = m.value },
            else => .{ .key = types.null_type, .value = types.null_type },
        };
    }

    /// `m[k]` — Go-style: missing keys yield the zero value.
    fn lowerMapIndex(self: *LoweringContext, node_idx: NodeIndex) LowerError!ir.Ref {
        const node = self.tree.nodes.items[node_idx];
        const kv = self.mapKeyValueTypes(self.typeOfNode(node.data.lhs));
        const key_c = self.cTypeForTypeId(kv.key);
        const val_c = self.cTypeForTypeId(kv.value);

        const map_ref = try self.lowerExpr(node.data.lhs);
        const key_val = try self.lowerExpr(node.data.rhs);
        const key_local = try self.makeTempLocal("_mk", key_c, 0);
        try self.emit(ir.makeInst(.local_set, 0, key_local, key_val));
        const val_local = try self.makeTempLocal("_mv", val_c, self.alignmentForTypeId(kv.value));
        try self.emit(ir.makeInst(.local_zero, 0, val_local, 0));

        const key_addr = self.allocRef();
        try self.emit(ir.makeInst(.local_addr, key_addr, key_local, 0));
        const val_addr = self.allocRef();
        try self.emit(ir.makeInst(.local_addr, val_addr, val_local, 0));
        _ = try self.emitTypedCall("run_map_get", &.{ map_ref, key_addr, val_addr }, "bool", false);

        const r = self.allocRef();
        try self.emit(ir.makeInst(.local_get, r, val_local, 0));
        return r;
    }

    /// `m[k] = v`
    fn lowerMapIndexAssign(self: *LoweringContext, lhs_idx: NodeIndex, val_ref: ir.Ref) LowerError!void {
        const lhs = self.tree.nodes.items[lhs_idx];
        const kv = self.mapKeyValueTypes(self.typeOfNode(lhs.data.lhs));
        const key_c = self.cTypeForTypeId(kv.key);
        const val_c = self.cTypeForTypeId(kv.value);

        const map_ref = try self.lowerExpr(lhs.data.lhs);
        const key_val = try self.lowerExpr(lhs.data.rhs);
        const key_local = try self.makeTempLocal("_mk", key_c, 0);
        try self.emit(ir.makeInst(.local_set, 0, key_local, key_val));
        const val_local = try self.makeTempLocal("_mv", val_c, self.alignmentForTypeId(kv.value));
        try self.emit(ir.makeInst(.local_set, 0, val_local, val_ref));

        const key_addr = self.allocRef();
        try self.emit(ir.makeInst(.local_addr, key_addr, key_local, 0));
        const val_addr = self.allocRef();
        try self.emit(ir.makeInst(.local_addr, val_addr, val_local, 0));
        _ = try self.emitTypedCall("run_map_set", &.{ map_ref, key_addr, val_addr }, "void", false);
    }

    fn sliceElemType(self: *const LoweringContext, type_id: TypeId) TypeId {
        return switch (self.type_pool.get(type_id)) {
            .slice_type => |sl| sl.elem,
            else => types.null_type,
        };
    }

    /// Lower an expression into a named temp local (or reuse an existing
    /// local when the expression is a plain identifier). Returns the local
    /// index, or null if the expression failed to lower.
    fn exprToTempLocal(self: *LoweringContext, node_idx: NodeIndex, c_type: []const u8) LowerError!?u32 {
        const node = self.tree.nodes.items[node_idx];
        if (node.tag == .ident) {
            const name = self.tokenSlice(node.main_token);
            if (self.lookupLocalIdx(name)) |local_idx| return local_idx;
        }
        const val_ref = try self.lowerExpr(node_idx);
        if (val_ref == ir.null_ref) return null;
        const tmp_idx = try self.makeTempLocal("_tmp", c_type, 0);
        try self.emit(ir.makeInst(.local_set, 0, tmp_idx, val_ref));
        return tmp_idx;
    }

    /// `append(s, v)` — appends by value through the runtime and yields the
    /// (possibly reallocated) slice header value.
    fn lowerAppend(self: *LoweringContext, call_idx: NodeIndex, slice_node: NodeIndex, value_node: NodeIndex) LowerError!ir.Ref {
        const slice_type = self.typeOfNode(slice_node);
        if (!self.isSliceType(slice_type)) {
            try self.unsupported(call_idx, "append on this type");
            return ir.null_ref;
        }
        const elem_type = self.sliceElemType(slice_type);
        const elem_c = self.cTypeForTypeId(elem_type);

        // Copy the slice header into a temp so append can mutate it.
        const slice_val = try self.lowerExpr(slice_node);
        const slice_local = try self.makeTempLocal("_app_s", "run_slice_t", 0);
        try self.emit(ir.makeInst(.local_set, 0, slice_local, slice_val));

        // Element value into an addressable temp.
        const elem_val = try self.lowerExpr(value_node);
        const elem_local = try self.makeTempLocal("_app_v", elem_c, self.alignmentForTypeId(elem_type));
        try self.emit(ir.makeInst(.local_set, 0, elem_local, elem_val));

        const slice_addr = self.allocRef();
        try self.emit(ir.makeInst(.local_addr, slice_addr, slice_local, 0));
        const elem_addr = self.allocRef();
        try self.emit(ir.makeInst(.local_addr, elem_addr, elem_local, 0));
        _ = try self.emitTypedCall("run_slice_append", &.{ slice_addr, elem_addr }, "void", false);

        const r = self.allocRef();
        try self.emit(ir.makeInst(.local_get, r, slice_local, 0));
        return r;
    }

    /// `s[i]` — bounds-checked element read.
    fn lowerSliceIndex(self: *LoweringContext, node_idx: NodeIndex) LowerError!ir.Ref {
        const node = self.tree.nodes.items[node_idx];
        const slice_type = self.typeOfNode(node.data.lhs);
        const elem_type = self.sliceElemType(slice_type);
        const elem_c = self.cTypeForTypeId(elem_type);

        const slice_local = (try self.exprToTempLocal(node.data.lhs, "run_slice_t")) orelse return ir.null_ref;
        const idx_ref = try self.lowerExpr(node.data.rhs);
        const slice_addr = self.allocRef();
        try self.emit(ir.makeInst(.local_addr, slice_addr, slice_local, 0));
        const elem_ptr = try self.emitTypedCall("run_slice_get", &.{ slice_addr, idx_ref }, "void*", false);
        const type_idx = try self.module.addValueTypeName(self.allocator, elem_c);
        const r = self.allocRef();
        try self.emit(ir.makeInst(.ptr_load_value, r, elem_ptr, type_idx));
        return r;
    }

    /// `s[i] = v` — bounds-checked element write (slice variables only).
    fn lowerSliceIndexAssign(self: *LoweringContext, lhs_idx: NodeIndex, val_ref: ir.Ref) LowerError!void {
        const lhs = self.tree.nodes.items[lhs_idx];
        const slice_type = self.typeOfNode(lhs.data.lhs);
        const elem_type = self.sliceElemType(slice_type);
        const elem_c = self.cTypeForTypeId(elem_type);

        const slice_local = (try self.exprToTempLocal(lhs.data.lhs, "run_slice_t")) orelse return;
        const idx_ref = try self.lowerExpr(lhs.data.rhs);
        const slice_addr = self.allocRef();
        try self.emit(ir.makeInst(.local_addr, slice_addr, slice_local, 0));
        const elem_ptr = try self.emitTypedCall("run_slice_get", &.{ slice_addr, idx_ref }, "void*", false);
        const type_idx = try self.module.addValueTypeName(self.allocator, elem_c);
        try self.emit(ir.makeInst(.ptr_store_value, val_ref, elem_ptr, type_idx));
    }

    /// `for x in s { body }` over a slice: counted loop with a bounds-checked
    /// element load per iteration.
    fn lowerForSlice(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const func = self.current_func orelse return;
        const body_node = node.data.rhs;
        const var_name = self.tokenSlice(node.main_token + 1);

        const slice_type = self.typeOfNode(node.data.lhs);
        const elem_type = self.sliceElemType(slice_type);
        const elem_c = self.cTypeForTypeId(elem_type);

        const slice_local = (try self.exprToTempLocal(node.data.lhs, "run_slice_t")) orelse return;
        const fi_len = try self.module.addFieldInfo(self.allocator, "run_slice_t", "len", "int64_t");
        const len_local = try self.makeTempLocal("_for_len", "int64_t", 0);
        const len_ref = self.allocRef();
        try self.emit(ir.makeInst(.local_field_get, len_ref, slice_local, fi_len));
        try self.emit(ir.makeInst(.local_set, 0, len_local, len_ref));
        const idx_local = try self.makeTempLocal("_for_idx", "int64_t", 0);
        const zero_ref = self.allocRef();
        try self.emit(ir.makeConstInt(zero_ref, 0));
        try self.emit(ir.makeInst(.local_set, 0, idx_local, zero_ref));

        const entry_bb = self.currentBlockId() orelse return;
        const cond_bb = try func.addBlock(self.allocator);
        const body_bb = try func.addBlock(self.allocator);
        const step_bb = try func.addBlock(self.allocator);
        const after_bb = try func.addBlock(self.allocator);
        self.current_block = func.getBlock(entry_bb);
        try self.emit(ir.makeInst(.br, 0, cond_bb, 0));

        self.current_block = func.getBlock(cond_bb);
        const i_ref = self.allocRef();
        try self.emit(ir.makeInst(.local_get, i_ref, idx_local, 0));
        const n_ref = self.allocRef();
        try self.emit(ir.makeInst(.local_get, n_ref, len_local, 0));
        const cmp_ref = self.allocRef();
        try self.emit(ir.makeInst(.lt, cmp_ref, i_ref, n_ref));
        try self.emit(ir.makeInst(.br_cond, 0, cmp_ref, body_bb));
        try self.emit(ir.makeInst(.br, 0, after_bb, 0));

        self.current_block = func.getBlock(body_bb);
        try self.loop_stack.append(self.allocator, .{
            .break_bb = after_bb,
            .continue_bb = step_bb,
            .defer_depth = self.defer_stack.items.len,
            .owned_depth = self.owned_stack.items.len,
        });
        try self.pushScope();
        // x = s[i]
        const slice_addr = self.allocRef();
        try self.emit(ir.makeInst(.local_addr, slice_addr, slice_local, 0));
        const cur_idx = self.allocRef();
        try self.emit(ir.makeInst(.local_get, cur_idx, idx_local, 0));
        const elem_ptr = try self.emitTypedCall("run_slice_get", &.{ slice_addr, cur_idx }, "void*", false);
        const type_idx = try self.module.addValueTypeName(self.allocator, elem_c);
        const elem_ref = self.allocRef();
        try self.emit(ir.makeInst(.ptr_load_value, elem_ref, elem_ptr, type_idx));
        _ = try self.defineVar(var_name, elem_c, self.alignmentForTypeId(elem_type), elem_ref);

        try self.lowerBlock(body_node);
        try self.popScope();
        _ = self.loop_stack.pop();
        if (!self.current_block.?.isTerminated()) {
            try self.emit(ir.makeInst(.br, 0, step_bb, 0));
        }

        self.current_block = func.getBlock(step_bb);
        const cur2 = self.allocRef();
        try self.emit(ir.makeInst(.local_get, cur2, idx_local, 0));
        const one_ref = self.allocRef();
        try self.emit(ir.makeConstInt(one_ref, 1));
        const next_ref = self.allocRef();
        try self.emit(ir.makeInst(.add, next_ref, cur2, one_ref));
        try self.emit(ir.makeInst(.local_set, 0, idx_local, next_ref));
        try self.emit(ir.makeInst(.br, 0, cond_bb, 0));

        self.current_block = func.getBlock(after_bb);
    }

    /// `for i, x in s { body }` over a slice: like lowerForSlice but also
    /// binds the index. The variable names live only in the token stream:
    /// `for` IDENT `,` IDENT `in` ... (same trick as resolve.zig).
    fn lowerForIndexValue(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const func = self.current_func orelse return;
        const body_node = node.data.rhs;

        var scan = node.main_token + 1;
        while (scan < self.tokens.len and self.tokens[scan].tag == .newline) : (scan += 1) {}
        if (scan >= self.tokens.len or self.tokens[scan].tag != .identifier) {
            return self.unsupported(node_idx, "this 'for index, value' form");
        }
        const idx_name = self.tokenSlice(scan);
        scan += 1;
        while (scan < self.tokens.len and (self.tokens[scan].tag == .comma or self.tokens[scan].tag == .newline)) : (scan += 1) {}
        if (scan >= self.tokens.len or self.tokens[scan].tag != .identifier) {
            return self.unsupported(node_idx, "this 'for index, value' form");
        }
        const val_name = self.tokenSlice(scan);

        const slice_type = self.typeOfNode(node.data.lhs);
        if (self.isMapType(slice_type)) {
            return self.lowerForMap(node_idx, idx_name, val_name);
        }
        if (!self.isSliceType(slice_type)) {
            return self.unsupported(node_idx, "'for index, value in ...' over a non-slice iterable");
        }
        const elem_type = self.sliceElemType(slice_type);
        const elem_c = self.cTypeForTypeId(elem_type);

        const slice_local = (try self.exprToTempLocal(node.data.lhs, "run_slice_t")) orelse return;
        const fi_len = try self.module.addFieldInfo(self.allocator, "run_slice_t", "len", "int64_t");
        const len_local = try self.makeTempLocal("_for_len", "int64_t", 0);
        const len_ref = self.allocRef();
        try self.emit(ir.makeInst(.local_field_get, len_ref, slice_local, fi_len));
        try self.emit(ir.makeInst(.local_set, 0, len_local, len_ref));
        const idx_local = try self.makeTempLocal("_for_idx", "int64_t", 0);
        const zero_ref = self.allocRef();
        try self.emit(ir.makeConstInt(zero_ref, 0));
        try self.emit(ir.makeInst(.local_set, 0, idx_local, zero_ref));

        const entry_bb = self.currentBlockId() orelse return;
        const cond_bb = try func.addBlock(self.allocator);
        const body_bb = try func.addBlock(self.allocator);
        const step_bb = try func.addBlock(self.allocator);
        const after_bb = try func.addBlock(self.allocator);
        self.current_block = func.getBlock(entry_bb);
        try self.emit(ir.makeInst(.br, 0, cond_bb, 0));

        self.current_block = func.getBlock(cond_bb);
        const i_ref = self.allocRef();
        try self.emit(ir.makeInst(.local_get, i_ref, idx_local, 0));
        const n_ref = self.allocRef();
        try self.emit(ir.makeInst(.local_get, n_ref, len_local, 0));
        const cmp_ref = self.allocRef();
        try self.emit(ir.makeInst(.lt, cmp_ref, i_ref, n_ref));
        try self.emit(ir.makeInst(.br_cond, 0, cmp_ref, body_bb));
        try self.emit(ir.makeInst(.br, 0, after_bb, 0));

        self.current_block = func.getBlock(body_bb);
        try self.loop_stack.append(self.allocator, .{
            .break_bb = after_bb,
            .continue_bb = step_bb,
            .defer_depth = self.defer_stack.items.len,
            .owned_depth = self.owned_stack.items.len,
        });
        try self.pushScope();
        const cur_idx = self.allocRef();
        try self.emit(ir.makeInst(.local_get, cur_idx, idx_local, 0));
        if (!std.mem.eql(u8, idx_name, "_")) {
            _ = try self.defineVar(idx_name, "int64_t", 0, cur_idx);
        }
        if (!std.mem.eql(u8, val_name, "_")) {
            const slice_addr = self.allocRef();
            try self.emit(ir.makeInst(.local_addr, slice_addr, slice_local, 0));
            const elem_ptr = try self.emitTypedCall("run_slice_get", &.{ slice_addr, cur_idx }, "void*", false);
            const type_idx = try self.module.addValueTypeName(self.allocator, elem_c);
            const elem_ref = self.allocRef();
            try self.emit(ir.makeInst(.ptr_load_value, elem_ref, elem_ptr, type_idx));
            _ = try self.defineVar(val_name, elem_c, self.alignmentForTypeId(elem_type), elem_ref);
        }

        try self.lowerBlock(body_node);
        try self.popScope();
        _ = self.loop_stack.pop();
        if (!self.current_block.?.isTerminated()) {
            try self.emit(ir.makeInst(.br, 0, step_bb, 0));
        }

        self.current_block = func.getBlock(step_bb);
        const cur2 = self.allocRef();
        try self.emit(ir.makeInst(.local_get, cur2, idx_local, 0));
        const one_ref = self.allocRef();
        try self.emit(ir.makeConstInt(one_ref, 1));
        const next_ref = self.allocRef();
        try self.emit(ir.makeInst(.add, next_ref, cur2, one_ref));
        try self.emit(ir.makeInst(.local_set, 0, idx_local, next_ref));
        try self.emit(ir.makeInst(.br, 0, cond_bb, 0));

        self.current_block = func.getBlock(after_bb);
    }

    /// `for k, v in m { body }` over a map, via the runtime iterator. The
    /// iterator yields pointers into map storage; key/value are copied out
    /// before the body runs.
    fn lowerForMap(self: *LoweringContext, node_idx: NodeIndex, key_name: []const u8, val_name: []const u8) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const func = self.current_func orelse return;
        const body_node = node.data.rhs;
        const kv = self.mapKeyValueTypes(self.typeOfNode(node.data.lhs));
        const key_c = self.cTypeForTypeId(kv.key);
        const val_c = self.cTypeForTypeId(kv.value);

        const map_ref = try self.lowerExpr(node.data.lhs);
        const iter_local = try self.makeTempLocal("_miter", "run_map_iter_t", 0);
        const kptr_local = try self.makeTempLocal("_mkptr", "const void*", 0);
        const vptr_local = try self.makeTempLocal("_mvptr", "const void*", 0);
        const iter_addr0 = self.allocRef();
        try self.emit(ir.makeInst(.local_addr, iter_addr0, iter_local, 0));
        _ = try self.emitTypedCall("run_map_iter_init", &.{ iter_addr0, map_ref }, "void", false);

        const entry_bb = self.currentBlockId() orelse return;
        const cond_bb = try func.addBlock(self.allocator);
        const body_bb = try func.addBlock(self.allocator);
        const after_bb = try func.addBlock(self.allocator);
        self.current_block = func.getBlock(entry_bb);
        try self.emit(ir.makeInst(.br, 0, cond_bb, 0));

        self.current_block = func.getBlock(cond_bb);
        const iter_addr = self.allocRef();
        try self.emit(ir.makeInst(.local_addr, iter_addr, iter_local, 0));
        const kptr_addr = self.allocRef();
        try self.emit(ir.makeInst(.local_addr, kptr_addr, kptr_local, 0));
        const vptr_addr = self.allocRef();
        try self.emit(ir.makeInst(.local_addr, vptr_addr, vptr_local, 0));
        const found_ref = try self.emitTypedCall("run_map_iter_next", &.{ iter_addr, kptr_addr, vptr_addr }, "bool", false);
        try self.emit(ir.makeInst(.br_cond, 0, found_ref, body_bb));
        try self.emit(ir.makeInst(.br, 0, after_bb, 0));

        self.current_block = func.getBlock(body_bb);
        try self.loop_stack.append(self.allocator, .{
            .break_bb = after_bb,
            .continue_bb = cond_bb,
            .defer_depth = self.defer_stack.items.len,
            .owned_depth = self.owned_stack.items.len,
        });
        try self.pushScope();
        if (!std.mem.eql(u8, key_name, "_")) {
            const kp = self.allocRef();
            try self.emit(ir.makeInst(.local_get, kp, kptr_local, 0));
            const ktype = try self.module.addValueTypeName(self.allocator, key_c);
            const k_ref = self.allocRef();
            try self.emit(ir.makeInst(.ptr_load_value, k_ref, kp, ktype));
            _ = try self.defineVar(key_name, key_c, self.alignmentForTypeId(kv.key), k_ref);
        }
        if (!std.mem.eql(u8, val_name, "_")) {
            const vp = self.allocRef();
            try self.emit(ir.makeInst(.local_get, vp, vptr_local, 0));
            const vtype = try self.module.addValueTypeName(self.allocator, val_c);
            const v_ref = self.allocRef();
            try self.emit(ir.makeInst(.ptr_load_value, v_ref, vp, vtype));
            _ = try self.defineVar(val_name, val_c, self.alignmentForTypeId(kv.value), v_ref);
        }
        try self.lowerBlock(body_node);
        try self.popScope();
        _ = self.loop_stack.pop();
        if (!self.current_block.?.isTerminated()) {
            try self.emit(ir.makeInst(.br, 0, cond_bb, 0));
        }

        self.current_block = func.getBlock(after_bb);
    }

    fn isNullableType(self: *const LoweringContext, type_id: TypeId) bool {
        if (type_id == types.null_type or type_id < types.primitives.count) return false;
        return switch (self.type_pool.get(type_id)) {
            .nullable_type => true,
            else => false,
        };
    }

    fn nullablePayload(self: *const LoweringContext, type_id: TypeId) TypeId {
        return switch (self.type_pool.get(type_id)) {
            .nullable_type => |nt| nt.inner,
            else => types.null_type,
        };
    }

    /// Build a T? value in a temp local. `payload_ref == null_ref` builds
    /// the null variant; otherwise wraps the payload.
    fn buildOptValue(self: *LoweringContext, opt_type: TypeId, payload_ref: ir.Ref) LowerError!ir.Ref {
        const opt_c = self.struct_c_names.get(opt_type) orelse "int64_t";
        const tmp_idx = try self.makeTempLocal("_opt", opt_c, 0);
        try self.emit(ir.makeInst(.local_zero, 0, tmp_idx, 0));
        if (payload_ref != ir.null_ref) {
            const true_ref = self.allocRef();
            try self.emit(ir.makeInst(.const_bool, true_ref, 1, 0));
            const fi_has = try self.module.addFieldInfo(self.allocator, opt_c, "has_value", "bool");
            try self.emit(ir.makeInst(.local_field_set, true_ref, tmp_idx, fi_has));
            const payload = self.nullablePayload(opt_type);
            const fi_val = try self.module.addFieldInfo(self.allocator, opt_c, "value", self.cTypeForTypeId(payload));
            try self.emit(ir.makeInst(.local_field_set, payload_ref, tmp_idx, fi_val));
        }
        const r = self.allocRef();
        try self.emit(ir.makeInst(.local_get, r, tmp_idx, 0));
        return r;
    }

    /// Lower `value_node` and adapt it to `target_type` where the language
    /// allows implicit wrapping (T -> T?, null -> T?). Returns the value ref.
    fn lowerCoerced(self: *LoweringContext, target_type: TypeId, value_node: NodeIndex) LowerError!ir.Ref {
        if (value_node == null_node) return ir.null_ref;
        if (self.isNullableType(target_type)) {
            if (self.tree.nodes.items[value_node].tag == .null_literal) {
                return self.buildOptValue(target_type, ir.null_ref);
            }
            const value_type = self.typeOfNode(value_node);
            if (!self.isNullableType(value_type)) {
                const payload_ref = try self.lowerExpr(value_node);
                return self.buildOptValue(target_type, payload_ref);
            }
        }
        return self.lowerExpr(value_node);
    }

    /// Switch on a nullable: `.some(x) :: ...` / `.null :: ...` / `_`.
    fn lowerNullableSwitch(self: *LoweringContext, node_idx: NodeIndex, arm_nodes: []const NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const func = self.current_func orelse return;
        const subject_type = self.typeOfNode(node.data.lhs);
        const opt_c = self.struct_c_names.get(subject_type) orelse "int64_t";
        const payload = self.nullablePayload(subject_type);

        const subj_ref = try self.lowerExpr(node.data.lhs);
        const subj_idx = try self.makeTempLocal("_switch_opt", opt_c, 0);
        try self.emit(ir.makeInst(.local_set, 0, subj_idx, subj_ref));
        const fi_has = try self.module.addFieldInfo(self.allocator, opt_c, "has_value", "bool");

        const entry_bb = self.currentBlockId() orelse return;
        const after_bb = try func.addBlock(self.allocator);
        var test_bbs: std.ArrayList(ir.BlockId) = .empty;
        defer test_bbs.deinit(self.allocator);
        var body_bbs: std.ArrayList(ir.BlockId) = .empty;
        defer body_bbs.deinit(self.allocator);
        for (arm_nodes) |_| {
            try test_bbs.append(self.allocator, try func.addBlock(self.allocator));
            try body_bbs.append(self.allocator, try func.addBlock(self.allocator));
        }
        self.current_block = func.getBlock(entry_bb);
        try self.emit(ir.makeInst(.br, 0, if (arm_nodes.len > 0) test_bbs.items[0] else after_bb, 0));

        for (arm_nodes, 0..) |arm, k| {
            const next_target = if (k + 1 < arm_nodes.len) test_bbs.items[k + 1] else after_bb;
            const arm_node = self.tree.nodes.items[arm];
            const pat_idx = arm_node.data.lhs;

            var is_some_arm = false;
            var is_null_arm = false;
            var payload_name: []const u8 = "";
            if (pat_idx != null_node) {
                const pat = self.tree.nodes.items[pat_idx];
                if (pat.tag == .variant) {
                    const vname_tok = pat.main_token + 1;
                    const vname = if (vname_tok < self.tokens.len) self.tokenSlice(vname_tok) else "";
                    is_some_arm = std.mem.eql(u8, vname, "some");
                    is_null_arm = std.mem.eql(u8, vname, "null");
                    if (pat.data.lhs != null_node and self.tree.nodes.items[pat.data.lhs].tag == .ident) {
                        payload_name = self.tokenSlice(self.tree.nodes.items[pat.data.lhs].main_token);
                    }
                } else if (pat.tag == .null_literal) {
                    is_null_arm = true;
                }
            }

            self.current_block = func.getBlock(test_bbs.items[k]);
            if (is_some_arm or is_null_arm) {
                const h_ref = self.allocRef();
                try self.emit(ir.makeInst(.local_field_get, h_ref, subj_idx, fi_has));
                const cond_ref = if (is_some_arm) h_ref else blk: {
                    const not_ref = self.allocRef();
                    try self.emit(ir.makeInst(.log_not, not_ref, h_ref, 0));
                    break :blk not_ref;
                };
                try self.emit(ir.makeInst(.br_cond, 0, cond_ref, body_bbs.items[k]));
                try self.emit(ir.makeInst(.br, 0, next_target, 0));
            } else {
                try self.emit(ir.makeInst(.br, 0, body_bbs.items[k], 0));
            }

            self.current_block = func.getBlock(body_bbs.items[k]);
            try self.pushScope();
            if (is_some_arm and payload_name.len > 0 and !std.mem.eql(u8, payload_name, "_") and
                payload != types.null_type)
            {
                const fi_val = try self.module.addFieldInfo(self.allocator, opt_c, "value", self.cTypeForTypeId(payload));
                const v_ref = self.allocRef();
                try self.emit(ir.makeInst(.local_field_get, v_ref, subj_idx, fi_val));
                _ = try self.defineVar(payload_name, self.cTypeForTypeId(payload), self.alignmentForTypeId(payload), v_ref);
            }
            const body_idx = arm_node.data.rhs;
            if (body_idx != null_node) {
                if (self.tree.nodes.items[body_idx].tag == .block) {
                    try self.lowerBlock(body_idx);
                } else {
                    _ = try self.lowerExpr(body_idx);
                }
            }
            try self.popScope();
            if (self.current_block != null and !self.current_block.?.isTerminated()) {
                try self.emit(ir.makeInst(.br, 0, after_bb, 0));
            }
        }

        self.current_block = func.getBlock(after_bb);
    }

    /// True if a switch pattern is the wildcard `_`.
    fn isWildcardPattern(self: *const LoweringContext, pat_idx: NodeIndex) bool {
        if (pat_idx == null_node) return false;
        const pat = self.tree.nodes.items[pat_idx];
        return pat.tag == .ident and std.mem.eql(u8, self.tokenSlice(pat.main_token), "_");
    }

    /// Emit `subject == pattern` with the right equality for the subject type.
    fn emitPatternEq(self: *LoweringContext, subj_ref: ir.Ref, pat_ref: ir.Ref, is_string: bool) LowerError!ir.Ref {
        if (is_string) {
            return self.emitTypedCall("run_string_eq", &.{ subj_ref, pat_ref }, "bool", false);
        }
        const r = self.allocRef();
        try self.emit(ir.makeInst(.eq, r, subj_ref, pat_ref));
        return r;
    }

    /// Lower a value switch as a chain of test blocks. Each arm gets a test
    /// block (compare against each alternative pattern) and a body block;
    /// failed tests fall through to the next arm's test block.
    fn lowerSwitchStmt(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const func = self.current_func orelse return;
        const extra = self.tree.extra_data.items;

        const arms_start = node.data.rhs;
        const arm_count = self.findTrailingCount(arms_start);
        const arm_nodes = extra[arms_start .. arms_start + arm_count];

        // Error-union subjects destructure with .ok(x)/.err(e) arms.
        if (self.isErrorUnion(self.typeOfNode(node.data.lhs))) {
            return self.lowerErrorUnionSwitch(node_idx, arm_nodes);
        }

        // Nullable subjects destructure with .some(x)/.null arms.
        if (self.isNullableType(self.typeOfNode(node.data.lhs))) {
            return self.lowerNullableSwitch(node_idx, arm_nodes);
        }

        // Variant patterns on sum types need payload destructuring that has
        // no lowering yet — fail loudly.
        for (arm_nodes) |arm| {
            if (arm == null_node) continue;
            const pat_idx = self.tree.nodes.items[arm].data.lhs;
            if (pat_idx != null_node and self.tree.nodes.items[pat_idx].tag == .variant) {
                return self.unsupported(node_idx, "switch over sum-type variants");
            }
        }

        const subject_node = node.data.lhs;
        const subject_is_string = self.typeOfNode(subject_node) == types.primitives.string_id;
        const subj_ref = try self.lowerExpr(subject_node);
        const subj_c_type = if (subject_is_string) "run_string_t" else self.cTypeForNode(subject_node);
        const subj_name = try std.fmt.allocPrint(self.allocator, "_switch_subj_{d}", .{func.next_ref});
        try self.module.owned_strings.append(self.allocator, subj_name);
        const subj_idx = try self.module.addLocalInfoAligned(self.allocator, subj_name, subj_c_type, 0);
        try self.emit(ir.makeInst(.local_set, 0, subj_idx, subj_ref));

        // Capture the entry block id only after the subject is lowered (it
        // can move the current block), and re-fetch the pointer after
        // addBlock calls (they can reallocate the array).
        const entry_bb = self.currentBlockId() orelse return;
        const after_bb = try func.addBlock(self.allocator);
        var test_bbs: std.ArrayList(ir.BlockId) = .empty;
        defer test_bbs.deinit(self.allocator);
        var body_bbs: std.ArrayList(ir.BlockId) = .empty;
        defer body_bbs.deinit(self.allocator);
        for (arm_nodes) |_| {
            try test_bbs.append(self.allocator, try func.addBlock(self.allocator));
            try body_bbs.append(self.allocator, try func.addBlock(self.allocator));
        }

        self.current_block = func.getBlock(entry_bb);
        try self.emit(ir.makeInst(.br, 0, if (arm_nodes.len > 0) test_bbs.items[0] else after_bb, 0));

        for (arm_nodes, 0..) |arm, k| {
            const next_target = if (k + 1 < arm_nodes.len) test_bbs.items[k + 1] else after_bb;
            const arm_node = self.tree.nodes.items[arm];
            const pat_idx = arm_node.data.lhs;

            self.current_block = func.getBlock(test_bbs.items[k]);
            if (pat_idx == null_node or self.isWildcardPattern(pat_idx)) {
                try self.emit(ir.makeInst(.br, 0, body_bbs.items[k], 0));
            } else if (self.tree.nodes.items[pat_idx].tag == .tuple_literal) {
                // Multi-pattern arm: `2, 3 :: body` — any match enters the body.
                const pats_start = self.tree.nodes.items[pat_idx].data.rhs;
                const pat_count = self.findTrailingCount(pats_start);
                const pat_nodes = extra[pats_start .. pats_start + pat_count];
                for (pat_nodes) |p| {
                    const s_ref = self.allocRef();
                    try self.emit(ir.makeInst(.local_get, s_ref, subj_idx, 0));
                    const p_ref = try self.lowerExpr(p);
                    const eq_ref = try self.emitPatternEq(s_ref, p_ref, subject_is_string);
                    try self.emit(ir.makeInst(.br_cond, 0, eq_ref, body_bbs.items[k]));
                }
                try self.emit(ir.makeInst(.br, 0, next_target, 0));
            } else {
                const s_ref = self.allocRef();
                try self.emit(ir.makeInst(.local_get, s_ref, subj_idx, 0));
                const p_ref = try self.lowerExpr(pat_idx);
                const eq_ref = try self.emitPatternEq(s_ref, p_ref, subject_is_string);
                try self.emit(ir.makeInst(.br_cond, 0, eq_ref, body_bbs.items[k]));
                try self.emit(ir.makeInst(.br, 0, next_target, 0));
            }

            self.current_block = func.getBlock(body_bbs.items[k]);
            try self.pushScope();
            const body_idx = arm_node.data.rhs;
            if (body_idx != null_node) {
                if (self.tree.nodes.items[body_idx].tag == .block) {
                    try self.lowerBlock(body_idx);
                } else {
                    _ = try self.lowerExpr(body_idx);
                }
            }
            try self.popScope();
            if (self.current_block != null and !self.current_block.?.isTerminated()) {
                try self.emit(ir.makeInst(.br, 0, after_bb, 0));
            }
        }

        self.current_block = func.getBlock(after_bb);
    }

    /// Switch on an error union: `.ok(x) :: ...` / `.err(e) :: ...` / `_`.
    fn lowerErrorUnionSwitch(self: *LoweringContext, node_idx: NodeIndex, arm_nodes: []const NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const func = self.current_func orelse return;
        const subject_type = self.typeOfNode(node.data.lhs);
        const eu_c = self.struct_c_names.get(subject_type) orelse "int64_t";
        const payload = self.errUnionPayload(subject_type);

        const subj_ref = try self.lowerExpr(node.data.lhs);
        const subj_idx = try self.makeTempLocal("_switch_eu", eu_c, 0);
        try self.emit(ir.makeInst(.local_set, 0, subj_idx, subj_ref));
        const fi_err = try self.module.addFieldInfo(self.allocator, eu_c, "is_error", "bool");

        const entry_bb = self.currentBlockId() orelse return;
        const after_bb = try func.addBlock(self.allocator);
        var test_bbs: std.ArrayList(ir.BlockId) = .empty;
        defer test_bbs.deinit(self.allocator);
        var body_bbs: std.ArrayList(ir.BlockId) = .empty;
        defer body_bbs.deinit(self.allocator);
        for (arm_nodes) |_| {
            try test_bbs.append(self.allocator, try func.addBlock(self.allocator));
            try body_bbs.append(self.allocator, try func.addBlock(self.allocator));
        }

        self.current_block = func.getBlock(entry_bb);
        try self.emit(ir.makeInst(.br, 0, if (arm_nodes.len > 0) test_bbs.items[0] else after_bb, 0));

        for (arm_nodes, 0..) |arm, k| {
            const next_target = if (k + 1 < arm_nodes.len) test_bbs.items[k + 1] else after_bb;
            const arm_node = self.tree.nodes.items[arm];
            const pat_idx = arm_node.data.lhs;

            var is_ok_arm = false;
            var is_err_arm = false;
            var payload_name: []const u8 = "";
            if (pat_idx != null_node and self.tree.nodes.items[pat_idx].tag == .variant) {
                const pat = self.tree.nodes.items[pat_idx];
                const vname_tok = pat.main_token + 1;
                const vname = if (vname_tok < self.tokens.len) self.tokenSlice(vname_tok) else "";
                is_ok_arm = std.mem.eql(u8, vname, "ok");
                is_err_arm = std.mem.eql(u8, vname, "err");
                if (pat.data.lhs != null_node and self.tree.nodes.items[pat.data.lhs].tag == .ident) {
                    payload_name = self.tokenSlice(self.tree.nodes.items[pat.data.lhs].main_token);
                }
            }

            self.current_block = func.getBlock(test_bbs.items[k]);
            if (is_ok_arm or is_err_arm) {
                const e_ref = self.allocRef();
                try self.emit(ir.makeInst(.local_field_get, e_ref, subj_idx, fi_err));
                const cond_ref = if (is_err_arm) e_ref else blk: {
                    const not_ref = self.allocRef();
                    try self.emit(ir.makeInst(.log_not, not_ref, e_ref, 0));
                    break :blk not_ref;
                };
                try self.emit(ir.makeInst(.br_cond, 0, cond_ref, body_bbs.items[k]));
                try self.emit(ir.makeInst(.br, 0, next_target, 0));
            } else {
                // Wildcard (or unrecognized pattern): always matches.
                try self.emit(ir.makeInst(.br, 0, body_bbs.items[k], 0));
            }

            self.current_block = func.getBlock(body_bbs.items[k]);
            try self.pushScope();
            if (payload_name.len > 0 and !std.mem.eql(u8, payload_name, "_")) {
                if (is_ok_arm and payload != types.null_type and payload != types.primitives.void_id) {
                    const fi_val = try self.module.addFieldInfo(self.allocator, eu_c, "value", self.cTypeForTypeId(payload));
                    const v_ref = self.allocRef();
                    try self.emit(ir.makeInst(.local_field_get, v_ref, subj_idx, fi_val));
                    _ = try self.defineVar(payload_name, self.cTypeForTypeId(payload), self.alignmentForTypeId(payload), v_ref);
                } else if (is_err_arm) {
                    const fi_msg = try self.module.addFieldInfo(self.allocator, eu_c, "error_msg", "run_string_t");
                    const m_ref = self.allocRef();
                    try self.emit(ir.makeInst(.local_field_get, m_ref, subj_idx, fi_msg));
                    _ = try self.defineVar(payload_name, "run_string_t", 0, m_ref);
                }
            }
            const body_idx = arm_node.data.rhs;
            if (body_idx != null_node) {
                if (self.tree.nodes.items[body_idx].tag == .block) {
                    try self.lowerBlock(body_idx);
                } else {
                    _ = try self.lowerExpr(body_idx);
                }
            }
            try self.popScope();
            if (self.current_block != null and !self.current_block.?.isTerminated()) {
                try self.emit(ir.makeInst(.br, 0, after_bb, 0));
            }
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
                try self.emit(ir.makeConstInt(r, val));
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
                // String equality compares contents via the runtime, not the
                // run_string_t struct representation.
                if (self.typeOfNode(node.data.lhs) == types.primitives.string_id) {
                    switch (self.tokens[op_tok].tag) {
                        .plus => return self.emitTypedCall("run_string_concat", &.{ lhs_ref, rhs_ref }, "run_string_t", false),
                        .equal_equal => return self.emitTypedCall("run_string_eq", &.{ lhs_ref, rhs_ref }, "bool", false),
                        .bang_equal => {
                            const eq_ref = try self.emitTypedCall("run_string_eq", &.{ lhs_ref, rhs_ref }, "bool", false);
                            const r = self.allocRef();
                            try self.emit(ir.makeInst(.log_not, r, eq_ref, 0));
                            return r;
                        },
                        else => {},
                    }
                }
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
            .array_literal => {
                try self.unsupported(node_idx, "array literals");
                return ir.null_ref;
            },
            .tuple_literal => {
                try self.unsupported(node_idx, "tuple literals");
                return ir.null_ref;
            },
            .alloc_expr => {
                // alloc(Type, capacity?) — check if this is a channel allocation
                const type_node_idx = node.data.lhs;
                const extra_start = node.data.rhs;

                // Map allocation: alloc(map[K]V) — capacity hint unused for now.
                if (type_node_idx != null_node and self.tree.nodes.items[type_node_idx].tag == .type_map) {
                    const map_type = self.resolveTypeNode(type_node_idx);
                    const kv = switch (self.type_pool.get(map_type)) {
                        .map_type => |m| .{ m.key, m.value },
                        else => .{ types.null_type, types.null_type },
                    };
                    const key_size_ref = self.allocRef();
                    try self.emit(ir.makeConstInt(key_size_ref, if (kv[0] != types.null_type) self.sizeOfTypeId(kv[0]) else 8));
                    const val_size_ref = self.allocRef();
                    try self.emit(ir.makeConstInt(val_size_ref, if (kv[1] != types.null_type) self.sizeOfTypeId(kv[1]) else 8));
                    const kind_ref = self.allocRef();
                    try self.emit(ir.makeConstInt(kind_ref, if (kv[0] == types.primitives.string_id) 1 else 0));
                    return self.emitTypedCall("run_map_new_typed", &.{ key_size_ref, val_size_ref, kind_ref }, "run_map_t*", false);
                }

                // Slice allocation: alloc([]T) or alloc([]T, capacity)
                if (type_node_idx != null_node and self.tree.nodes.items[type_node_idx].tag == .type_slice) {
                    const slice_type = self.resolveTypeNode(type_node_idx);
                    const elem_type = switch (self.type_pool.get(slice_type)) {
                        .slice_type => |sl| sl.elem,
                        else => types.null_type,
                    };
                    const elem_size = if (elem_type != types.null_type) self.sizeOfTypeId(elem_type) else 8;
                    const elem_size_ref = self.allocRef();
                    try self.emit(ir.makeConstInt(elem_size_ref, elem_size));
                    const cap_node = self.tree.extra_data.items[extra_start];
                    var cap_ref: ir.Ref = undefined;
                    if (cap_node != null_node) {
                        cap_ref = try self.lowerExpr(cap_node);
                    } else {
                        cap_ref = self.allocRef();
                        try self.emit(ir.makeConstInt(cap_ref, 0));
                    }
                    return self.emitTypedCall("run_slice_new", &.{ elem_size_ref, cap_ref }, "run_slice_t", false);
                }

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
                if (self.isSliceType(self.typeOfNode(node.data.lhs))) {
                    return try self.lowerSliceIndex(node_idx);
                }
                if (self.isMapType(self.typeOfNode(node.data.lhs))) {
                    return try self.lowerMapIndex(node_idx);
                }
                try self.unsupported(node_idx, "indexing this type");
                return ir.null_ref;
            },
            .addr_of, .addr_of_const => {
                // &ident/@ident should capture the local's storage, not its
                // loaded value. Stack slots have no allocation header, so the
                // reference is created unchecked (generation 0) instead of
                // reading garbage where a heap header would be.
                const operand_node = node.data.lhs;
                if (operand_node != null_node and self.tree.nodes.items[operand_node].tag == .ident) {
                    const name = self.tokenSlice(self.tree.nodes.items[operand_node].main_token);
                    if (self.lookupLocalIdx(name)) |local_idx| {
                        const local_ptr = self.allocRef();
                        try self.emit(ir.makeInst(.local_addr, local_ptr, local_idx, 0));
                        const ref_result = self.allocRef();
                        try self.emit(ir.makeInst(.gen_ref_stack, ref_result, local_ptr, 0));
                        return ref_result;
                    }
                }

                const ptr_ref = try self.lowerExpr(operand_node);
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
            .field_access => return try self.lowerFieldAccess(node_idx),
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
            .struct_literal => return try self.lowerStructLiteral(node_idx),
            .anon_struct_literal => {
                try self.unsupported(node_idx, "anonymous struct literals");
                return ir.null_ref;
            },
            .closure => return try self.lowerClosureLifted(node_idx, null),
            .variant => {
                try self.unsupported(node_idx, "sum-type variants");
                return ir.null_ref;
            },
            .try_expr => return try self.lowerTryExpr(node_idx),
            else => {
                try self.unsupported(node_idx, "this expression");
                return ir.null_ref;
            },
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
        const current_bb = self.currentBlockId() orelse return ir.null_ref;
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

        self.current_block = func.getBlock(current_bb);
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

    /// Find a nominal type (struct, newtype, sum, interface) by name. Later
    /// pool entries win, matching typecheck's final registrations.
    fn findNamedType(self: *const LoweringContext, name: []const u8) TypeId {
        var result: TypeId = types.null_type;
        for (self.type_pool.types.items, 0..) |typ, i| {
            const type_name = switch (typ) {
                .struct_type => |st| st.name,
                .newtype => |nt| nt.name,
                .sum_type => |st| st.name,
                .interface_type => |it| it.name,
                else => continue,
            };
            if (std.mem.eql(u8, type_name, name)) result = @intCast(i);
        }
        return result;
    }

    fn resolveTypeNode(self: *LoweringContext, node_idx: NodeIndex) TypeId {
        if (node_idx == null_node) return types.null_type;
        const node = self.tree.nodes.items[node_idx];
        return switch (node.tag) {
            .type_name, .ident => blk: {
                const name = self.tokenSlice(node.main_token);
                if (TypePool.lookupPrimitive(name)) |prim| break :blk prim;
                const typed = self.typeOfNode(node_idx);
                if (typed != types.null_type) break :blk typed;
                // Type nodes (e.g. method receiver types) are not in the
                // typecheck type_map; resolve nominal types by pool scan.
                break :blk self.findNamedType(name);
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
            .type_array => blk: {
                const inner = self.resolveTypeNode(node.data.lhs);
                if (inner == types.null_type) break :blk types.null_type;
                break :blk @constCast(self.type_pool).intern(self.allocator, .{ .array_type = .{
                    .elem = inner,
                    .len = node.data.rhs,
                } }) catch types.null_type;
            },
            .type_fn => blk: {
                const extra = self.tree.extra_data.items;
                const param_count = self.findTrailingCount(node.data.lhs);
                const param_nodes = extra[node.data.lhs .. node.data.lhs + param_count];

                var param_types: std.ArrayList(TypeId) = .empty;
                defer param_types.deinit(self.allocator);
                var is_variadic = false;

                for (param_nodes) |param_node| {
                    if (param_node == null_node) {
                        param_types.append(self.allocator, types.null_type) catch break :blk types.null_type;
                        continue;
                    }

                    if (self.tree.nodes.items[param_node].tag == .variadic_param) is_variadic = true;
                    const param_type = self.resolveTypeNode(self.tree.nodes.items[param_node].data.lhs);
                    param_types.append(self.allocator, param_type) catch break :blk types.null_type;
                }

                const owned_params = self.allocator.alloc(TypeId, param_types.items.len) catch break :blk types.null_type;
                @memcpy(owned_params, param_types.items);

                const return_type = self.resolveTypeNode(node.data.rhs);
                break :blk @constCast(self.type_pool).addType(self.allocator, .{ .fn_type = .{
                    .params = owned_params,
                    .return_type = return_type,
                    .is_variadic = is_variadic,
                } }) catch types.null_type;
            },
            .type_tuple => types.null_type,
            else => self.typeOfNode(node_idx),
        };
    }

    fn resolveTypeArgument(self: *LoweringContext, node_idx: NodeIndex) TypeId {
        const node = self.tree.nodes.items[node_idx];
        return switch (node.tag) {
            .type_name, .ident, .type_ptr, .type_const_ptr, .type_nullable, .type_slice, .type_chan, .type_map, .type_array, .type_fn, .type_tuple => self.resolveTypeNode(node_idx),
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
            // &T/@T lower to run_gen_ref_t (pointer + generation).
            .ptr_type => 16,
            // run_slice_t header: ptr + generation + len + cap + elem_size.
            .slice_type => 40,
            .chan_type, .map_type => 8,
            .newtype => |newtype| self.sizeOfTypeId(newtype.underlying),
            .struct_type => |st| blk: {
                var offset: u32 = 0;
                var max_align: u32 = 1;
                for (st.fields) |f| {
                    const field_align = @max(@as(u32, 1), self.alignOfTypeId(f.type_id));
                    const field_size = self.sizeOfTypeId(f.type_id);
                    max_align = @max(max_align, field_align);
                    offset = std.mem.alignForward(u32, offset, field_align) + field_size;
                }
                break :blk @max(@as(u32, 1), std.mem.alignForward(u32, offset, max_align));
            },
            else => 8,
        };
    }

    fn alignOfTypeId(self: *const LoweringContext, type_id: TypeId) u32 {
        if (self.type_pool.simdAlignment(type_id)) |alignment| return alignment;
        if (type_id == types.primitives.string_id) return 8;
        if (type_id >= types.primitives.count) {
            switch (self.type_pool.get(type_id)) {
                .struct_type => |st| {
                    var max_align: u32 = 1;
                    for (st.fields) |f| {
                        max_align = @max(max_align, self.alignOfTypeId(f.type_id));
                    }
                    return max_align;
                },
                .ptr_type => return 8,
                else => {},
            }
        }
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

        if (std.mem.eql(u8, package_name, "syscall")) {
            if (std.mem.eql(u8, member_name, "open")) return "syscall.open";
            if (std.mem.eql(u8, member_name, "read")) return "syscall.read";
            if (std.mem.eql(u8, member_name, "write")) return "syscall.write";
            if (std.mem.eql(u8, member_name, "close")) return "syscall.close";
            if (std.mem.eql(u8, member_name, "lseek")) return "syscall.lseek";
            if (std.mem.eql(u8, member_name, "args")) return "syscall.args";
            if (std.mem.eql(u8, member_name, "getenv")) return "syscall.getenv";
            if (std.mem.eql(u8, member_name, "setenv")) return "syscall.setenv";
            if (std.mem.eql(u8, member_name, "unsetenv")) return "syscall.unsetenv";
            if (std.mem.eql(u8, member_name, "environ")) return "syscall.environ";
            if (std.mem.eql(u8, member_name, "exit")) return "syscall.exit";
            if (std.mem.eql(u8, member_name, "getpid")) return "syscall.getpid";
            if (std.mem.eql(u8, member_name, "gethostname")) return "syscall.gethostname";
            if (std.mem.eql(u8, member_name, "mkdir")) return "syscall.mkdir";
            if (std.mem.eql(u8, member_name, "rmdir")) return "syscall.rmdir";
            if (std.mem.eql(u8, member_name, "unlink")) return "syscall.unlink";
            if (std.mem.eql(u8, member_name, "rename")) return "syscall.rename";
            if (std.mem.eql(u8, member_name, "symlink")) return "syscall.symlink";
            if (std.mem.eql(u8, member_name, "readlink")) return "syscall.readlink";
            if (std.mem.eql(u8, member_name, "chmod")) return "syscall.chmod";
            if (std.mem.eql(u8, member_name, "chown")) return "syscall.chown";
            if (std.mem.eql(u8, member_name, "stat")) return "syscall.stat";
            if (std.mem.eql(u8, member_name, "lstat")) return "syscall.lstat";
            if (std.mem.eql(u8, member_name, "readdir")) return "syscall.readdir";
            if (std.mem.eql(u8, member_name, "mkstemp")) return "syscall.mkstemp";
            if (std.mem.eql(u8, member_name, "getcwd")) return "syscall.getcwd";
            if (std.mem.eql(u8, member_name, "chdir")) return "syscall.chdir";
            return null;
        }

        if (std.mem.eql(u8, package_name, "numa")) {
            if (std.mem.eql(u8, member_name, "nodeCount")) return "numa.nodeCount";
            if (std.mem.eql(u8, member_name, "currentNode")) return "numa.currentNode";
            if (std.mem.eql(u8, member_name, "distance")) return "numa.distance";
            if (std.mem.eql(u8, member_name, "pin")) return "numa.pin";
            if (std.mem.eql(u8, member_name, "memoryOnNode")) return "numa.memoryOnNode";
            if (std.mem.eql(u8, member_name, "available")) return "numa.available";
            if (std.mem.eql(u8, member_name, "preferredNode")) return "numa.preferredNode";
            if (std.mem.eql(u8, member_name, "localAlloc")) return "numa.localAlloc";
            if (std.mem.eql(u8, member_name, "nodeAlloc")) return "numa.nodeAlloc";
            if (std.mem.eql(u8, member_name, "interleaveAlloc")) return "numa.interleaveAlloc";
            if (std.mem.eql(u8, member_name, "free")) return "numa.free";
            if (std.mem.eql(u8, member_name, "bindThread")) return "numa.bindThread";
            if (std.mem.eql(u8, member_name, "bindGreenThread")) return "numa.bindGreenThread";
            if (std.mem.eql(u8, member_name, "setMemoryPolicy")) return "numa.setMemoryPolicy";
            if (std.mem.eql(u8, member_name, "cpuCount")) return "numa.cpuCount";
            return null;
        }

        if (std.mem.eql(u8, package_name, "runtime")) {
            if (std.mem.eql(u8, member_name, "numCpu")) return "runtime.numCpu";
            if (std.mem.eql(u8, member_name, "numGoroutine")) return "runtime.numGoroutine";
            if (std.mem.eql(u8, member_name, "gomaxprocs")) return "runtime.gomaxprocs";
            if (std.mem.eql(u8, member_name, "memStats")) return "runtime.memStats";
            if (std.mem.eql(u8, member_name, "version")) return "runtime.version";
            if (std.mem.eql(u8, member_name, "gcDisable")) return "runtime.gcDisable";
            if (std.mem.eql(u8, member_name, "gcEnable")) return "runtime.gcEnable";
            if (std.mem.eql(u8, member_name, "yield")) return "runtime.yield";
            if (std.mem.eql(u8, member_name, "caller")) return "runtime.caller";
            if (std.mem.eql(u8, member_name, "stack")) return "runtime.stack";
            return null;
        }

        if (std.mem.eql(u8, package_name, "debug")) {
            if (std.mem.eql(u8, member_name, "stackTrace")) return "debug.stackTrace";
            if (std.mem.eql(u8, member_name, "printStack")) return "debug.printStack";
            if (std.mem.eql(u8, member_name, "formatStack")) return "debug.formatStack";
            if (std.mem.eql(u8, member_name, "assert")) return "debug.assert";
            if (std.mem.eql(u8, member_name, "assertEq")) return "debug.assertEq";
            if (std.mem.eql(u8, member_name, "unreachable")) return "debug.unreachable";
            if (std.mem.eql(u8, member_name, "todo")) return "debug.todo";
            if (std.mem.eql(u8, member_name, "breakpoint")) return "debug.breakpoint";
            return null;
        }

        if (std.mem.eql(u8, package_name, "exec")) {
            if (std.mem.eql(u8, member_name, "command")) return "exec.command";
            if (std.mem.eql(u8, member_name, "runCmd")) return "exec.runCmd";
            if (std.mem.eql(u8, member_name, "outputCmd")) return "exec.outputCmd";
            if (std.mem.eql(u8, member_name, "combinedOutputCmd")) return "exec.combinedOutputCmd";
            if (std.mem.eql(u8, member_name, "startCmd")) return "exec.startCmd";
            if (std.mem.eql(u8, member_name, "waitCmd")) return "exec.waitCmd";
            if (std.mem.eql(u8, member_name, "stdinPipeCmd")) return "exec.stdinPipeCmd";
            if (std.mem.eql(u8, member_name, "stdoutPipeCmd")) return "exec.stdoutPipeCmd";
            if (std.mem.eql(u8, member_name, "stderrPipeCmd")) return "exec.stderrPipeCmd";
            if (std.mem.eql(u8, member_name, "setDirCmd")) return "exec.setDirCmd";
            if (std.mem.eql(u8, member_name, "setEnvCmd")) return "exec.setEnvCmd";
            if (std.mem.eql(u8, member_name, "addArgsCmd")) return "exec.addArgsCmd";
            if (std.mem.eql(u8, member_name, "processStateCmd")) return "exec.processStateCmd";
            if (std.mem.eql(u8, member_name, "freeCmd")) return "exec.freeCmd";
            if (std.mem.eql(u8, member_name, "lookPath")) return "exec.lookPath";
            return null;
        }

        if (std.mem.eql(u8, package_name, "signal")) {
            if (std.mem.eql(u8, member_name, "notify")) return "signal.notify";
            if (std.mem.eql(u8, member_name, "stop")) return "signal.stop";
            if (std.mem.eql(u8, member_name, "ignore")) return "signal.ignore";
            if (std.mem.eql(u8, member_name, "reset")) return "signal.reset";
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
        if (std.mem.eql(u8, member_name, "loadUnaligned")) return "simd.loadUnaligned";
        if (std.mem.eql(u8, member_name, "width")) return "simd.width";
        if (std.mem.eql(u8, member_name, "sqrt")) return "simd.sqrt";
        if (std.mem.eql(u8, member_name, "abs")) return "simd.abs";
        if (std.mem.eql(u8, member_name, "floor")) return "simd.floor";
        if (std.mem.eql(u8, member_name, "ceil")) return "simd.ceil";
        if (std.mem.eql(u8, member_name, "round")) return "simd.round";
        if (std.mem.eql(u8, member_name, "fma")) return "simd.fma";
        if (std.mem.eql(u8, member_name, "clamp")) return "simd.clamp";
        if (std.mem.eql(u8, member_name, "broadcast")) return "simd.broadcast";
        if (std.mem.eql(u8, member_name, "i32ToF32")) return "simd.i32ToF32";
        if (std.mem.eql(u8, member_name, "f32ToI32")) return "simd.f32ToI32";
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
            const ret_type = numaReturnType(builtin_name);
            return self.emitTypedCall(target, numa_arg_refs.items, ret_type, false);
        }

        // Runtime builtins
        if (std.mem.startsWith(u8, builtin_name, "runtime.")) {
            var rt_arg_refs: std.ArrayList(ir.Ref) = .empty;
            defer rt_arg_refs.deinit(self.allocator);
            for (arg_nodes) |arg_node| {
                try rt_arg_refs.append(self.allocator, try self.lowerExpr(arg_node));
            }
            const target = mapBuiltinCall(builtin_name);
            const ret_type = runtimeReturnType(builtin_name);
            return self.emitTypedCall(target, rt_arg_refs.items, ret_type, false);
        }

        // Debug builtins
        if (std.mem.startsWith(u8, builtin_name, "debug.")) {
            var dbg_arg_refs: std.ArrayList(ir.Ref) = .empty;
            defer dbg_arg_refs.deinit(self.allocator);
            for (arg_nodes) |arg_node| {
                try dbg_arg_refs.append(self.allocator, try self.lowerExpr(arg_node));
            }
            const target = mapBuiltinCall(builtin_name);
            const ret_type = debugReturnType(builtin_name);
            return self.emitTypedCall(target, dbg_arg_refs.items, ret_type, false);
        }

        // exec builtins
        if (std.mem.startsWith(u8, builtin_name, "exec.")) {
            var exec_arg_refs: std.ArrayList(ir.Ref) = .empty;
            defer exec_arg_refs.deinit(self.allocator);
            for (arg_nodes) |arg_node| {
                try exec_arg_refs.append(self.allocator, try self.lowerExpr(arg_node));
            }
            const target = mapBuiltinCall(builtin_name);
            const ret_type = execReturnType(builtin_name);
            return self.emitTypedCall(target, exec_arg_refs.items, ret_type, false);
        }

        // signal builtins
        if (std.mem.startsWith(u8, builtin_name, "signal.")) {
            var sig_arg_refs: std.ArrayList(ir.Ref) = .empty;
            defer sig_arg_refs.deinit(self.allocator);
            for (arg_nodes) |arg_node| {
                try sig_arg_refs.append(self.allocator, try self.lowerExpr(arg_node));
            }
            const target = mapBuiltinCall(builtin_name);
            return self.emitTypedCall(target, sig_arg_refs.items, "void", false);
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

        // Conversions: i32ToF32, f32ToI32
        if (std.mem.eql(u8, builtin_name, "simd.i32ToF32") or std.mem.eql(u8, builtin_name, "simd.f32ToI32")) {
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
            if (std.mem.eql(u8, builtin_name, "simd.loadUnaligned")) break :blk try std.fmt.allocPrint(self.allocator, "run_simd_{s}_load_unaligned", .{self.simdTypeSuffix(helper_type)});
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

    /// Lift a closure literal into a top-level function and return a
    /// function-pointer value. Capturing closures are rejected (the body
    /// lowers with a fresh variable space; see getVar).
    /// Returns the lifted function's mangled name via out_name when non-null.
    fn lowerClosureLifted(self: *LoweringContext, node_idx: NodeIndex, out_name: ?*[]const u8) LowerError!ir.Ref {
        const node = self.tree.nodes.items[node_idx];
        const extra = self.tree.extra_data.items;
        const params_start = node.data.lhs;
        var param_count: u32 = 0;
        while (params_start + param_count < extra.len) : (param_count += 1) {
            if (extra[params_start + param_count] == param_count) break;
        }
        const param_nodes = extra[params_start .. params_start + param_count];
        const body = node.data.rhs;

        const fn_type_id = self.typeOfNode(node_idx);
        var return_type: TypeId = types.primitives.void_id;
        var param_types: []const TypeId = &.{};
        if (fn_type_id != types.null_type) {
            switch (self.type_pool.get(fn_type_id)) {
                .fn_type => |ft| {
                    return_type = ft.return_type;
                    param_types = ft.params;
                },
                else => {},
            }
        }

        const name = try std.fmt.allocPrint(self.allocator, "run_closure_{d}", .{self.module.functions.items.len});
        try self.module.owned_strings.append(self.allocator, name);
        if (out_name) |slot| slot.* = name;

        // Swap in a fresh per-function lowering state for the closure body.
        const saved_func = self.current_func;
        const saved_block = self.current_block;
        const saved_closure = self.closure_ctx_node;
        const saved_ret_type = self.current_fn_return_type_id;
        var fresh_var_map: @TypeOf(self.var_map) = .empty;
        var fresh_var_lookup: @TypeOf(self.var_lookup) = .empty;
        var fresh_shadow: @TypeOf(self.var_shadow_stack) = .empty;
        var fresh_shadow_scopes: @TypeOf(self.var_shadow_scope_stack) = .empty;
        var fresh_scopes: @TypeOf(self.scope_stack) = .empty;
        var fresh_defers: @TypeOf(self.defer_stack) = .empty;
        var fresh_defer_scopes: @TypeOf(self.defer_scope_stack) = .empty;
        var fresh_owned: @TypeOf(self.owned_stack) = .empty;
        var fresh_owned_scopes: @TypeOf(self.owned_scope_stack) = .empty;
        var fresh_loops: @TypeOf(self.loop_stack) = .empty;
        var fresh_names: @TypeOf(self.func_local_names) = .empty;
        std.mem.swap(@TypeOf(self.var_map), &self.var_map, &fresh_var_map);
        std.mem.swap(@TypeOf(self.var_lookup), &self.var_lookup, &fresh_var_lookup);
        std.mem.swap(@TypeOf(self.var_shadow_stack), &self.var_shadow_stack, &fresh_shadow);
        std.mem.swap(@TypeOf(self.var_shadow_scope_stack), &self.var_shadow_scope_stack, &fresh_shadow_scopes);
        std.mem.swap(@TypeOf(self.scope_stack), &self.scope_stack, &fresh_scopes);
        std.mem.swap(@TypeOf(self.defer_stack), &self.defer_stack, &fresh_defers);
        std.mem.swap(@TypeOf(self.defer_scope_stack), &self.defer_scope_stack, &fresh_defer_scopes);
        std.mem.swap(@TypeOf(self.owned_stack), &self.owned_stack, &fresh_owned);
        std.mem.swap(@TypeOf(self.owned_scope_stack), &self.owned_scope_stack, &fresh_owned_scopes);
        std.mem.swap(@TypeOf(self.loop_stack), &self.loop_stack, &fresh_loops);
        std.mem.swap(@TypeOf(self.func_local_names), &self.func_local_names, &fresh_names);
        self.closure_ctx_node = node_idx;
        self.current_fn_return_type_id = return_type;

        const func_id = try self.module.addFunction(self.allocator, name);
        self.current_func = self.module.getFunction(func_id);
        self.current_func.?.return_type_name = self.cTypeForTypeId(return_type);

        var param_refs: [64]ir.Ref = [_]ir.Ref{ir.null_ref} ** 64;
        for (param_nodes, 0..) |param_node, i| {
            if (param_node == null_node or i >= param_refs.len) continue;
            const param_name = self.tokenSlice(self.tree.nodes.items[param_node].main_token);
            const param_type = if (i < param_types.len) param_types[i] else types.null_type;
            const c_name = try std.fmt.allocPrint(self.allocator, "_param_{s}", .{param_name});
            try self.module.owned_strings.append(self.allocator, c_name);
            param_refs[i] = try self.current_func.?.addParam(self.allocator, c_name, self.cTypeForTypeId(param_type));
        }

        const block_id = try self.current_func.?.addBlock(self.allocator);
        self.current_block = self.current_func.?.getBlock(block_id);

        try self.pushScope();
        for (param_nodes, 0..) |param_node, i| {
            if (param_node == null_node or i >= param_refs.len or param_refs[i] == ir.null_ref) continue;
            const param_name = self.tokenSlice(self.tree.nodes.items[param_node].main_token);
            const param_type = if (i < param_types.len) param_types[i] else types.null_type;
            _ = try self.defineVar(param_name, self.cTypeForTypeId(param_type), self.alignmentForTypeId(param_type), param_refs[i]);
        }
        if (body != null_node) {
            try self.lowerBlock(body);
        }
        try self.popScope();
        if (self.current_block != null and !self.current_block.?.isTerminated()) {
            if (self.isErrorUnion(self.current_fn_return_type_id)) {
                // Falling off the end of a `!`-returning function yields ok.
                const ok_ref = try self.buildErrUnionValue(self.current_fn_return_type_id, ir.null_ref, ir.null_ref);
                try self.emitAllCleanup();
                try self.emit(ir.makeInst(.ret, 0, ok_ref, 0));
            } else {
                try self.current_block.?.addInst(self.allocator, ir.makeInst(.ret_void, 0, 0, 0));
            }
        }

        // Restore enclosing function state.
        std.mem.swap(@TypeOf(self.var_map), &self.var_map, &fresh_var_map);
        std.mem.swap(@TypeOf(self.var_lookup), &self.var_lookup, &fresh_var_lookup);
        std.mem.swap(@TypeOf(self.var_shadow_stack), &self.var_shadow_stack, &fresh_shadow);
        std.mem.swap(@TypeOf(self.var_shadow_scope_stack), &self.var_shadow_scope_stack, &fresh_shadow_scopes);
        std.mem.swap(@TypeOf(self.scope_stack), &self.scope_stack, &fresh_scopes);
        std.mem.swap(@TypeOf(self.defer_stack), &self.defer_stack, &fresh_defers);
        std.mem.swap(@TypeOf(self.defer_scope_stack), &self.defer_scope_stack, &fresh_defer_scopes);
        std.mem.swap(@TypeOf(self.owned_stack), &self.owned_stack, &fresh_owned);
        std.mem.swap(@TypeOf(self.owned_scope_stack), &self.owned_scope_stack, &fresh_owned_scopes);
        std.mem.swap(@TypeOf(self.loop_stack), &self.loop_stack, &fresh_loops);
        std.mem.swap(@TypeOf(self.func_local_names), &self.func_local_names, &fresh_names);
        fresh_var_map.deinit(self.allocator);
        fresh_var_lookup.deinit(self.allocator);
        fresh_shadow.deinit(self.allocator);
        fresh_shadow_scopes.deinit(self.allocator);
        fresh_scopes.deinit(self.allocator);
        fresh_defers.deinit(self.allocator);
        fresh_defer_scopes.deinit(self.allocator);
        fresh_owned.deinit(self.allocator);
        fresh_owned_scopes.deinit(self.allocator);
        fresh_loops.deinit(self.allocator);
        fresh_names.deinit(self.allocator);
        self.closure_ctx_node = saved_closure;
        self.current_fn_return_type_id = saved_ret_type;
        self.current_func = saved_func;
        self.current_block = saved_block;

        // The closure value in the enclosing function: a function pointer.
        if (self.current_func == null) return ir.null_ref;
        const ci = try self.module.addTypedCallInfo(self.allocator, name, &.{}, "void*");
        const r = self.allocRef();
        try self.emit(ir.makeInst(.closure_create, r, ci, 0));
        return r;
    }

    /// Build the C function-pointer cast type for an fn_type, e.g.
    /// "int64_t (*)(int64_t, int64_t)".
    fn fnPtrCastType(self: *LoweringContext, fn_type_id: TypeId) LowerError![]const u8 {
        var ret_c: []const u8 = "void";
        var params: []const TypeId = &.{};
        if (fn_type_id != types.null_type) {
            switch (self.type_pool.get(fn_type_id)) {
                .fn_type => |ft| {
                    ret_c = self.cTypeForTypeId(ft.return_type);
                    params = ft.params;
                },
                else => {},
            }
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, ret_c);
        try buf.appendSlice(self.allocator, " (*)(");
        if (params.len == 0) {
            try buf.appendSlice(self.allocator, "void");
        } else {
            for (params, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(self.allocator, ", ");
                try buf.appendSlice(self.allocator, self.cTypeForTypeId(p));
            }
        }
        try buf.appendSlice(self.allocator, ")");
        const owned = try buf.toOwnedSlice(self.allocator);
        try self.module.owned_strings.append(self.allocator, owned);
        return owned;
    }

    fn lowerRunStmt(self: *LoweringContext, node_idx: NodeIndex) LowerError!void {
        const node = self.tree.nodes.items[node_idx];
        const call_idx = node.data.lhs;
        if (call_idx == null_node) return;

        const call_node = self.tree.nodes.items[call_idx];

        var target_name: []const u8 = "";
        var arg_refs: std.ArrayList(ir.Ref) = .empty;
        defer arg_refs.deinit(self.allocator);

        if (call_node.tag == .closure) {
            // `run fun() { ... }` — spawn a lifted closure with no args.
            _ = try self.lowerClosureLifted(call_idx, &target_name);
        } else if (call_node.tag == .call) {
            const callee_idx = call_node.data.lhs;
            const args_start = call_node.data.rhs;
            const n = self.findTrailingCount(args_start);
            const arg_nodes = self.tree.extra_data.items[args_start .. args_start + n];

            if (callee_idx != null_node and self.tree.nodes.items[callee_idx].tag == .closure) {
                // `run fun() { ... }()` — spawn the lifted closure.
                _ = try self.lowerClosureLifted(callee_idx, &target_name);
            } else {
                const callee_name = self.resolveCalleeName(callee_idx);
                target_name = try self.targetNameForCall(callee_name);
            }

            for (arg_nodes) |arg_node| {
                try arg_refs.append(self.allocator, try self.lowerExpr(arg_node));
            }
        } else {
            return self.unsupported(node_idx, "spawning this expression with 'run'");
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

        // Slice builtins.
        if (callee_idx != null_node and self.tree.nodes.items[callee_idx].tag == .ident) {
            const bname = self.tokenSlice(self.tree.nodes.items[callee_idx].main_token);
            if (std.mem.eql(u8, bname, "append") and arg_nodes.len == 2) {
                return try self.lowerAppend(node_idx, arg_nodes[0], arg_nodes[1]);
            }
            if (std.mem.eql(u8, bname, "len") and arg_nodes.len == 1) {
                if (self.isSliceType(self.typeOfNode(arg_nodes[0]))) {
                    const slice_local = (try self.exprToTempLocal(arg_nodes[0], "run_slice_t")) orelse return ir.null_ref;
                    const fi_len = try self.module.addFieldInfo(self.allocator, "run_slice_t", "len", "int64_t");
                    const r = self.allocRef();
                    try self.emit(ir.makeInst(.local_field_get, r, slice_local, fi_len));
                    return r;
                }
                if (self.isMapType(self.typeOfNode(arg_nodes[0]))) {
                    const map_ref = try self.lowerExpr(arg_nodes[0]);
                    return self.emitTypedCall("run_map_len", &.{map_ref}, "int64_t", false);
                }
            }
        }

        // Indirect call through a local holding a function value:
        // `f := fun(x int) int { ... }; f(1)`.
        if (callee_idx != null_node and self.tree.nodes.items[callee_idx].tag == .ident) {
            const callee_name_slice = self.tokenSlice(self.tree.nodes.items[callee_idx].main_token);
            const callee_type = self.typeOfNode(callee_idx);
            if (self.lookupLocalIdx(callee_name_slice) != null and callee_type != types.null_type and
                callee_type >= types.primitives.count)
            {
                switch (self.type_pool.get(callee_type)) {
                    .fn_type => |ft| {
                        const fn_ref = try self.getVar(callee_name_slice);
                        var indirect_args: std.ArrayList(ir.Ref) = .empty;
                        defer indirect_args.deinit(self.allocator);
                        for (arg_nodes) |arg_node| {
                            try indirect_args.append(self.allocator, try self.lowerExpr(arg_node));
                        }
                        const cast_type = try self.fnPtrCastType(callee_type);
                        const ret_c = self.cTypeForTypeId(ft.return_type);
                        const ci = try self.module.addTypedCallInfo(self.allocator, cast_type, indirect_args.items, ret_c);
                        const is_void = std.mem.eql(u8, ret_c, "void");
                        const result = if (is_void) ir.null_ref else self.allocRef();
                        try self.emit(ir.makeInst(.call_ptr, result, ci, fn_ref));
                        return result;
                    },
                    else => {},
                }
            }
        }

        // Method dispatch: `base.method(args)` where base is a struct value
        // or a pointer to one.
        if (callee_idx != null_node and self.tree.nodes.items[callee_idx].tag == .field_access) {
            const fa = self.tree.nodes.items[callee_idx];
            const base_idx = fa.data.lhs;
            const base_type = self.typeOfNode(base_idx);
            const struct_ty = self.type_pool.unwrapPointer(base_type) orelse base_type;
            if (self.isStructType(struct_ty)) {
                const method_name = self.tokenSlice(fa.main_token + 1);
                if (self.lookupMethodInfo(struct_ty, method_name)) |mi| {
                    return try self.lowerMethodCall(node_idx, mi, base_idx, arg_nodes);
                }
            }
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
            std.mem.eql(u8, name, "run_chan_close") or
            std.mem.eql(u8, name, "run_runtime_gc_disable") or
            std.mem.eql(u8, name, "run_runtime_gc_enable") or
            std.mem.eql(u8, name, "run_runtime_yield") or
            std.mem.eql(u8, name, "run_debug_print_stack") or
            std.mem.eql(u8, name, "run_debug_assert") or
            std.mem.eql(u8, name, "run_debug_assert_eq") or
            std.mem.eql(u8, name, "run_debug_unreachable") or
            std.mem.eql(u8, name, "run_debug_todo") or
            std.mem.eql(u8, name, "run_debug_breakpoint") or
            std.mem.eql(u8, name, "run_exec_set_dir") or
            std.mem.eql(u8, name, "run_exec_set_env") or
            std.mem.eql(u8, name, "run_exec_add_args") or
            std.mem.eql(u8, name, "run_exec_free") or
            std.mem.eql(u8, name, "run_signal_notify") or
            std.mem.eql(u8, name, "run_signal_stop") or
            std.mem.eql(u8, name, "run_signal_ignore") or
            std.mem.eql(u8, name, "run_signal_reset");
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
        if (std.mem.eql(u8, name, "numa.nodeCount")) return "run_numa_node_count";
        if (std.mem.eql(u8, name, "numa.currentNode")) return "run_numa_current_node";
        if (std.mem.eql(u8, name, "numa.distance")) return "run_numa_distance";
        if (std.mem.eql(u8, name, "numa.pin")) return "run_numa_pin";
        if (std.mem.eql(u8, name, "numa.memoryOnNode")) return "run_numa_memory_on_node";
        if (std.mem.eql(u8, name, "numa.available")) return "run_numa_available";
        if (std.mem.eql(u8, name, "numa.preferredNode")) return "run_numa_preferred_node";
        if (std.mem.eql(u8, name, "numa.localAlloc")) return "run_numa_local_alloc";
        if (std.mem.eql(u8, name, "numa.nodeAlloc")) return "run_numa_node_alloc";
        if (std.mem.eql(u8, name, "numa.interleaveAlloc")) return "run_numa_interleave_alloc";
        if (std.mem.eql(u8, name, "numa.free")) return "run_numa_free";
        if (std.mem.eql(u8, name, "numa.bindThread")) return "run_numa_bind_thread";
        if (std.mem.eql(u8, name, "numa.bindGreenThread")) return "run_numa_pin";
        if (std.mem.eql(u8, name, "numa.setMemoryPolicy")) return "run_numa_set_memory_policy";
        if (std.mem.eql(u8, name, "numa.cpuCount")) return "run_numa_cpu_count";
        // Runtime package
        if (std.mem.eql(u8, name, "runtime.numCpu")) return "run_runtime_num_cpu";
        if (std.mem.eql(u8, name, "runtime.numGoroutine")) return "run_runtime_num_goroutine";
        if (std.mem.eql(u8, name, "runtime.gomaxprocs")) return "run_runtime_gomaxprocs";
        if (std.mem.eql(u8, name, "runtime.memStats")) return "run_runtime_mem_stats";
        if (std.mem.eql(u8, name, "runtime.version")) return "run_runtime_version";
        if (std.mem.eql(u8, name, "runtime.gcDisable")) return "run_runtime_gc_disable";
        if (std.mem.eql(u8, name, "runtime.gcEnable")) return "run_runtime_gc_enable";
        if (std.mem.eql(u8, name, "runtime.yield")) return "run_runtime_yield";
        if (std.mem.eql(u8, name, "runtime.caller")) return "run_runtime_caller";
        if (std.mem.eql(u8, name, "runtime.stack")) return "run_runtime_stack";
        // Debug package
        if (std.mem.eql(u8, name, "debug.stackTrace")) return "run_debug_stack_trace";
        if (std.mem.eql(u8, name, "debug.printStack")) return "run_debug_print_stack";
        if (std.mem.eql(u8, name, "debug.formatStack")) return "run_debug_format_stack";
        if (std.mem.eql(u8, name, "debug.assert")) return "run_debug_assert";
        if (std.mem.eql(u8, name, "debug.assertEq")) return "run_debug_assert_eq";
        if (std.mem.eql(u8, name, "debug.unreachable")) return "run_debug_unreachable";
        if (std.mem.eql(u8, name, "debug.todo")) return "run_debug_todo";
        if (std.mem.eql(u8, name, "debug.breakpoint")) return "run_debug_breakpoint";
        // exec builtins
        if (std.mem.eql(u8, name, "exec.command")) return "run_exec_command";
        if (std.mem.eql(u8, name, "exec.runCmd")) return "run_exec_run";
        if (std.mem.eql(u8, name, "exec.outputCmd")) return "run_exec_output";
        if (std.mem.eql(u8, name, "exec.combinedOutputCmd")) return "run_exec_combined_output";
        if (std.mem.eql(u8, name, "exec.startCmd")) return "run_exec_start";
        if (std.mem.eql(u8, name, "exec.waitCmd")) return "run_exec_wait";
        if (std.mem.eql(u8, name, "exec.stdinPipeCmd")) return "run_exec_stdin_pipe";
        if (std.mem.eql(u8, name, "exec.stdoutPipeCmd")) return "run_exec_stdout_pipe";
        if (std.mem.eql(u8, name, "exec.stderrPipeCmd")) return "run_exec_stderr_pipe";
        if (std.mem.eql(u8, name, "exec.setDirCmd")) return "run_exec_set_dir";
        if (std.mem.eql(u8, name, "exec.setEnvCmd")) return "run_exec_set_env";
        if (std.mem.eql(u8, name, "exec.addArgsCmd")) return "run_exec_add_args";
        if (std.mem.eql(u8, name, "exec.processStateCmd")) return "run_exec_process_state";
        if (std.mem.eql(u8, name, "exec.freeCmd")) return "run_exec_free";
        if (std.mem.eql(u8, name, "exec.lookPath")) return "run_exec_look_path";
        // signal builtins
        if (std.mem.eql(u8, name, "signal.notify")) return "run_signal_notify";
        if (std.mem.eql(u8, name, "signal.stop")) return "run_signal_stop";
        if (std.mem.eql(u8, name, "signal.ignore")) return "run_signal_ignore";
        if (std.mem.eql(u8, name, "signal.reset")) return "run_signal_reset";
        // syscall builtins
        if (std.mem.eql(u8, name, "syscall.open")) return "run_syscall_open";
        if (std.mem.eql(u8, name, "syscall.read")) return "run_syscall_read";
        if (std.mem.eql(u8, name, "syscall.write")) return "run_syscall_write";
        if (std.mem.eql(u8, name, "syscall.close")) return "run_syscall_close";
        if (std.mem.eql(u8, name, "syscall.lseek")) return "run_syscall_lseek";
        if (std.mem.eql(u8, name, "syscall.args")) return "run_syscall_args";
        if (std.mem.eql(u8, name, "syscall.getenv")) return "run_syscall_getenv";
        if (std.mem.eql(u8, name, "syscall.setenv")) return "run_syscall_setenv";
        if (std.mem.eql(u8, name, "syscall.unsetenv")) return "run_syscall_unsetenv";
        if (std.mem.eql(u8, name, "syscall.environ")) return "run_syscall_environ";
        if (std.mem.eql(u8, name, "syscall.exit")) return "run_syscall_exit";
        if (std.mem.eql(u8, name, "syscall.getpid")) return "run_syscall_getpid";
        if (std.mem.eql(u8, name, "syscall.gethostname")) return "run_syscall_gethostname";
        if (std.mem.eql(u8, name, "syscall.mkdir")) return "run_syscall_mkdir";
        if (std.mem.eql(u8, name, "syscall.rmdir")) return "run_syscall_rmdir";
        if (std.mem.eql(u8, name, "syscall.unlink")) return "run_syscall_unlink";
        if (std.mem.eql(u8, name, "syscall.rename")) return "run_syscall_rename";
        if (std.mem.eql(u8, name, "syscall.symlink")) return "run_syscall_symlink";
        if (std.mem.eql(u8, name, "syscall.readlink")) return "run_syscall_readlink";
        if (std.mem.eql(u8, name, "syscall.chmod")) return "run_syscall_chmod";
        if (std.mem.eql(u8, name, "syscall.chown")) return "run_syscall_chown";
        if (std.mem.eql(u8, name, "syscall.stat")) return "run_syscall_stat";
        if (std.mem.eql(u8, name, "syscall.lstat")) return "run_syscall_lstat";
        if (std.mem.eql(u8, name, "syscall.readdir")) return "run_syscall_readdir";
        if (std.mem.eql(u8, name, "syscall.mkstemp")) return "run_syscall_mkstemp";
        if (std.mem.eql(u8, name, "syscall.getcwd")) return "run_syscall_getcwd";
        if (std.mem.eql(u8, name, "syscall.chdir")) return "run_syscall_chdir";
        return name;
    }

    fn numaReturnType(builtin_name: []const u8) []const u8 {
        if (std.mem.eql(u8, builtin_name, "numa.pin") or
            std.mem.eql(u8, builtin_name, "numa.bindGreenThread") or
            std.mem.eql(u8, builtin_name, "numa.free"))
            return "void";
        if (std.mem.eql(u8, builtin_name, "numa.bindThread") or
            std.mem.eql(u8, builtin_name, "numa.setMemoryPolicy") or
            std.mem.eql(u8, builtin_name, "numa.preferredNode"))
            return "int32_t";
        if (std.mem.eql(u8, builtin_name, "numa.available"))
            return "bool";
        if (std.mem.eql(u8, builtin_name, "numa.localAlloc") or
            std.mem.eql(u8, builtin_name, "numa.nodeAlloc") or
            std.mem.eql(u8, builtin_name, "numa.interleaveAlloc"))
            return "void *";
        if (std.mem.eql(u8, builtin_name, "numa.memoryOnNode"))
            return "uint64_t";
        return "uint32_t"; // nodeCount, currentNode, distance, cpuCount
    }

    fn runtimeReturnType(builtin_name: []const u8) []const u8 {
        if (std.mem.eql(u8, builtin_name, "runtime.gcDisable") or
            std.mem.eql(u8, builtin_name, "runtime.gcEnable") or
            std.mem.eql(u8, builtin_name, "runtime.yield"))
            return "void";
        if (std.mem.eql(u8, builtin_name, "runtime.version") or
            std.mem.eql(u8, builtin_name, "runtime.stack"))
            return "run_string_t";
        if (std.mem.eql(u8, builtin_name, "runtime.memStats"))
            return "run_mem_stats_t";
        if (std.mem.eql(u8, builtin_name, "runtime.caller"))
            return "run_caller_info_t";
        return "int64_t"; // numCpu, numGoroutine, gomaxprocs
    }

    fn debugReturnType(builtin_name: []const u8) []const u8 {
        if (std.mem.eql(u8, builtin_name, "debug.printStack") or
            std.mem.eql(u8, builtin_name, "debug.assert") or
            std.mem.eql(u8, builtin_name, "debug.assertEq") or
            std.mem.eql(u8, builtin_name, "debug.unreachable") or
            std.mem.eql(u8, builtin_name, "debug.todo") or
            std.mem.eql(u8, builtin_name, "debug.breakpoint"))
            return "void";
        if (std.mem.eql(u8, builtin_name, "debug.formatStack"))
            return "run_string_t";
        if (std.mem.eql(u8, builtin_name, "debug.stackTrace"))
            return "run_slice_t";
        return "void";
    }

    fn execReturnType(builtin_name: []const u8) []const u8 {
        if (std.mem.eql(u8, builtin_name, "exec.command"))
            return "run_exec_cmd_t*";
        if (std.mem.eql(u8, builtin_name, "exec.runCmd") or
            std.mem.eql(u8, builtin_name, "exec.startCmd") or
            std.mem.eql(u8, builtin_name, "exec.waitCmd"))
            return "run_error_t";
        if (std.mem.eql(u8, builtin_name, "exec.outputCmd") or
            std.mem.eql(u8, builtin_name, "exec.combinedOutputCmd"))
            return "run_slice_t";
        if (std.mem.eql(u8, builtin_name, "exec.lookPath"))
            return "run_string_t";
        if (std.mem.eql(u8, builtin_name, "exec.stdinPipeCmd") or
            std.mem.eql(u8, builtin_name, "exec.stdoutPipeCmd") or
            std.mem.eql(u8, builtin_name, "exec.stderrPipeCmd"))
            return "int64_t";
        if (std.mem.eql(u8, builtin_name, "exec.processStateCmd"))
            return "run_exec_process_state_t";
        if (std.mem.eql(u8, builtin_name, "exec.setDirCmd") or
            std.mem.eql(u8, builtin_name, "exec.setEnvCmd") or
            std.mem.eql(u8, builtin_name, "exec.addArgsCmd") or
            std.mem.eql(u8, builtin_name, "exec.freeCmd"))
            return "void";
        return "int64_t";
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

    fn currentBlockId(self: *const LoweringContext) ?ir.BlockId {
        const func = self.current_func orelse return null;
        const block = self.current_block orelse return null;

        for (func.blocks.items, 0..) |*candidate, idx| {
            if (candidate == block) return @intCast(idx);
        }
        return null;
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
        // Track the allocation so it gets freed with the module. toOwnedSlice
        // resizes the buffer so the stored slice length matches the allocation,
        // which Module.deinit relies on when freeing.
        const owned = try buf.toOwnedSlice(self.allocator);
        try self.module.owned_strings.append(self.allocator, owned);
        return owned;
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

fn countCallsTo(module: *const ir.Module, block: *const ir.BasicBlock, target_name: []const u8) usize {
    var count: usize = 0;
    for (block.insts.items) |inst| {
        if (inst.op != .call) continue;
        if (inst.arg1 >= module.call_infos.items.len) continue;
        if (std.mem.eql(u8, module.call_infos.items[inst.arg1].target_name, target_name)) count += 1;
    }
    return count;
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

    // Slice allocs go through the runtime and are freed at scope exit.
    try std.testing.expect(countCallsTo(&module, block, "run_slice_new") == 1);
    try std.testing.expect(countCallsTo(&module, block, "run_slice_free") == 1);

    // run_slice_free should appear before ret_void
    var found_free = false;
    var found_ret_after_free = false;
    for (block.insts.items) |inst| {
        if (inst.op == .call and inst.arg1 < module.call_infos.items.len and
            std.mem.eql(u8, module.call_infos.items[inst.arg1].target_name, "run_slice_free"))
        {
            found_free = true;
        }
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

    // run_slice_free should appear before ret_void (return statement cleanup)
    var found_free = false;
    var found_ret_after_free = false;
    for (block.insts.items) |inst| {
        if (inst.op == .call and inst.arg1 < module.call_infos.items.len and
            std.mem.eql(u8, module.call_infos.items[inst.arg1].target_name, "run_slice_free"))
        {
            found_free = true;
        }
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

    // Should have exactly one free (for 't' which now owns the value),
    // not two (which would be a double-free).
    try std.testing.expectEqual(@as(usize, 1), countCallsTo(&module, block, "run_slice_free"));
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

    // Should free both slices (inner scope freed first, then outer)
    try std.testing.expectEqual(@as(usize, 2), countCallsTo(&module, block, "run_slice_free"));
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

    // Deferred println should appear before the slice free
    var found_call = false;
    var found_free_after_call = false;
    for (block.insts.items) |inst| {
        if (inst.op != .call or inst.arg1 >= module.call_infos.items.len) continue;
        const target = module.call_infos.items[inst.arg1].target_name;
        if (std.mem.eql(u8, target, "run_fmt_println_args")) found_call = true;
        if (found_call and std.mem.eql(u8, target, "run_slice_free")) found_free_after_call = true;
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
