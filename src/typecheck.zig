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
    /// Field slices allocated for StructType entries; must be freed.
    allocated_field_slices: std.ArrayList([]const types.StructField),
    /// TypeId slices allocated for struct implements; must be freed.
    allocated_type_id_slices: std.ArrayList([]const TypeId),
    /// MethodSig slices allocated for InterfaceType entries; must be freed.
    allocated_method_sig_slices: std.ArrayList([]const types.MethodSig),
    /// Variant slices allocated for SumType entries; must be freed.
    allocated_variant_slices: std.ArrayList([]const types.Variant),

    pub fn deinit(self: *TypeCheckResult, allocator: std.mem.Allocator) void {
        for (self.allocated_param_slices.items) |slice| {
            allocator.free(slice);
        }
        self.allocated_param_slices.deinit(allocator);
        for (self.allocated_field_slices.items) |slice| {
            allocator.free(slice);
        }
        self.allocated_field_slices.deinit(allocator);
        for (self.allocated_type_id_slices.items) |slice| {
            allocator.free(slice);
        }
        self.allocated_type_id_slices.deinit(allocator);
        for (self.allocated_method_sig_slices.items) |slice| {
            allocator.free(slice);
        }
        self.allocated_method_sig_slices.deinit(allocator);
        for (self.allocated_variant_slices.items) |slice| {
            allocator.free(slice);
        }
        self.allocated_variant_slices.deinit(allocator);
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
    /// Declaration nodes of variables whose ownership has been moved away.
    moved_nodes: std.ArrayList(NodeIndex),
    /// Tracks param slices allocated for FnType entries.
    allocated_param_slices: std.ArrayList([]const TypeId),
    /// Tracks field slices allocated for StructType entries.
    allocated_field_slices: std.ArrayList([]const types.StructField),
    /// Tracks TypeId slices allocated for struct implements.
    allocated_type_id_slices: std.ArrayList([]const TypeId),
    /// Tracks MethodSig slices allocated for InterfaceType entries.
    allocated_method_sig_slices: std.ArrayList([]const types.MethodSig),
    /// Tracks Variant slices allocated for SumType entries.
    allocated_variant_slices: std.ArrayList([]const types.Variant),

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
            .moved_nodes = .empty,
            .allocated_param_slices = .empty,
            .allocated_field_slices = .empty,
            .allocated_type_id_slices = .empty,
            .allocated_method_sig_slices = .empty,
            .allocated_variant_slices = .empty,
        };
    }

    fn check(self: *TypeChecker) !TypeCheckResult {
        try self.checkTopLevel();
        self.moved_nodes.deinit(self.allocator);
        return .{
            .diagnostics = self.diagnostics,
            .type_map = self.type_map,
            .type_pool = self.type_pool,
            .allocated_param_slices = self.allocated_param_slices,
            .allocated_field_slices = self.allocated_field_slices,
            .allocated_type_id_slices = self.allocated_type_id_slices,
            .allocated_method_sig_slices = self.allocated_method_sig_slices,
            .allocated_variant_slices = self.allocated_variant_slices,
        };
    }

    // ── Top-level walking ────────────────────────────────────────────────────

    fn checkTopLevel(self: *TypeChecker) CheckError!void {
        const root = self.tree.nodes.items[0];
        const start = root.data.lhs;
        const count = root.data.rhs;
        const decl_indices = self.tree.extra_data.items[start .. start + count];

        // Pass 0: Register interface types so they can be referenced.
        for (decl_indices) |decl_idx| {
            var node = decl_idx;
            if (self.nodeTag(node) == .inline_decl) node = self.nodeData(node).lhs;
            if (self.nodeTag(node) == .pub_decl) node = self.nodeData(node).lhs;
            if (self.nodeTag(node) == .interface_decl) {
                try self.registerInterfaceType(node);
            }
        }

        // Pass 0b: Register struct types so they can be referenced in type annotations.
        for (decl_indices) |decl_idx| {
            var node = decl_idx;
            if (self.nodeTag(node) == .inline_decl) node = self.nodeData(node).lhs;
            if (self.nodeTag(node) == .pub_decl) node = self.nodeData(node).lhs;
            if (self.nodeTag(node) == .struct_decl) {
                try self.registerStructType(node);
            }
        }

        // Pass 0c: Register sum types (type_alias nodes with variants).
        for (decl_indices) |decl_idx| {
            var node = decl_idx;
            if (self.nodeTag(node) == .inline_decl) node = self.nodeData(node).lhs;
            if (self.nodeTag(node) == .pub_decl) node = self.nodeData(node).lhs;
            if (self.nodeTag(node) == .type_alias) {
                try self.registerSumType(node);
            }
        }

        // After struct types are registered, re-bind methods with correct TypeIds.
        try self.rebindMethods();

        // Pass 1: Register all function signatures so forward/recursive calls work.
        for (decl_indices) |decl_idx| {
            var node = decl_idx;
            if (self.nodeTag(node) == .inline_decl) node = self.nodeData(node).lhs;
            if (self.nodeTag(node) == .pub_decl) node = self.nodeData(node).lhs;
            if (self.nodeTag(node) == .fn_decl) {
                try self.registerFnType(node);
            }
        }

        // Pass 2: Type-check bodies and top-level var/let decls.
        for (decl_indices) |decl_idx| {
            var node = decl_idx;
            if (self.nodeTag(node) == .inline_decl) node = self.nodeData(node).lhs;
            if (self.nodeTag(node) == .pub_decl) node = self.nodeData(node).lhs;
            switch (self.nodeTag(node)) {
                .fn_decl => try self.checkFnDecl(node),
                .var_decl => try self.checkVarDecl(node),
                .let_decl => try self.checkVarDecl(node),
                else => {},
            }
        }

        // Pass 3: Check interface satisfaction for all struct declarations.
        for (decl_indices) |decl_idx| {
            var node = decl_idx;
            if (self.nodeTag(node) == .inline_decl) node = self.nodeData(node).lhs;
            if (self.nodeTag(node) == .pub_decl) node = self.nodeData(node).lhs;
            if (self.nodeTag(node) == .struct_decl) {
                try self.checkInterfaceSatisfaction(node);
            }
        }
    }

    // ── Interface type registration ────────────────────────────────────────

    /// Build an InterfaceType from an interface_decl node and register it in the type pool.
    fn registerInterfaceType(self: *TypeChecker, node: NodeIndex) CheckError!void {
        const data = self.nodeData(node);
        const main_tok = self.nodeMainToken(node);
        const name_tok = main_tok + 1;
        const name = self.tokenSlice(name_tok);
        const extra = self.tree.extra_data.items;
        const methods_start = data.lhs;
        const method_count = data.rhs;

        // Build MethodSig array for the interface.
        var method_sigs: std.ArrayList(types.MethodSig) = .empty;
        defer method_sigs.deinit(self.allocator);

        const method_sig_nodes = extra[methods_start .. methods_start + method_count];
        for (method_sig_nodes) |msig_node| {
            if (msig_node == null_node) continue;
            const msig_data = self.nodeData(msig_node);
            const msig_name = self.tokenSlice(self.nodeMainToken(msig_node));

            // Build FnType for this method signature.
            const params_start = msig_data.lhs;
            const param_count = self.findParamCount(params_start, extra);

            var param_types_list: std.ArrayList(TypeId) = .empty;
            defer param_types_list.deinit(self.allocator);

            const param_nodes = extra[params_start .. params_start + param_count];
            for (param_nodes) |param_node| {
                if (param_node == null_node) {
                    try param_types_list.append(self.allocator, types.null_type);
                    continue;
                }
                const param_type_node = self.nodeData(param_node).lhs;
                const param_type = self.resolveTypeNode(param_type_node);
                try param_types_list.append(self.allocator, param_type);
            }

            // Return type: extra_data[params_start + param_count + 1]
            // Note: method_sig has no receiver_node slot (unlike fn_decl which has +2)
            const ret_type_node = extra[params_start + param_count + 1];
            const return_type = self.resolveTypeNode(ret_type_node);

            // Allocate param slice and track it.
            const owned_params = try self.allocator.alloc(TypeId, param_types_list.items.len);
            @memcpy(owned_params, param_types_list.items);
            try self.allocated_param_slices.append(self.allocator, owned_params);

            const fn_type_id = try self.type_pool.addType(self.allocator, .{ .fn_type = .{
                .params = owned_params,
                .return_type = return_type,
            } });

            try method_sigs.append(self.allocator, .{
                .name = msig_name,
                .type_id = fn_type_id,
            });
        }

        // Allocate MethodSig slice and track for cleanup.
        const owned_methods = try self.allocator.alloc(types.MethodSig, method_sigs.items.len);
        @memcpy(owned_methods, method_sigs.items);
        try self.allocated_method_sig_slices.append(self.allocator, owned_methods);

        // Create InterfaceType.
        const iface_type_id = try self.type_pool.addType(self.allocator, .{ .interface_type = .{
            .name = name,
            .methods = owned_methods,
        } });

        // Update the interface symbol's type_id.
        if (self.symbols.lookup(name)) |sym_id| {
            self.symbols.getSymbolPtr(sym_id).type_id = iface_type_id;
        }

        self.type_map.items[node] = iface_type_id;
    }

    // ── Struct type registration ──────────────────────────────────────────

    /// Register a struct declaration in the TypePool and update the symbol's type_id.
    fn registerStructType(self: *TypeChecker, node: NodeIndex) CheckError!void {
        const data = self.nodeData(node);
        const name_tok = self.nodeMainToken(node);
        const struct_name = self.tokenSlice(name_tok);

        // extra_data layout: [implements_count, iface1..ifaceN, field1..fieldM]
        const extra = self.tree.extra_data.items;
        const extra_start = data.lhs;
        const field_count = data.rhs;
        const implements_count = extra[extra_start];
        const fields_start = extra_start + 1 + implements_count;

        // Build StructField array.
        const fields = self.allocator.alloc(types.StructField, field_count) catch return;
        self.allocated_field_slices.append(self.allocator, fields) catch return;
        for (0..field_count) |i| {
            const field_node = extra[fields_start + i];
            const field_data = self.nodeData(field_node);
            const field_name_tok = self.nodeMainToken(field_node);
            const field_name = self.tokenSlice(field_name_tok);
            const field_type = self.resolveTypeNode(field_data.lhs);
            fields[i] = .{
                .name = field_name,
                .type_id = field_type,
            };
        }

        // Resolve implements interfaces.
        const impl_list = self.allocator.alloc(TypeId, implements_count) catch return;
        self.allocated_type_id_slices.append(self.allocator, impl_list) catch return;
        for (0..implements_count) |i| {
            const iface_ident_node = extra[extra_start + 1 + i];
            if (iface_ident_node == null_node) {
                impl_list[i] = types.null_type;
                continue;
            }
            const iface_name = self.tokenSlice(self.nodeMainToken(iface_ident_node));
            if (self.symbols.lookup(iface_name)) |sym_id| {
                const sym = self.symbols.getSymbol(sym_id);
                if (sym.type_id != types.null_type) {
                    impl_list[i] = sym.type_id;
                } else {
                    impl_list[i] = types.null_type;
                }
            } else {
                impl_list[i] = types.null_type;
            }
        }

        // Create StructType in the pool.
        const struct_type_id = self.type_pool.addType(self.allocator, .{ .struct_type = .{
            .name = struct_name,
            .fields = fields,
            .methods = &.{},
            .implements = impl_list,
        } }) catch return;

        // Update the type_def symbol's type_id.
        if (self.symbols.lookup(struct_name)) |sym_id| {
            self.symbols.getSymbolPtr(sym_id).type_id = struct_type_id;
        }

        self.type_map.items[node] = struct_type_id;
    }

    // ── Sum type registration ────────────────────────────────────────────

    /// Register a sum type (type_alias with variants) in the TypePool.
    fn registerSumType(self: *TypeChecker, node: NodeIndex) CheckError!void {
        const data = self.nodeData(node);
        const main_tok = self.nodeMainToken(node);
        const name_tok = main_tok + 1;
        const name = self.tokenSlice(name_tok);
        const extra = self.tree.extra_data.items;
        const variants_start = data.lhs;
        const variant_count = data.rhs;

        // Build Variant array from the variant definition nodes.
        const owned_variants = try self.allocator.alloc(types.Variant, variant_count);
        try self.allocated_variant_slices.append(self.allocator, owned_variants);

        const variant_nodes = extra[variants_start .. variants_start + variant_count];
        for (variant_nodes, 0..) |variant_node, i| {
            if (variant_node == null_node) {
                owned_variants[i] = .{ .name = "", .payload = types.null_type };
                continue;
            }
            const variant_name = self.variantName(variant_node);
            const payload_type_node = self.nodeData(variant_node).lhs;
            const payload_type = if (payload_type_node != null_node)
                self.resolveTypeNode(payload_type_node)
            else
                types.null_type;
            owned_variants[i] = .{ .name = variant_name, .payload = payload_type };
        }

        // Create SumType in the pool.
        const sum_type_id = try self.type_pool.addType(self.allocator, .{ .sum_type = .{
            .name = name,
            .variants = owned_variants,
        } });

        // Update the type_def symbol's type_id.
        if (self.symbols.lookup(name)) |sym_id| {
            self.symbols.getSymbolPtr(sym_id).type_id = sum_type_id;
        }

        self.type_map.items[node] = sum_type_id;
    }

    /// Re-bind methods in the method table with correct struct TypeIds.
    /// The resolver registered all methods under TypeId 0 (null_type) because
    /// struct TypeIds weren't assigned yet during name resolution.
    fn rebindMethods(self: *TypeChecker) CheckError!void {
        for (self.symbols.symbols.items, 0..) |sym, idx| {
            if (sym.kind != .method) continue;
            const decl_node = sym.decl_node;
            if (decl_node == null_node) continue;

            // Extract receiver type name from the fn_decl node.
            const fn_data = self.nodeData(decl_node);
            const params_start = fn_data.lhs;
            const extra = self.tree.extra_data.items;
            const param_count = self.findParamCount(params_start, extra);
            const receiver_node = extra[params_start + param_count + 1];
            if (receiver_node == null_node) continue;

            const recv_type_node = self.nodeData(receiver_node).lhs;
            const recv_type_name = self.extractTypeName(recv_type_node);
            if (recv_type_name == null) continue;

            // Look up the struct's real TypeId and re-register the method.
            if (self.symbols.lookup(recv_type_name.?)) |type_sym_id| {
                const type_sym = self.symbols.getSymbol(type_sym_id);
                if (type_sym.kind == .type_def and type_sym.type_id != types.null_type) {
                    try self.symbols.defineMethod(type_sym.type_id, sym.name, @intCast(idx));
                }
            }
        }
    }

    /// Extract the base type name from a type node, unwrapping pointers.
    fn extractTypeName(self: *const TypeChecker, type_node: NodeIndex) ?[]const u8 {
        if (type_node == null_node) return null;
        const tag = self.nodeTag(type_node);
        return switch (tag) {
            .type_name, .ident => self.tokenSlice(self.nodeMainToken(type_node)),
            .type_ptr, .type_const_ptr => {
                const inner = self.nodeData(type_node).lhs;
                return self.extractTypeName(inner);
            },
            else => null,
        };
    }

    // ── Interface satisfaction checking ─────────────────────────────────────

    /// Verify that a struct implements all methods required by its declared interfaces.
    fn checkInterfaceSatisfaction(self: *TypeChecker, node: NodeIndex) CheckError!void {
        const data = self.nodeData(node);
        const struct_name = self.tokenSlice(self.nodeMainToken(node));
        const extra = self.tree.extra_data.items;
        const extra_start = data.lhs;
        const implements_count = extra[extra_start];

        if (implements_count == 0) return;

        // Get the struct's TypeId.
        const struct_type_id = self.type_map.items[node];
        if (struct_type_id == types.null_type) return;

        var i: u32 = 0;
        while (i < implements_count) : (i += 1) {
            const iface_ident_node = extra[extra_start + 1 + i];
            if (iface_ident_node == null_node) continue;
            const iface_name_tok = self.nodeMainToken(iface_ident_node);
            const iface_name = self.tokenSlice(iface_name_tok);
            const loc = self.tokenLoc(iface_name_tok);

            // Look up the interface.
            const iface_sym_id = self.symbols.lookup(iface_name) orelse {
                try self.diagnostics.addErrorFmt(
                    loc.start,
                    loc.end,
                    "undefined interface '{s}'",
                    .{iface_name},
                );
                continue;
            };

            const iface_sym = self.symbols.getSymbol(iface_sym_id);
            if (iface_sym.type_id == types.null_type) {
                try self.diagnostics.addErrorFmt(
                    loc.start,
                    loc.end,
                    "undefined interface '{s}'",
                    .{iface_name},
                );
                continue;
            }

            // Verify it's actually an interface type.
            const iface_type = self.type_pool.get(iface_sym.type_id);
            const iface_methods = switch (iface_type) {
                .interface_type => |it| it.methods,
                else => {
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "'{s}' is not an interface",
                        .{iface_name},
                    );
                    continue;
                },
            };

            // Check each required method.
            for (iface_methods) |required_method| {
                const method_sym_id = self.symbols.lookupMethod(struct_type_id, required_method.name);

                if (method_sym_id == null) {
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "type '{s}' does not implement interface '{s}': missing method '{s}'",
                        .{ struct_name, iface_name, required_method.name },
                    );
                    continue;
                }

                // Compare method signatures.
                const method_sym = self.symbols.getSymbol(method_sym_id.?);
                if (method_sym.type_id == types.null_type) continue;

                const method_type = self.type_pool.get(method_sym.type_id);
                const method_fn = switch (method_type) {
                    .fn_type => |ft| ft,
                    else => continue,
                };

                const required_fn = switch (self.type_pool.get(required_method.type_id)) {
                    .fn_type => |ft| ft,
                    else => continue,
                };

                // Compare signatures.
                if (!self.fnSignaturesMatch(method_fn, required_fn)) {
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "type '{s}' does not implement interface '{s}': method '{s}' has wrong signature",
                        .{ struct_name, iface_name, required_method.name },
                    );
                }
            }
        }
    }

    /// Compare two FnType signatures for compatibility.
    fn fnSignaturesMatch(self: *TypeChecker, actual: types.FnType, expected: types.FnType) bool {
        if (actual.params.len != expected.params.len) return false;
        if (!self.typesCompatible(actual.return_type, expected.return_type)) return false;
        for (actual.params, expected.params) |a, e| {
            if (a == types.null_type or e == types.null_type) continue;
            if (!self.typesCompatible(a, e)) return false;
        }
        return true;
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
        var is_variadic = false;
        const param_nodes = extra[params_start .. params_start + param_count];
        for (param_nodes) |param_node| {
            if (param_node == null_node) {
                try param_types.append(self.allocator, types.null_type);
                continue;
            }
            const param_tag = self.nodeTag(param_node);
            if (param_tag == .variadic_param) {
                is_variadic = true;
                const param_type_node = self.nodeData(param_node).lhs;
                const param_type = self.resolveTypeNode(param_type_node);
                try param_types.append(self.allocator, param_type);
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
            .is_variadic = is_variadic,
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
                    // Note: resolution_map doesn't have entries for param nodes,
                    // so we find param symbols by matching decl_node.
                    for (param_nodes, 0..) |param_node, i| {
                        if (param_node == null_node) continue;
                        if (i < ft.params.len) {
                            self.updateSymbolTypeByDeclNode(param_node, self.tokenSlice(self.nodeMainToken(param_node)), ft.params[i]);
                        }
                    }
                },
                else => {},
            }
        }

        // Update receiver symbol's type for methods.
        const receiver_node = extra[params_start + param_count + 1];
        if (receiver_node != null_node) {
            const recv_type_node = self.nodeData(receiver_node).lhs;
            const recv_type = self.resolveTypeNode(recv_type_node);
            const recv_name = self.tokenSlice(self.nodeMainToken(receiver_node));
            self.updateSymbolTypeByDeclNode(receiver_node, recv_name, recv_type);
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
            // If declared type is a sum type and init is a variant, validate it.
            if (declared_type != types.null_type and self.isSumType(declared_type) and
                self.nodeTag(init_node) == .variant)
            {
                init_type = try self.validateVariantAgainstSumType(init_node, declared_type);
            } else {
                init_type = try self.inferExpr(init_node);
            }
        }

        // Reject null assigned to non-nullable type.
        if (init_node != null_node and self.nodeTag(init_node) == .null_literal) {
            if (declared_type != types.null_type and !self.type_pool.isNullable(declared_type)) {
                const loc = self.tokenLoc(main_tok);
                try self.diagnostics.addErrorFmt(
                    loc.start,
                    loc.end,
                    "cannot assign null to non-nullable type '{s}'",
                    .{self.typeName(declared_type)},
                );
            }
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

        // Emit error if we couldn't infer the type from the initializer.
        if (init_type == types.null_type and init_node != null_node) {
            const loc = self.tokenLoc(self.nodeMainToken(node));
            try self.diagnostics.addErrorFmt(
                loc.start,
                loc.end,
                "cannot infer type for short variable declaration",
                .{},
            );
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

        // Check immutability: prevent reassignment to `let` variables.
        if (data.lhs != null_node and self.nodeTag(data.lhs) == .ident) {
            if (self.resolution_map[data.lhs]) |sym_id| {
                const sym = self.symbols.getSymbol(sym_id);
                if ((sym.kind == .variable or sym.kind == .param) and !sym.is_mutable) {
                    const loc = self.tokenLoc(self.nodeMainToken(node));
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "cannot assign to immutable variable '{s}'",
                        .{sym.name},
                    );
                }
            }
        }

        if (data.lhs != null_node and self.nodeTag(data.lhs) == .index_access) {
            try self.checkSimdLaneAssignTarget(data.lhs);
        }

        // Check const pointer write protection: prevent field assignment through @T.
        if (data.lhs != null_node and self.nodeTag(data.lhs) == .field_access) {
            try self.checkConstPtrFieldAssign(data.lhs);
        }

        // If LHS is a sum type and RHS is a variant, validate against the sum type.
        var rhs_type: TypeId = types.null_type;
        if (lhs_type != types.null_type and self.isSumType(lhs_type) and
            self.nodeTag(data.rhs) == .variant)
        {
            rhs_type = try self.validateVariantAgainstSumType(data.rhs, lhs_type);
        } else {
            rhs_type = try self.inferExpr(data.rhs);
        }

        // Reject null assigned to non-nullable type.
        if (self.nodeTag(data.rhs) == .null_literal) {
            if (lhs_type != types.null_type and !self.type_pool.isNullable(lhs_type)) {
                const loc = self.tokenLoc(self.nodeMainToken(node));
                try self.diagnostics.addErrorFmt(
                    loc.start,
                    loc.end,
                    "cannot assign null to non-nullable type '{s}'",
                    .{self.typeName(lhs_type)},
                );
            }
        }

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

        // Move semantics: if RHS is an identifier referencing an owned variable
        // (one initialized via alloc), mark it as moved.
        if (self.nodeTag(data.rhs) == .ident) {
            if (self.resolution_map[data.rhs]) |sym_id| {
                const sym = self.symbols.getSymbol(sym_id);
                if (sym.kind == .variable and self.isOwnedDecl(sym.decl_node)) {
                    try self.moved_nodes.append(self.allocator, sym.decl_node);
                }
            }
        }
    }

    fn checkSimdLaneAssignTarget(self: *TypeChecker, lane_node: NodeIndex) CheckError!void {
        const lane_data = self.nodeData(lane_node);
        const base_node = lane_data.lhs;
        if (base_node == null_node) return;

        if (self.nodeTag(base_node) != .ident) {
            const loc = self.tokenLoc(self.nodeMainToken(lane_node));
            try self.diagnostics.addError(loc.start, loc.end, "SIMD lane assignment target must be a local identifier or parameter");
            return;
        }

        const base_type = try self.inferExpr(base_node);
        if (base_type != types.null_type and !self.type_pool.isSimd(base_type)) {
            const loc = self.tokenLoc(self.nodeMainToken(lane_node));
            try self.diagnostics.addError(loc.start, loc.end, "lane assignment is only supported for SIMD vectors");
        }

        if (self.resolution_map[base_node]) |sym_id| {
            const sym = self.symbols.getSymbol(sym_id);
            if (sym.kind == .param) return;
            if (sym.kind != .variable) {
                const loc = self.tokenLoc(self.nodeMainToken(lane_node));
                try self.diagnostics.addError(loc.start, loc.end, "SIMD lane assignment target must be a local identifier or parameter");
                return;
            }
            if (!sym.is_mutable) {
                const loc = self.tokenLoc(self.nodeMainToken(lane_node));
                try self.diagnostics.addErrorFmt(loc.start, loc.end, "cannot assign to immutable variable '{s}'", .{sym.name});
            }
        }
    }

    /// Prevent writing to struct fields through a const pointer (@T).
    fn checkConstPtrFieldAssign(self: *TypeChecker, field_access_node: NodeIndex) CheckError!void {
        const fa_data = self.nodeData(field_access_node);
        const obj_node = fa_data.lhs;
        if (obj_node == null_node) return;

        // Get the raw type of the object (before pointer unwrapping).
        var obj_type_raw: TypeId = types.null_type;
        if (self.nodeTag(obj_node) == .ident) {
            if (self.resolution_map[obj_node]) |sym_id| {
                obj_type_raw = self.symbols.getSymbol(sym_id).type_id;
            }
        } else if (self.nodeTag(obj_node) == .field_access) {
            // Nested field access: check recursively
            obj_type_raw = try self.inferExpr(obj_node);
        } else if (self.nodeTag(obj_node) == .deref) {
            obj_type_raw = try self.inferExpr(self.nodeData(obj_node).lhs);
        }

        if (obj_type_raw == types.null_type) return;

        // Check if the object's type is a const pointer (@T).
        const resolved = self.type_pool.get(obj_type_raw);
        switch (resolved) {
            .ptr_type => |pt| {
                if (pt.is_const) {
                    const loc = self.tokenLoc(self.nodeMainToken(field_access_node));
                    try self.diagnostics.addError(
                        loc.start,
                        loc.end,
                        "cannot assign to field of read-only reference (@T)",
                    );
                }
            },
            else => {},
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
        const subject_type = try self.inferExpr(data.lhs);

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

        // Exhaustiveness checking for error unions, nullable types, and sum types.
        if (subject_type != types.null_type) {
            if (self.type_pool.isErrorUnion(subject_type)) {
                try self.checkErrorUnionExhaustiveness(node, arm_nodes);
            } else if (self.type_pool.isNullable(subject_type)) {
                try self.checkNullableExhaustiveness(node, arm_nodes);
            } else if (self.isSumType(subject_type)) {
                try self.checkSumTypeExhaustiveness(node, arm_nodes, subject_type);
            }
        }
    }

    /// Check that a switch on an error union covers .ok and .err (or has a wildcard _).
    fn checkErrorUnionExhaustiveness(self: *TypeChecker, node: NodeIndex, arm_nodes: []const NodeIndex) CheckError!void {
        var has_ok = false;
        var has_err = false;
        var has_wildcard = false;

        for (arm_nodes) |arm| {
            if (arm == null_node) continue;
            const pattern = self.nodeData(arm).lhs;
            if (pattern == null_node) continue;

            if (self.isWildcardPattern(pattern)) {
                has_wildcard = true;
                break;
            }

            if (self.nodeTag(pattern) == .variant) {
                const name = self.variantName(pattern);
                if (std.mem.eql(u8, name, "ok")) has_ok = true;
                if (std.mem.eql(u8, name, "err")) has_err = true;
            }
        }

        if (!has_wildcard and !(has_ok and has_err)) {
            const loc = self.tokenLoc(self.nodeMainToken(node));
            try self.diagnostics.addError(
                loc.start,
                loc.end,
                "non-exhaustive switch on error union: must cover .ok and .err (or use _)",
            );
        }
    }

    /// Check that a switch on a nullable covers .some and null (or has a wildcard _).
    fn checkNullableExhaustiveness(self: *TypeChecker, node: NodeIndex, arm_nodes: []const NodeIndex) CheckError!void {
        var has_some = false;
        var has_null = false;
        var has_wildcard = false;

        for (arm_nodes) |arm| {
            if (arm == null_node) continue;
            const pattern = self.nodeData(arm).lhs;
            if (pattern == null_node) continue;

            if (self.isWildcardPattern(pattern)) {
                has_wildcard = true;
                break;
            }

            if (self.nodeTag(pattern) == .null_literal) {
                has_null = true;
            } else if (self.nodeTag(pattern) == .variant) {
                const name = self.variantName(pattern);
                if (std.mem.eql(u8, name, "some")) has_some = true;
                if (std.mem.eql(u8, name, "null")) has_null = true;
            }
        }

        if (!has_wildcard and !(has_some and has_null)) {
            const loc = self.tokenLoc(self.nodeMainToken(node));
            try self.diagnostics.addError(
                loc.start,
                loc.end,
                "non-exhaustive switch on nullable: must cover .some and null (or use _)",
            );
        }
    }

    /// Check if a TypeId refers to a sum type.
    fn isSumType(self: *TypeChecker, type_id: TypeId) bool {
        return switch (self.type_pool.get(type_id)) {
            .sum_type => true,
            else => false,
        };
    }

    /// Check that a switch on a sum type covers all variants (or has a wildcard _).
    fn checkSumTypeExhaustiveness(
        self: *TypeChecker,
        node: NodeIndex,
        arm_nodes: []const NodeIndex,
        subject_type: TypeId,
    ) CheckError!void {
        const sum = switch (self.type_pool.get(subject_type)) {
            .sum_type => |s| s,
            else => return,
        };

        var has_wildcard = false;
        // Track which variants are covered (max 64 variants).
        var covered: [64]bool = .{false} ** 64;
        const variant_count = sum.variants.len;

        for (arm_nodes) |arm| {
            if (arm == null_node) continue;
            const pattern = self.nodeData(arm).lhs;
            if (pattern == null_node) continue;

            if (self.isWildcardPattern(pattern)) {
                has_wildcard = true;
                continue;
            }

            if (self.nodeTag(pattern) == .variant) {
                const name = self.variantName(pattern);

                // Find the matching variant in the sum type.
                var found = false;
                for (sum.variants, 0..) |v, vi| {
                    if (std.mem.eql(u8, v.name, name)) {
                        found = true;
                        // Check for duplicate variant in switch.
                        if (vi < 64 and covered[vi]) {
                            const pat_tok = self.nodeMainToken(pattern);
                            const loc = self.tokenLoc(pat_tok);
                            try self.diagnostics.addErrorFmt(
                                loc.start,
                                loc.end,
                                "duplicate variant '.{s}' in switch",
                                .{name},
                            );
                        }
                        if (vi < 64) covered[vi] = true;

                        // Validate payload: variant with data matched without binding, or vice versa.
                        const pattern_has_payload = self.nodeData(pattern).lhs != null_node;
                        const variant_has_payload = v.payload != types.null_type;
                        if (variant_has_payload and !pattern_has_payload) {
                            const pat_tok = self.nodeMainToken(pattern);
                            const loc = self.tokenLoc(pat_tok);
                            try self.diagnostics.addErrorFmt(
                                loc.start,
                                loc.end,
                                "variant '.{s}' carries data but pattern does not bind it",
                                .{name},
                            );
                        }

                        break;
                    }
                }

                if (!found) {
                    const pat_tok = self.nodeMainToken(pattern);
                    const loc = self.tokenLoc(pat_tok);
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "'.{s}' is not a variant of type '{s}'",
                        .{ name, sum.name },
                    );
                }
            }
        }

        if (!has_wildcard) {
            // Check that all variants are covered.
            var missing: std.ArrayList(u8) = .empty;
            defer missing.deinit(self.allocator);
            var missing_count: u32 = 0;

            for (0..variant_count) |vi| {
                if (vi < 64 and !covered[vi]) {
                    if (missing_count > 0) {
                        try missing.appendSlice(self.allocator, ", ");
                    }
                    try missing.appendSlice(self.allocator, ".");
                    try missing.appendSlice(self.allocator, sum.variants[vi].name);
                    missing_count += 1;
                }
            }

            if (missing_count > 0) {
                const loc = self.tokenLoc(self.nodeMainToken(node));
                try self.diagnostics.addErrorFmt(
                    loc.start,
                    loc.end,
                    "non-exhaustive switch on '{s}': missing variants: {s}",
                    .{ sum.name, missing.items },
                );
            }
        }
    }

    /// Extract the variant name (the identifier after the dot).
    fn variantName(self: *const TypeChecker, node: NodeIndex) []const u8 {
        const main_tok = self.nodeMainToken(node);
        // main_token is the dot; variant name is the next token.
        if (main_tok + 1 < self.tokens.len) {
            return self.tokenSlice(main_tok + 1);
        }
        return "";
    }

    /// Validate a variant expression against an expected sum type.
    /// Returns the sum TypeId if valid, or null_type if not.
    fn validateVariantAgainstSumType(
        self: *TypeChecker,
        variant_node: NodeIndex,
        expected_type: TypeId,
    ) CheckError!TypeId {
        const sum = switch (self.type_pool.get(expected_type)) {
            .sum_type => |s| s,
            else => return types.null_type,
        };

        const name = self.variantName(variant_node);
        const payload_node = self.nodeData(variant_node).lhs;

        for (sum.variants) |v| {
            if (std.mem.eql(u8, v.name, name)) {
                // Validate payload presence.
                if (v.payload != types.null_type and payload_node == null_node) {
                    const loc = self.tokenLoc(self.nodeMainToken(variant_node));
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "variant '.{s}' of '{s}' requires data of type '{s}'",
                        .{ name, sum.name, self.typeName(v.payload) },
                    );
                } else if (v.payload == types.null_type and payload_node != null_node) {
                    const loc = self.tokenLoc(self.nodeMainToken(variant_node));
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "variant '.{s}' of '{s}' does not carry data",
                        .{ name, sum.name },
                    );
                } else if (v.payload != types.null_type and payload_node != null_node) {
                    // Check payload type compatibility.
                    const payload_type = try self.inferExpr(payload_node);
                    if (payload_type != types.null_type and !self.typesCompatible(v.payload, payload_type)) {
                        const loc = self.tokenLoc(self.nodeMainToken(variant_node));
                        try self.diagnostics.addErrorFmt(
                            loc.start,
                            loc.end,
                            "variant '.{s}' payload type mismatch: expected '{s}', got '{s}'",
                            .{ name, self.typeName(v.payload), self.typeName(payload_type) },
                        );
                    }
                }
                return expected_type;
            }
        }

        // Variant not found in sum type.
        const loc = self.tokenLoc(self.nodeMainToken(variant_node));
        try self.diagnostics.addErrorFmt(
            loc.start,
            loc.end,
            "'.{s}' is not a variant of type '{s}'",
            .{ name, sum.name },
        );
        return types.null_type;
    }

    /// Check if a pattern is a wildcard `_`.
    fn isWildcardPattern(self: *const TypeChecker, node: NodeIndex) bool {
        if (self.nodeTag(node) == .ident) {
            return std.mem.eql(u8, self.tokenSlice(self.nodeMainToken(node)), "_");
        }
        return false;
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

            .ident => try self.inferIdent(node),

            .binary_op => try self.inferBinaryOp(node),
            .unary_op => try self.inferUnaryOp(node),

            .call => try self.inferCall(node),

            .field_access => try self.inferFieldAccess(node),

            .index_access => try self.inferIndexAccess(node),

            .addr_of => blk: {
                const operand_type = try self.inferExpr(self.nodeData(node).lhs);
                if (operand_type == types.null_type) break :blk types.null_type;
                break :blk try self.type_pool.intern(self.allocator, .{ .ptr_type = .{ .pointee = operand_type, .is_const = false } });
            },
            .addr_of_const => blk: {
                const operand_type = try self.inferExpr(self.nodeData(node).lhs);
                if (operand_type == types.null_type) break :blk types.null_type;
                break :blk try self.type_pool.intern(self.allocator, .{ .ptr_type = .{ .pointee = operand_type, .is_const = true } });
            },
            .deref => blk: {
                const operand_type = try self.inferExpr(self.nodeData(node).lhs);
                if (operand_type == types.null_type) break :blk types.null_type;
                // Validate that the operand is actually a pointer type.
                if (self.type_pool.unwrapPointer(operand_type)) |pointee| {
                    break :blk pointee;
                } else {
                    const loc = self.tokenLoc(self.nodeMainToken(node));
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "cannot dereference non-pointer type '{s}'",
                        .{self.typeName(operand_type)},
                    );
                    break :blk types.null_type;
                }
            },
            .chan_recv => blk: {
                _ = try self.inferExpr(self.nodeData(node).lhs);
                break :blk types.null_type;
            },
            .alloc_expr => blk: {
                const alloc_type_node = self.nodeData(node).lhs;
                if (alloc_type_node == null_node) break :blk types.null_type;
                if (self.nodeTag(alloc_type_node) == .type_chan) {
                    break :blk self.resolveTypeNode(alloc_type_node);
                }
                const pointee = self.resolveTypeNode(alloc_type_node);
                if (pointee == types.null_type) break :blk types.null_type;
                break :blk try self.type_pool.intern(self.allocator, .{ .ptr_type = .{
                    .pointee = pointee,
                    .is_const = false,
                } });
            },

            .try_expr => blk: {
                const operand_type = try self.inferExpr(self.nodeData(node).lhs);
                const loc = self.tokenLoc(self.nodeMainToken(node));

                // Validate operand is an error union.
                if (operand_type != types.null_type and !self.type_pool.isErrorUnion(operand_type)) {
                    try self.diagnostics.addError(
                        loc.start,
                        loc.end,
                        "'try' requires an error union operand",
                    );
                }

                // Validate enclosing function returns an error union.
                if (!self.type_pool.isErrorUnion(self.current_fn_return_type)) {
                    try self.diagnostics.addError(
                        loc.start,
                        loc.end,
                        "'try' requires enclosing function to return an error union",
                    );
                }

                // Unwrap !T → T.
                if (self.type_pool.unwrapErrorUnion(operand_type)) |payload| {
                    break :blk payload;
                }
                break :blk types.null_type;
            },

            .range => blk: {
                _ = try self.inferExpr(self.nodeData(node).lhs);
                _ = try self.inferExpr(self.nodeData(node).rhs);
                break :blk types.null_type;
            },

            .if_expr => try self.inferIfExpr(node),

            .struct_literal => try self.inferStructLiteral(node),
            .simd_literal => try self.inferSimdLiteral(node),

            .anon_struct_literal => blk: {
                const data = self.nodeData(node);
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
        const callee_node = data.lhs;

        // Collect argument types first.
        const args_start = data.rhs;
        const extra = self.tree.extra_data.items;
        const arg_count = self.findTrailingCount(args_start, extra);
        const arg_nodes = extra[args_start .. args_start + arg_count];

        var arg_types: [64]TypeId = undefined;
        const actual_count: u32 = @intCast(arg_nodes.len);
        for (arg_nodes, 0..) |arg, i| {
            arg_types[i] = try self.inferExpr(arg);
        }

        if (self.builtinCallName(callee_node)) |builtin_name| {
            return try self.inferBuiltinCall(builtin_name, arg_nodes[0..actual_count], arg_types[0..actual_count], node);
        }

        // Check if this is a method call (callee is field_access on a struct).
        if (callee_node != null_node and self.nodeTag(callee_node) == .field_access) {
            const fa_data = self.nodeData(callee_node);
            const obj_type_raw = try self.inferExpr(fa_data.lhs);
            if (obj_type_raw != types.null_type) {
                // Unwrap pointer to get the struct type.
                const obj_type = self.type_pool.unwrapPointer(obj_type_raw) orelse obj_type_raw;
                const resolved = self.type_pool.get(obj_type);
                switch (resolved) {
                    .struct_type => {
                        const method_name_tok = self.nodeMainToken(callee_node) + 1;
                        const method_name = self.tokenSlice(method_name_tok);

                        if (self.symbols.lookupMethod(obj_type, method_name)) |method_sym_id| {
                            const method_sym = self.symbols.getSymbol(method_sym_id);
                            const method_type_id = method_sym.type_id;

                            // Check mutability: if calling through @T (const ptr),
                            // the method must not require &T (mutable) receiver.
                            if (method_type_id != types.null_type) {
                                try self.checkMethodMutability(method_sym, obj_type_raw, method_name, node);
                            }

                            if (method_type_id != types.null_type) {
                                return self.checkFnCallArgs(method_type_id, arg_nodes[0..actual_count], arg_types[0..actual_count], node, true);
                            }
                            return types.null_type;
                        }
                        // Not a method — might be a field that's a function.
                        // Fall through to regular call checking.
                    },
                    else => {},
                }
            }
        }

        const callee_type = try self.inferExpr(callee_node);

        // If callee type is unknown, we can't check further.
        if (callee_type == types.null_type) return types.null_type;

        return self.checkFnCallArgs(callee_type, arg_nodes[0..actual_count], arg_types[0..actual_count], node, false);
    }

    fn builtinCallName(self: *TypeChecker, callee_node: NodeIndex) ?[]const u8 {
        if (callee_node == null_node or self.nodeTag(callee_node) != .field_access) return null;
        const callee_data = self.nodeData(callee_node);
        if (callee_data.lhs == null_node or self.nodeTag(callee_data.lhs) != .ident) return null;

        const package_name = self.tokenSlice(self.nodeMainToken(callee_data.lhs));
        const member_name = self.tokenSlice(self.nodeMainToken(callee_node) + 1);

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

    fn inferBuiltinCall(
        self: *TypeChecker,
        builtin_name: []const u8,
        arg_nodes: []const NodeIndex,
        arg_types: []const TypeId,
        call_node: NodeIndex,
    ) CheckError!TypeId {
        const call_tok = self.nodeMainToken(call_node);
        const call_loc = self.tokenLoc(call_tok);

        if (std.mem.eql(u8, builtin_name, "unsafe.alignof")) {
            if (arg_nodes.len != 1) {
                try self.diagnostics.addErrorFmt(call_loc.start, call_loc.end, "unsafe.alignof expects 1 argument, got {d}", .{arg_nodes.len});
                return types.primitives.int_id;
            }
            const arg_type = self.resolveTypeArgument(arg_nodes[0]) orelse arg_types[0];
            if (arg_type == types.null_type) {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[0]));
                try self.diagnostics.addError(loc.start, loc.end, "unsafe.alignof expects a type or typed expression");
            }
            return types.primitives.int_id;
        }

        if (std.mem.eql(u8, builtin_name, "simd.width")) {
            if (arg_nodes.len != 0) {
                try self.diagnostics.addErrorFmt(call_loc.start, call_loc.end, "simd.width expects 0 arguments, got {d}", .{arg_nodes.len});
            }
            return types.primitives.int_id;
        }

        if (std.mem.eql(u8, builtin_name, "simd.load") or std.mem.eql(u8, builtin_name, "simd.loadUnaligned")) {
            if (arg_nodes.len != 1) {
                try self.diagnostics.addErrorFmt(call_loc.start, call_loc.end, "{s} expects 1 argument, got {d}", .{ builtin_name, arg_nodes.len });
                return types.null_type;
            }
            const ptr_type = arg_types[0];
            const pointee = self.type_pool.unwrapPointer(ptr_type) orelse {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[0]));
                try self.diagnostics.addError(loc.start, loc.end, "simd.load expects a pointer-to-vector argument");
                return types.null_type;
            };
            if (!self.type_pool.isSimd(pointee) or self.type_pool.isSimdMask(pointee)) {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[0]));
                try self.diagnostics.addError(loc.start, loc.end, "simd.load expects a pointer-to-vector argument");
                return types.null_type;
            }
            return pointee;
        }

        if (std.mem.eql(u8, builtin_name, "simd.store")) {
            if (arg_nodes.len != 2) {
                try self.diagnostics.addErrorFmt(call_loc.start, call_loc.end, "simd.store expects 2 arguments, got {d}", .{arg_nodes.len});
                return types.null_type;
            }
            const ptr_type = arg_types[0];
            const resolved_ptr = self.type_pool.get(ptr_type);
            const pointee = self.type_pool.unwrapPointer(ptr_type) orelse {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[0]));
                try self.diagnostics.addError(loc.start, loc.end, "simd.store expects a mutable pointer-to-vector argument");
                return types.null_type;
            };
            switch (resolved_ptr) {
                .ptr_type => |ptr_type_info| {
                    if (ptr_type_info.is_const) {
                        const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[0]));
                        try self.diagnostics.addError(loc.start, loc.end, "simd.store expects a mutable pointer-to-vector argument");
                    }
                },
                else => {},
            }
            if (pointee != types.null_type and arg_types[1] != types.null_type and !self.type_pool.typeEql(pointee, arg_types[1])) {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[1]));
                try self.diagnostics.addErrorFmt(loc.start, loc.end, "simd.store value type mismatch: expected '{s}', got '{s}'", .{
                    self.typeName(pointee),
                    self.typeName(arg_types[1]),
                });
            }
            return types.null_type;
        }

        if (std.mem.eql(u8, builtin_name, "simd.hadd")) {
            const vec_type = try self.expectSimdVectorArgs(builtin_name, arg_nodes, arg_types, 1, call_node) orelse return types.null_type;
            return self.type_pool.simdElementType(vec_type) orelse types.null_type;
        }

        if (std.mem.eql(u8, builtin_name, "simd.dot")) {
            const vec_type = try self.expectSimdVectorArgs(builtin_name, arg_nodes, arg_types, 2, call_node) orelse return types.null_type;
            if (arg_types.len >= 2 and arg_types[1] != types.null_type and !self.type_pool.typeEql(vec_type, arg_types[1])) {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[1]));
                try self.diagnostics.addErrorFmt(loc.start, loc.end, "simd.dot requires matching vector types, got '{s}' and '{s}'", .{
                    self.typeName(vec_type),
                    self.typeName(arg_types[1]),
                });
            }
            return self.type_pool.simdElementType(vec_type) orelse types.null_type;
        }

        if (std.mem.eql(u8, builtin_name, "simd.min") or std.mem.eql(u8, builtin_name, "simd.max")) {
            const vec_type = try self.expectSimdVectorArgs(builtin_name, arg_nodes, arg_types, 2, call_node) orelse return types.null_type;
            if (arg_types.len >= 2 and arg_types[1] != types.null_type and !self.type_pool.typeEql(vec_type, arg_types[1])) {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[1]));
                try self.diagnostics.addErrorFmt(loc.start, loc.end, "{s} requires matching vector types, got '{s}' and '{s}'", .{
                    builtin_name,
                    self.typeName(vec_type),
                    self.typeName(arg_types[1]),
                });
            }
            return vec_type;
        }

        if (std.mem.eql(u8, builtin_name, "simd.select")) {
            if (arg_nodes.len != 3) {
                try self.diagnostics.addErrorFmt(call_loc.start, call_loc.end, "simd.select expects 3 arguments, got {d}", .{arg_nodes.len});
                return types.null_type;
            }
            const mask_type = arg_types[0];
            const true_type = arg_types[1];
            const false_type = arg_types[2];
            if (true_type == types.null_type or false_type == types.null_type) return types.null_type;
            if (!self.type_pool.typeEql(true_type, false_type)) {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[2]));
                try self.diagnostics.addErrorFmt(loc.start, loc.end, "simd.select requires matching vector arguments, got '{s}' and '{s}'", .{
                    self.typeName(true_type),
                    self.typeName(false_type),
                });
                return true_type;
            }
            if (!self.type_pool.isSimd(true_type) or self.type_pool.isSimdMask(true_type)) {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[1]));
                try self.diagnostics.addError(loc.start, loc.end, "simd.select expects vector arguments");
                return true_type;
            }
            const expected_mask = self.type_pool.simdMaskFor(true_type);
            if (expected_mask == null or mask_type == types.null_type or !self.type_pool.typeEql(mask_type, expected_mask.?)) {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[0]));
                try self.diagnostics.addErrorFmt(loc.start, loc.end, "simd.select mask type mismatch: expected '{s}', got '{s}'", .{
                    self.typeName(expected_mask orelse types.null_type),
                    self.typeName(mask_type),
                });
            }
            return true_type;
        }

        if (std.mem.eql(u8, builtin_name, "simd.shuffle")) {
            const vec_type = try self.expectSimdVectorArgs(builtin_name, arg_nodes[0..@min(arg_nodes.len, @as(usize, 1))], arg_types[0..@min(arg_types.len, @as(usize, 1))], 1, call_node) orelse return types.null_type;
            const simd = self.type_pool.getSimd(vec_type).?;
            const expected_arg_count: usize = 1 + simd.lanes;
            if (arg_nodes.len != expected_arg_count) {
                try self.diagnostics.addErrorFmt(call_loc.start, call_loc.end, "simd.shuffle expects {d} arguments for '{s}', got {d}", .{
                    expected_arg_count,
                    self.typeName(vec_type),
                    arg_nodes.len,
                });
                return vec_type;
            }
            for (arg_nodes[1..], 0..) |index_node, i| {
                if (self.nodeTag(index_node) != .int_literal) {
                    const loc = self.tokenLoc(self.nodeMainToken(index_node));
                    try self.diagnostics.addError(loc.start, loc.end, "simd.shuffle indices must be integer literals");
                    continue;
                }
                const text = self.tokenSlice(self.nodeMainToken(index_node));
                const lane_index = std.fmt.parseInt(i64, text, 10) catch {
                    const loc = self.tokenLoc(self.nodeMainToken(index_node));
                    try self.diagnostics.addError(loc.start, loc.end, "simd.shuffle indices must be integer literals");
                    continue;
                };
                _ = i;
                if (lane_index < 0 or lane_index >= simd.lanes) {
                    const loc = self.tokenLoc(self.nodeMainToken(index_node));
                    try self.diagnostics.addErrorFmt(loc.start, loc.end, "simd.shuffle index {d} is out of range for '{s}'", .{
                        lane_index,
                        self.typeName(vec_type),
                    });
                }
            }
            return vec_type;
        }

        // Unary element-wise math (float vectors only)
        if (std.mem.eql(u8, builtin_name, "simd.sqrt") or
            std.mem.eql(u8, builtin_name, "simd.abs") or
            std.mem.eql(u8, builtin_name, "simd.floor") or
            std.mem.eql(u8, builtin_name, "simd.ceil") or
            std.mem.eql(u8, builtin_name, "simd.round"))
        {
            const vec_type = try self.expectSimdVectorArgs(builtin_name, arg_nodes, arg_types, 1, call_node) orelse return types.null_type;
            const simd = self.type_pool.getSimd(vec_type).?;
            if (simd.elem_kind != .float) {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[0]));
                try self.diagnostics.addErrorFmt(loc.start, loc.end, "{s} requires a float vector argument", .{builtin_name});
                return types.null_type;
            }
            return vec_type;
        }

        // Ternary: fma (float only)
        if (std.mem.eql(u8, builtin_name, "simd.fma")) {
            if (arg_nodes.len != 3) {
                try self.diagnostics.addErrorFmt(call_loc.start, call_loc.end, "simd.fma expects 3 arguments, got {d}", .{arg_nodes.len});
                return types.null_type;
            }
            const vec_type = arg_types[0];
            if (vec_type == types.null_type) return types.null_type;
            if (!self.type_pool.isSimd(vec_type) or self.type_pool.isSimdMask(vec_type)) {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[0]));
                try self.diagnostics.addError(loc.start, loc.end, "simd.fma expects numeric SIMD vector arguments");
                return types.null_type;
            }
            const simd = self.type_pool.getSimd(vec_type).?;
            if (simd.elem_kind != .float) {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[0]));
                try self.diagnostics.addError(loc.start, loc.end, "simd.fma requires float vector arguments");
                return types.null_type;
            }
            for (arg_types[1..]) |at| {
                if (at != types.null_type and !self.type_pool.typeEql(vec_type, at)) {
                    try self.diagnostics.addErrorFmt(call_loc.start, call_loc.end, "simd.fma requires matching vector types", .{});
                    return vec_type;
                }
            }
            return vec_type;
        }

        // Ternary: clamp (all numeric vectors)
        if (std.mem.eql(u8, builtin_name, "simd.clamp")) {
            if (arg_nodes.len != 3) {
                try self.diagnostics.addErrorFmt(call_loc.start, call_loc.end, "simd.clamp expects 3 arguments, got {d}", .{arg_nodes.len});
                return types.null_type;
            }
            const vec_type = arg_types[0];
            if (vec_type == types.null_type) return types.null_type;
            if (!self.type_pool.isSimd(vec_type) or self.type_pool.isSimdMask(vec_type)) {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[0]));
                try self.diagnostics.addError(loc.start, loc.end, "simd.clamp expects numeric SIMD vector arguments");
                return types.null_type;
            }
            for (arg_types[1..]) |at| {
                if (at != types.null_type and !self.type_pool.typeEql(vec_type, at)) {
                    try self.diagnostics.addErrorFmt(call_loc.start, call_loc.end, "simd.clamp requires matching vector types", .{});
                    return vec_type;
                }
            }
            return vec_type;
        }

        // Broadcast: simd.broadcast(T, scalar)
        if (std.mem.eql(u8, builtin_name, "simd.broadcast")) {
            if (arg_nodes.len != 2) {
                try self.diagnostics.addErrorFmt(call_loc.start, call_loc.end, "simd.broadcast expects 2 arguments (type, scalar), got {d}", .{arg_nodes.len});
                return types.null_type;
            }
            const target_type = self.resolveTypeArgument(arg_nodes[0]) orelse {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[0]));
                try self.diagnostics.addError(loc.start, loc.end, "simd.broadcast first argument must be a SIMD vector type");
                return types.null_type;
            };
            if (!self.type_pool.isSimd(target_type) or self.type_pool.isSimdMask(target_type)) {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[0]));
                try self.diagnostics.addError(loc.start, loc.end, "simd.broadcast first argument must be a SIMD vector type");
                return types.null_type;
            }
            return target_type;
        }

        // Conversion: i32ToF32
        if (std.mem.eql(u8, builtin_name, "simd.i32ToF32")) {
            const vec_type = try self.expectSimdVectorArgs(builtin_name, arg_nodes, arg_types, 1, call_node) orelse return types.null_type;
            const simd = self.type_pool.getSimd(vec_type).?;
            if (simd.elem_kind != .int or simd.elem_bits != 32) {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[0]));
                try self.diagnostics.addError(loc.start, loc.end, "simd.i32ToF32 expects a v4i32 or v8i32 argument");
                return types.null_type;
            }
            return switch (simd.lanes) {
                4 => types.primitives.v4f32_id,
                8 => types.primitives.v8f32_id,
                else => types.null_type,
            };
        }

        // Conversion: f32ToI32
        if (std.mem.eql(u8, builtin_name, "simd.f32ToI32")) {
            const vec_type = try self.expectSimdVectorArgs(builtin_name, arg_nodes, arg_types, 1, call_node) orelse return types.null_type;
            const simd = self.type_pool.getSimd(vec_type).?;
            if (simd.elem_kind != .float or simd.elem_bits != 32) {
                const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[0]));
                try self.diagnostics.addError(loc.start, loc.end, "simd.f32ToI32 expects a v4f32 or v8f32 argument");
                return types.null_type;
            }
            return switch (simd.lanes) {
                4 => types.primitives.v4i32_id,
                8 => types.primitives.v8i32_id,
                else => types.null_type,
            };
        }

        return types.null_type;
    }

    fn expectSimdVectorArgs(
        self: *TypeChecker,
        builtin_name: []const u8,
        arg_nodes: []const NodeIndex,
        arg_types: []const TypeId,
        expected_count: usize,
        call_node: NodeIndex,
    ) CheckError!?TypeId {
        if (arg_nodes.len != expected_count) {
            const loc = self.tokenLoc(self.nodeMainToken(call_node));
            try self.diagnostics.addErrorFmt(loc.start, loc.end, "{s} expects {d} argument(s), got {d}", .{
                builtin_name,
                expected_count,
                arg_nodes.len,
            });
            return null;
        }
        const vec_type = arg_types[0];
        if (vec_type == types.null_type) return null;
        if (!self.type_pool.isSimd(vec_type) or self.type_pool.isSimdMask(vec_type)) {
            const loc = self.tokenLoc(self.nodeMainToken(arg_nodes[0]));
            try self.diagnostics.addErrorFmt(loc.start, loc.end, "{s} expects a numeric SIMD vector argument, got '{s}'", .{
                builtin_name,
                self.typeName(vec_type),
            });
            return null;
        }
        return vec_type;
    }

    fn resolveTypeArgument(self: *TypeChecker, node: NodeIndex) ?TypeId {
        if (node == null_node) return null;
        const tag = self.nodeTag(node);
        if (tag == .ident or tag == .type_name) {
            const name = self.tokenSlice(self.nodeMainToken(node));
            if (TypePool.lookupPrimitive(name)) |primitive| return primitive;
            if (self.symbols.lookup(name)) |sym_id| {
                const sym = self.symbols.getSymbol(sym_id);
                if (sym.kind == .type_def and sym.type_id != types.null_type) {
                    return sym.type_id;
                }
            }
        }
        return null;
    }

    /// Validate function call arguments against a FnType.
    /// If is_method is true, skip the first parameter (receiver).
    fn checkFnCallArgs(
        self: *TypeChecker,
        fn_type_id: TypeId,
        arg_nodes: []const NodeIndex,
        arg_types_slice: []const TypeId,
        call_node: NodeIndex,
        is_method: bool,
    ) CheckError!TypeId {
        const callee_resolved = self.type_pool.get(fn_type_id);
        switch (callee_resolved) {
            .fn_type => |fn_type| {
                // Note: For methods, the receiver is NOT included in FnType.params
                // (it's stored separately in the AST extra_data), so no skipping needed.
                _ = is_method;
                const params = fn_type.params;
                const expected_count: u32 = @intCast(params.len);
                const actual_count: u32 = @intCast(arg_nodes.len);
                const call_tok = self.nodeMainToken(call_node);

                // Check argument count.
                if (fn_type.is_variadic) {
                    // Variadic: require at least (expected_count - 1) args
                    // (the last declared param is the variadic one)
                    const required = if (expected_count > 0) expected_count - 1 else 0;
                    if (actual_count < required) {
                        const loc = self.tokenLoc(call_tok);
                        try self.diagnostics.addErrorFmt(
                            loc.start,
                            loc.end,
                            "function expects at least {d} argument(s), got {d}",
                            .{ required, actual_count },
                        );
                        return fn_type.return_type;
                    }
                } else if (actual_count != expected_count) {
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
                // For variadic functions, only check non-variadic params.
                // Variadic args accept any type.
                const check_count = if (fn_type.is_variadic)
                    @min(actual_count, if (expected_count > 0) expected_count - 1 else 0)
                else
                    actual_count;
                for (0..check_count) |i| {
                    const param_type = params[i];
                    if (param_type == types.null_type) continue;
                    const arg_type = arg_types_slice[i];
                    if (arg_type == types.null_type) continue;
                    if (!self.typesCompatible(param_type, arg_type)) {
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

    /// Check that a method call respects receiver mutability.
    /// If the object is accessed via @T (const pointer), the method must not require &T.
    fn checkMethodMutability(
        self: *TypeChecker,
        method_sym: Symbol,
        obj_type_raw: TypeId,
        method_name: []const u8,
        call_node: NodeIndex,
    ) CheckError!void {
        // Check if the object is accessed through a const pointer (@T).
        const is_const_ref = blk: {
            const obj_resolved = self.type_pool.get(obj_type_raw);
            break :blk switch (obj_resolved) {
                .ptr_type => |pt| pt.is_const,
                else => false,
            };
        };

        if (!is_const_ref) return;

        // Check if the method requires a mutable receiver (&T).
        const decl_node = method_sym.decl_node;
        if (decl_node == null_node) return;

        const fn_data = self.nodeData(decl_node);
        const params_start = fn_data.lhs;
        const extra = self.tree.extra_data.items;
        const param_count = self.findParamCount(params_start, extra);
        const receiver_node = extra[params_start + param_count + 1];
        if (receiver_node == null_node) return;

        const recv_type_node = self.nodeData(receiver_node).lhs;
        if (recv_type_node == null_node) return;

        // &T receiver = type_ptr, @T receiver = type_const_ptr
        if (self.nodeTag(recv_type_node) == .type_ptr) {
            const call_tok = self.nodeMainToken(call_node);
            const loc = self.tokenLoc(call_tok);
            try self.diagnostics.addErrorFmt(
                loc.start,
                loc.end,
                "cannot call mutating method '{s}' on read-only reference",
                .{method_name},
            );
        }
    }

    fn inferIdent(self: *TypeChecker, node: NodeIndex) CheckError!TypeId {
        if (self.resolution_map[node]) |sym_id| {
            const sym = self.symbols.getSymbol(sym_id);

            // Check for use-after-move on owned variables.
            if (sym.kind == .variable and self.isOwnedDecl(sym.decl_node)) {
                for (self.moved_nodes.items) |moved_node| {
                    if (moved_node == sym.decl_node) {
                        const loc = self.tokenLoc(self.nodeMainToken(node));
                        try self.diagnostics.addErrorFmt(
                            loc.start,
                            loc.end,
                            "use of moved value '{s}'",
                            .{sym.name},
                        );
                        break;
                    }
                }
            }

            return sym.type_id;
        }
        return types.null_type;
    }

    /// Check if a declaration node initializes the variable with an alloc expression.
    fn isOwnedDecl(self: *const TypeChecker, decl_node: NodeIndex) bool {
        if (decl_node == null_node) return false;
        const node = self.tree.nodes.items[decl_node];
        switch (node.tag) {
            .var_decl, .let_decl => {
                // data.rhs is the init expression
                if (node.data.rhs != null_node) {
                    return self.tree.nodes.items[node.data.rhs].tag == .alloc_expr;
                }
            },
            .short_var_decl => {
                // data.rhs is the init expression
                if (node.data.rhs != null_node) {
                    return self.tree.nodes.items[node.data.rhs].tag == .alloc_expr;
                }
            },
            else => {},
        }
        return false;
    }

    /// Infer the type of a field access expression (obj.field).
    fn inferFieldAccess(self: *TypeChecker, node: NodeIndex) CheckError!TypeId {
        const data = self.nodeData(node);
        const obj_type_raw = try self.inferExpr(data.lhs);
        if (obj_type_raw == types.null_type) return types.null_type;

        // Unwrap pointer types: &T or @T -> T
        const obj_type = self.type_pool.unwrapPointer(obj_type_raw) orelse obj_type_raw;

        const resolved = self.type_pool.get(obj_type);
        switch (resolved) {
            .struct_type => |st| {
                const field_name_tok = self.nodeMainToken(node) + 1;
                const field_name = self.tokenSlice(field_name_tok);

                // Search for the field.
                for (st.fields) |field| {
                    if (std.mem.eql(u8, field.name, field_name)) {
                        return field.type_id;
                    }
                }

                // Check if it's a method (don't error — it might be called).
                if (self.symbols.lookupMethod(obj_type, field_name) != null) {
                    // Return null_type; method calls are handled by inferCall.
                    return types.null_type;
                }

                // Field not found — emit error with suggestion.
                const loc = self.tokenLoc(field_name_tok);
                const suggestion = self.findClosestField(st.fields, field_name);
                if (suggestion) |s| {
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "type '{s}' has no field '{s}'; did you mean '{s}'?",
                        .{ st.name, field_name, s },
                    );
                } else {
                    try self.diagnostics.addErrorFmt(
                        loc.start,
                        loc.end,
                        "type '{s}' has no field '{s}'",
                        .{ st.name, field_name },
                    );
                }
                return types.null_type;
            },
            else => return types.null_type,
        }
    }

    fn inferIndexAccess(self: *TypeChecker, node: NodeIndex) CheckError!TypeId {
        const data = self.nodeData(node);
        const base_type = try self.inferExpr(data.lhs);
        const index_type = try self.inferExpr(data.rhs);

        if (base_type == types.null_type) return types.null_type;
        if (!self.type_pool.isSimd(base_type)) return types.null_type;

        if (index_type != types.null_type and !self.type_pool.isInteger(index_type)) {
            const loc = self.tokenLoc(self.nodeMainToken(data.rhs));
            try self.diagnostics.addError(loc.start, loc.end, "SIMD lane index must be an integer expression");
        }

        return self.type_pool.simdElementType(base_type) orelse types.null_type;
    }

    /// Find the closest matching field name for "did you mean" suggestions.
    fn findClosestField(self: *const TypeChecker, fields: []const types.StructField, target: []const u8) ?[]const u8 {
        _ = self;
        var best: ?[]const u8 = null;
        var best_dist: usize = std.math.maxInt(usize);
        for (fields) |field| {
            const dist = levenshteinDistance(field.name, target);
            if (dist < best_dist and dist <= 2) {
                best_dist = dist;
                best = field.name;
            }
        }
        return best;
    }

    /// Infer the type of a struct literal expression (TypeName{ field: value, ... }).
    fn inferStructLiteral(self: *TypeChecker, node: NodeIndex) CheckError!TypeId {
        const data = self.nodeData(node);

        // Resolve the struct type from the type name node.
        const type_name_node = data.lhs;
        var struct_type_id: TypeId = types.null_type;

        if (type_name_node != null_node) {
            const tag = self.nodeTag(type_name_node);
            if (tag == .ident) {
                const name = self.tokenSlice(self.nodeMainToken(type_name_node));
                if (self.symbols.lookup(name)) |sym_id| {
                    const sym = self.symbols.getSymbol(sym_id);
                    if (sym.kind == .type_def and sym.type_id != types.null_type) {
                        struct_type_id = sym.type_id;
                    }
                }
            }
        }

        // Collect field initializations.
        const fields_start = data.rhs;
        const extra = self.tree.extra_data.items;
        const field_count = self.findTrailingCount(fields_start, extra);
        const field_nodes = extra[fields_start .. fields_start + field_count];

        // Infer all field init value types.
        var init_types: [64]TypeId = undefined;
        for (field_nodes, 0..) |field, i| {
            if (field != null_node) {
                init_types[i] = try self.inferExpr(self.nodeData(field).lhs);
            } else {
                init_types[i] = types.null_type;
            }
        }

        if (struct_type_id == types.null_type) return types.null_type;

        const resolved = self.type_pool.get(struct_type_id);
        switch (resolved) {
            .struct_type => |st| {
                // Track which declared fields were initialized.
                var initialized: [64]bool = .{false} ** 64;
                const decl_field_count = st.fields.len;

                for (field_nodes, 0..) |field, i| {
                    if (field == null_node) continue;
                    const init_name_tok = self.nodeMainToken(field);
                    const init_name = self.tokenSlice(init_name_tok);

                    // Find matching declared field.
                    var found = false;
                    for (st.fields, 0..) |decl_field, fi| {
                        if (std.mem.eql(u8, decl_field.name, init_name)) {
                            found = true;
                            initialized[fi] = true;

                            // Check type compatibility.
                            const init_type = init_types[i];
                            if (init_type != types.null_type and decl_field.type_id != types.null_type) {
                                if (!self.typesCompatible(decl_field.type_id, init_type)) {
                                    const loc = self.tokenLoc(init_name_tok);
                                    try self.diagnostics.addErrorFmt(
                                        loc.start,
                                        loc.end,
                                        "field '{s}' type mismatch: expected '{s}', got '{s}'",
                                        .{ init_name, self.typeName(decl_field.type_id), self.typeName(init_type) },
                                    );
                                }
                            }
                            break;
                        }
                    }

                    if (!found) {
                        const loc = self.tokenLoc(init_name_tok);
                        try self.diagnostics.addErrorFmt(
                            loc.start,
                            loc.end,
                            "unknown field '{s}' in struct '{s}'",
                            .{ init_name, st.name },
                        );
                    }
                }

                // Check for missing required fields (no default value).
                for (0..decl_field_count) |fi| {
                    if (!initialized[fi]) {
                        const decl_field = st.fields[fi];
                        if (!self.fieldHasDefault(struct_type_id, fi)) {
                            const lit_tok = self.nodeMainToken(node);
                            const loc = self.tokenLoc(lit_tok);
                            try self.diagnostics.addErrorFmt(
                                loc.start,
                                loc.end,
                                "missing field '{s}' in '{s}' literal",
                                .{ decl_field.name, st.name },
                            );
                        }
                    }
                }

                return struct_type_id;
            },
            else => return types.null_type,
        }
    }

    fn inferSimdLiteral(self: *TypeChecker, node: NodeIndex) CheckError!TypeId {
        const data = self.nodeData(node);
        const simd_type = self.resolveTypeNode(data.lhs);
        if (simd_type == types.null_type) return types.null_type;
        if (!self.type_pool.isSimd(simd_type)) {
            const loc = self.tokenLoc(self.nodeMainToken(node));
            try self.diagnostics.addError(loc.start, loc.end, "SIMD literal requires a SIMD vector type");
            return types.null_type;
        }

        const simd = self.type_pool.getSimd(simd_type).?;
        const fields_start = data.rhs;
        const extra = self.tree.extra_data.items;
        const lane_count = self.findTrailingCount(fields_start, extra);
        const lane_nodes = extra[fields_start .. fields_start + lane_count];
        const expected_lane_count: usize = simd.lanes;
        if (lane_nodes.len != expected_lane_count) {
            const loc = self.tokenLoc(self.nodeMainToken(node));
            try self.diagnostics.addErrorFmt(loc.start, loc.end, "SIMD literal for '{s}' expects {d} lane(s), got {d}", .{
                self.typeName(simd_type),
                expected_lane_count,
                lane_nodes.len,
            });
        }

        const elem_type = self.type_pool.simdElementType(simd_type) orelse types.null_type;
        for (lane_nodes) |lane_node| {
            const lane_type = try self.inferExpr(lane_node);
            if (lane_type == types.null_type or elem_type == types.null_type) continue;
            if (!self.typesCompatible(elem_type, lane_type)) {
                const loc = self.tokenLoc(self.nodeMainToken(lane_node));
                try self.diagnostics.addErrorFmt(loc.start, loc.end, "SIMD literal lane type mismatch: expected '{s}', got '{s}'", .{
                    self.typeName(elem_type),
                    self.typeName(lane_type),
                });
            }
        }

        return simd_type;
    }

    /// Check if a struct field has a default value by looking at the struct_decl AST node.
    fn fieldHasDefault(self: *const TypeChecker, struct_type_id: TypeId, field_index: usize) bool {
        // Find the struct_decl node by scanning for a type_def symbol with this type_id.
        for (self.symbols.symbols.items) |sym| {
            if (sym.kind == .type_def and sym.type_id == struct_type_id) {
                const decl_node = sym.decl_node;
                if (decl_node == null_node) return false;
                const decl_data = self.nodeData(decl_node);
                const extra = self.tree.extra_data.items;
                const extra_start = decl_data.lhs;
                const implements_count = extra[extra_start];
                const fields_start = extra_start + 1 + implements_count;
                const field_node = extra[fields_start + field_index];
                // field_decl: rhs = default value (or null_node)
                return self.nodeData(field_node).rhs != null_node;
            }
        }
        return false;
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
                if (self.type_pool.isSimd(lhs_type) or self.type_pool.isSimd(rhs_type)) {
                    if (!self.type_pool.isSimd(lhs_type) or !self.type_pool.isSimd(rhs_type) or !self.type_pool.typeEql(lhs_type, rhs_type)) {
                        const loc = self.tokenLoc(op_tok);
                        try self.diagnostics.addErrorFmt(
                            loc.start,
                            loc.end,
                            "SIMD operator '{s}' requires matching vector operands, got '{s}' and '{s}'",
                            .{ self.tokenSlice(op_tok), self.typeName(lhs_type), self.typeName(rhs_type) },
                        );
                        return types.null_type;
                    }
                    if (self.type_pool.isSimdMask(lhs_type) or op == .percent) {
                        const loc = self.tokenLoc(op_tok);
                        try self.diagnostics.addErrorFmt(
                            loc.start,
                            loc.end,
                            "SIMD operator '{s}' is not supported for '{s}'",
                            .{ self.tokenSlice(op_tok), self.typeName(lhs_type) },
                        );
                        return types.null_type;
                    }
                    return lhs_type;
                }
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
                if (self.type_pool.isSimd(lhs_type) or self.type_pool.isSimd(rhs_type)) {
                    if (!self.type_pool.isSimd(lhs_type) or !self.type_pool.isSimd(rhs_type) or !self.type_pool.typeEql(lhs_type, rhs_type)) {
                        const loc = self.tokenLoc(op_tok);
                        try self.diagnostics.addErrorFmt(
                            loc.start,
                            loc.end,
                            "cannot compare '{s}' and '{s}'",
                            .{ self.typeName(lhs_type), self.typeName(rhs_type) },
                        );
                        return types.null_type;
                    }
                    return self.type_pool.simdMaskFor(lhs_type) orelse types.null_type;
                }
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
                // Check primitives first.
                if (TypePool.lookupPrimitive(name)) |prim| return prim;
                // Check user-defined types (structs, etc.).
                if (self.symbols.lookup(name)) |sym_id| {
                    const sym = self.symbols.getSymbol(sym_id);
                    if (sym.kind == .type_def and sym.type_id != types.null_type) {
                        return sym.type_id;
                    }
                }
                return types.null_type;
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
            .type_ptr => {
                const inner = self.nodeData(node).lhs;
                const inner_type = self.resolveTypeNode(inner);
                if (inner_type == types.null_type) return types.null_type;
                return self.type_pool.intern(self.allocator, .{ .ptr_type = .{
                    .pointee = inner_type,
                    .is_const = false,
                } }) catch types.null_type;
            },
            .type_const_ptr => {
                const inner = self.nodeData(node).lhs;
                const inner_type = self.resolveTypeNode(inner);
                if (inner_type == types.null_type) return types.null_type;
                return self.type_pool.intern(self.allocator, .{ .ptr_type = .{
                    .pointee = inner_type,
                    .is_const = true,
                } }) catch types.null_type;
            },
            .type_nullable => {
                // T? — resolve the inner type and wrap in nullable.
                const inner = self.nodeData(node).lhs;
                const inner_type = self.resolveTypeNode(inner);
                if (inner_type == types.null_type) return types.null_type;
                return self.type_pool.intern(self.allocator, .{ .nullable_type = .{
                    .inner = inner_type,
                } }) catch types.null_type;
            },
            .type_slice => {
                const inner = self.nodeData(node).lhs;
                const inner_type = self.resolveTypeNode(inner);
                if (inner_type == types.null_type) return types.null_type;
                return self.type_pool.intern(self.allocator, .{ .slice_type = .{
                    .elem = inner_type,
                } }) catch types.null_type;
            },
            .type_chan => {
                const inner = self.nodeData(node).lhs;
                const inner_type = self.resolveTypeNode(inner);
                if (inner_type == types.null_type) return types.null_type;
                return self.type_pool.intern(self.allocator, .{ .chan_type = .{
                    .elem = inner_type,
                } }) catch types.null_type;
            },
            .type_map => {
                const extra = self.tree.extra_data.items;
                const key_type = self.resolveTypeNode(extra[self.nodeData(node).lhs]);
                const value_type = self.resolveTypeNode(extra[self.nodeData(node).lhs + 1]);
                if (key_type == types.null_type or value_type == types.null_type) return types.null_type;
                return self.type_pool.intern(self.allocator, .{ .map_type = .{
                    .key = key_type,
                    .value = value_type,
                } }) catch types.null_type;
            },
            else => types.null_type,
        };
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    fn typesCompatible(self: *TypeChecker, a: TypeId, b: TypeId) bool {
        if (a == b) return true;
        // `any` is compatible with all types.
        if (a == types.primitives.any_id or b == types.primitives.any_id) return true;
        // Both numeric types are compatible for comparisons.
        if (self.type_pool.isNumeric(a) and self.type_pool.isNumeric(b)) return true;
        // T is assignable to !T (error union wrapping).
        if (self.type_pool.unwrapErrorUnion(a)) |payload| {
            if (self.typesCompatible(payload, b)) return true;
        }
        // T is assignable to T? (nullable wrapping).
        if (self.type_pool.unwrapNullable(a)) |inner| {
            if (self.typesCompatible(inner, b)) return true;
        }
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
                types.primitives.any_id => "any",
                types.primitives.i8_id => "i8",
                types.primitives.i16_id => "i16",
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
                else => "<unknown>",
            };
        }
        // For non-primitive types, check the type kind.
        const typ = self.type_pool.get(type_id);
        return switch (typ) {
            .error_union_type => "!T",
            .nullable_type => "T?",
            .fn_type => "fn",
            .struct_type => |st| st.name,
            .interface_type => |it| it.name,
            .sum_type => |st| st.name,
            .ptr_type => |pt| {
                if (pt.is_const) return "@T";
                return "&T";
            },
            .simd_type => |simd| switch (simd.elem_kind) {
                .bool => switch (simd.lanes) {
                    2 => "v2bool",
                    4 => "v4bool",
                    8 => "v8bool",
                    16 => "v16bool",
                    32 => "v32bool",
                    else => "<unknown>",
                },
                .float => switch (simd.lanes) {
                    2 => "v2f64",
                    4 => if (simd.elem_bits == 32) "v4f32" else "v4f64",
                    8 => "v8f32",
                    else => "<unknown>",
                },
                .int => switch (simd.lanes) {
                    4 => "v4i32",
                    8 => if (simd.elem_bits == 16) "v8i16" else "v8i32",
                    16 => if (simd.elem_bits == 8) "v16i8" else "v16i16",
                    32 => "v32i8",
                    else => "<unknown>",
                },
            },
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

/// Compute Levenshtein edit distance between two strings.
fn levenshteinDistance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    if (a.len > 32 or b.len > 32) return std.math.maxInt(usize);

    var prev_row: [33]usize = undefined;
    var curr_row: [33]usize = undefined;

    for (0..b.len + 1) |j| {
        prev_row[j] = j;
    }

    for (a, 0..) |ca, i| {
        curr_row[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            curr_row[j + 1] = @min(@min(curr_row[j] + 1, prev_row[j + 1] + 1), prev_row[j] + cost);
        }
        @memcpy(prev_row[0 .. b.len + 1], curr_row[0 .. b.len + 1]);
    }

    return prev_row[b.len];
}

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

    const has_resolve_errors = res.diagnostics.hasErrors();
    const has_tc_errors = tc_result.diagnostics.hasErrors();
    return .{
        .has_errors = has_resolve_errors or has_tc_errors,
        .error_count = res.diagnostics.diagnostics.items.len + tc_result.diagnostics.diagnostics.items.len,
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

    // Check both resolve and typecheck diagnostics for the needle.
    for (res.diagnostics.diagnostics.items) |d| {
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
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

// ── Struct type checking tests ──────────────────────────────────────────────────

test "typecheck: struct literal with correct field types" {
    const result = try testTypeCheck(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn main() {
        \\    p := Point{ x: 1, y: 2 }
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: struct literal with type mismatch" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn main() {
        \\    p := Point{ x: "hello", y: 2 }
        \\}
        \\
    , "field 'x' type mismatch");
    try std.testing.expect(has_err);
}

test "typecheck: struct literal missing required field" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn main() {
        \\    p := Point{ x: 1 }
        \\}
        \\
    , "missing field 'y'");
    try std.testing.expect(has_err);
}

test "typecheck: struct literal unknown field" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn main() {
        \\    p := Point{ x: 1, y: 2, z: 3 }
        \\}
        \\
    , "unknown field 'z'");
    try std.testing.expect(has_err);
}

test "typecheck: field access returns correct type" {
    const result = try testTypeCheck(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn main() {
        \\    p := Point{ x: 1, y: 2 }
        \\    var a int = p.x
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: field access type mismatch" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn main() {
        \\    p := Point{ x: 1, y: 2 }
        \\    var a string = p.x
        \\}
        \\
    , "type mismatch");
    try std.testing.expect(has_err);
}

test "typecheck: field access on non-existent field" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn main() {
        \\    p := Point{ x: 1, y: 2 }
        \\    var a int = p.z
        \\}
        \\
    , "has no field 'z'");
    try std.testing.expect(has_err);
}

test "typecheck: field access did you mean suggestion" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\Config struct {
        \\    name string
        \\    value int
        \\}
        \\fn main() {
        \\    c := Config{ name: "test", value: 1 }
        \\    var n string = c.nam
        \\}
        \\
    , "did you mean 'name'");
    try std.testing.expect(has_err);
}

test "typecheck: nested struct field access" {
    const result = try testTypeCheck(
        \\Inner struct {
        \\    value int
        \\}
        \\Outer struct {
        \\    inner Inner
        \\}
        \\fn main() {
        \\    i := Inner{ value: 42 }
        \\    o := Outer{ inner: i }
        \\    var v int = o.inner.value
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: var with struct type annotation" {
    const result = try testTypeCheck(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn main() {
        \\    var p Point = Point{ x: 1, y: 2 }
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: var with struct type mismatch" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn main() {
        \\    var p Point = 42
        \\}
        \\
    , "type mismatch");
    try std.testing.expect(has_err);
}

test "typecheck: method call with correct args" {
    const result = try testTypeCheck(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn (self &Point) scale(factor int) int {
        \\    return self.x
        \\}
        \\fn main() {
        \\    p := Point{ x: 1, y: 2 }
        \\    var r int = p.scale(3)
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: method call wrong arg count" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn (self &Point) scale(factor int) int {
        \\    return self.x
        \\}
        \\fn main() {
        \\    p := Point{ x: 1, y: 2 }
        \\    p.scale(1, 2)
        \\}
        \\
    , "expects 1 argument(s), got 2");
    try std.testing.expect(has_err);
}

test "typecheck: method call arg type mismatch" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn (self &Point) scale(factor int) int {
        \\    return self.x
        \\}
        \\fn main() {
        \\    p := Point{ x: 1, y: 2 }
        \\    p.scale("hello")
        \\}
        \\
    , "argument 1 type mismatch");
    try std.testing.expect(has_err);
}

test "typecheck: mutating method on const ref" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\Counter struct {
        \\    count int
        \\}
        \\fn (self &Counter) increment() int {
        \\    return self.count
        \\}
        \\fn callIt(c @Counter) int {
        \\    return c.increment()
        \\}
        \\
    , "cannot call mutating method 'increment' on read-only reference");
    try std.testing.expect(has_err);
}

test "typecheck: const method on const ref is ok" {
    const result = try testTypeCheck(
        \\Counter struct {
        \\    count int
        \\}
        \\fn (self @Counter) getCount() int {
        \\    return self.count
        \\}
        \\fn callIt(c @Counter) int {
        \\    return c.getCount()
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: method with no args" {
    const result = try testTypeCheck(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn (self &Point) getX() int {
        \\    return self.x
        \\}
        \\fn main() {
        \\    p := Point{ x: 1, y: 2 }
        \\    var x int = p.getX()
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: struct field with struct type" {
    const result = try testTypeCheck(
        \\Name struct {
        \\    first string
        \\    last string
        \\}
        \\Person struct {
        \\    name Name
        \\    age int
        \\}
        \\fn main() {
        \\    n := Name{ first: "John", last: "Doe" }
        \\    p := Person{ name: n, age: 30 }
        \\    var f string = p.name.first
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: struct satisfies interface" {
    const result = try testTypeCheck(
        \\type Stringer interface {
        \\    to_string() string
        \\}
        \\Point struct {
        \\    implements (
        \\        Stringer,
        \\    )
        \\    x int
        \\    y int
        \\}
        \\fn (p &Point) to_string() string {
        \\    return "point"
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: struct missing method from interface" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\type Stringer interface {
        \\    to_string() string
        \\}
        \\Point struct {
        \\    implements (
        \\        Stringer,
        \\    )
        \\    x int
        \\}
        \\
    , "missing method");
    try std.testing.expect(has_err);
}

test "typecheck: method wrong parameter type" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\type Adder interface {
        \\    add(x int) int
        \\}
        \\Calc struct {
        \\    implements (
        \\        Adder,
        \\    )
        \\    val int
        \\}
        \\fn (c &Calc) add(x string) int {
        \\    return 0
        \\}
        \\
    , "wrong signature");
    try std.testing.expect(has_err);
}

test "typecheck: method wrong return type" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\type Stringer interface {
        \\    to_string() string
        \\}
        \\Point struct {
        \\    implements (
        \\        Stringer,
        \\    )
        \\    x int
        \\}
        \\fn (p &Point) to_string() int {
        \\    return 0
        \\}
        \\
    , "wrong signature");
    try std.testing.expect(has_err);
}

test "typecheck: method wrong parameter count" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\type Adder interface {
        \\    add(x int) int
        \\}
        \\Calc struct {
        \\    implements (
        \\        Adder,
        \\    )
        \\    val int
        \\}
        \\fn (c &Calc) add(x int, y int) int {
        \\    return 0
        \\}
        \\
    , "wrong signature");
    try std.testing.expect(has_err);
}

test "typecheck: struct satisfies multiple interfaces" {
    const result = try testTypeCheck(
        \\type Stringer interface {
        \\    to_string() string
        \\}
        \\type Adder interface {
        \\    add(x int) int
        \\}
        \\Widget struct {
        \\    implements (
        \\        Stringer,
        \\        Adder,
        \\    )
        \\    val int
        \\}
        \\fn (w &Widget) to_string() string {
        \\    return "widget"
        \\}
        \\fn (w &Widget) add(x int) int {
        \\    return 0
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: one of multiple interfaces not satisfied" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\type Stringer interface {
        \\    to_string() string
        \\}
        \\type Adder interface {
        \\    add(x int) int
        \\}
        \\Widget struct {
        \\    implements (
        \\        Stringer,
        \\        Adder,
        \\    )
        \\    val int
        \\}
        \\fn (w &Widget) to_string() string {
        \\    return "widget"
        \\}
        \\
    , "missing method");
    try std.testing.expect(has_err);
}

test "typecheck: undefined interface in implements" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\Point struct {
        \\    implements (
        \\        NonExistent,
        \\    )
        \\    x int
        \\}
        \\
    , "undefined interface");
    try std.testing.expect(has_err);
}

test "typecheck: interface type as function parameter" {
    const result = try testTypeCheck(
        \\type Stringer interface {
        \\    to_string() string
        \\}
        \\fn print_it(s Stringer) {
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

// ── Error union and nullable type checking tests ────────────────────────────

test "typecheck: error union return type construction" {
    const result = try testTypeCheck(
        \\fn readFile() !int {
        \\    return 42
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: nullable type construction in var decl" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int? = null
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: try on error union valid" {
    const result = try testTypeCheck(
        \\fn readFile() !int {
        \\    return 42
        \\}
        \\fn main() !int {
        \\    var x int = try readFile()
        \\    return x
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: try on non-error-union operand" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\fn get_val() int {
        \\    return 42
        \\}
        \\fn main() !int {
        \\    var x int = try get_val()
        \\    return x
        \\}
        \\
    , "'try' requires an error union operand");
    try std.testing.expect(has_err);
}

test "typecheck: try in non-error-union function" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\fn readFile() !int {
        \\    return 42
        \\}
        \\fn main() {
        \\    var x int = try readFile()
        \\}
        \\
    , "'try' requires enclosing function to return an error union");
    try std.testing.expect(has_err);
}

test "typecheck: null assigned to nullable type" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int? = null
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: null assigned to non-nullable type rejected" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\fn main() {
        \\    var x int = null
        \\}
        \\
    , "cannot assign null to non-nullable type");
    try std.testing.expect(has_err);
}

test "typecheck: null assigned to non-nullable in assignment" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\fn main() {
        \\    var x int = 42
        \\    x = null
        \\}
        \\
    , "cannot assign null to non-nullable type");
    try std.testing.expect(has_err);
}

test "typecheck: switch exhaustive on error union" {
    const result = try testTypeCheck(
        \\fn readFile() !int {
        \\    return 42
        \\}
        \\fn main() {
        \\    switch readFile() {
        \\        .ok(val) :: val,
        \\        .err(e) :: e,
        \\    }
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: switch non-exhaustive on error union missing err" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\fn readFile() !int {
        \\    return 42
        \\}
        \\fn main() {
        \\    switch readFile() {
        \\        .ok(val) :: val,
        \\    }
        \\}
        \\
    , "non-exhaustive switch on error union");
    try std.testing.expect(has_err);
}

test "typecheck: switch exhaustive on nullable" {
    const result = try testTypeCheck(
        \\fn find() int? {
        \\    return 42
        \\}
        \\fn main() {
        \\    switch find() {
        \\        .some(val) :: val,
        \\        null :: 0,
        \\    }
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: switch non-exhaustive on nullable missing null" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\fn find() int? {
        \\    return 42
        \\}
        \\fn main() {
        \\    switch find() {
        \\        .some(val) :: val,
        \\    }
        \\}
        \\
    , "non-exhaustive switch on nullable");
    try std.testing.expect(has_err);
}

test "typecheck: switch with wildcard on error union" {
    const result = try testTypeCheck(
        \\fn readFile() !int {
        \\    return 42
        \\}
        \\fn main() {
        \\    switch readFile() {
        \\        _ :: 0,
        \\    }
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

// ── Short variable declaration inference tests ──────────────────────────────

test "typecheck: short var decl infers float" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    x := 3.14
        \\    x = "hello"
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: short var decl infers bool" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    x := true
        \\    x = 42
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: short var decl infers from function call" {
    const result = try testTypeCheck(
        \\fn get_num() int {
        \\    return 42
        \\}
        \\fn main() {
        \\    x := get_num()
        \\    x = "hello"
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: short var decl infers from function call valid" {
    const result = try testTypeCheck(
        \\fn get_num() int {
        \\    return 42
        \\}
        \\fn main() {
        \\    x := get_num()
        \\    x = 100
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: short var decl infers from binary op" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    x := 1 + 2
        \\    x = "hello"
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: short var decl infers from comparison" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    x := 1 < 2
        \\    x = 42
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: short var decl infers from field access" {
    const result = try testTypeCheck(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn main() {
        \\    p := Point{ x: 1, y: 2 }
        \\    v := p.x
        \\    v = "hello"
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: short var decl chained inference" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    x := 42
        \\    y := x
        \\    y = "hello"
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: short var decl infers from struct literal" {
    const result = try testTypeCheck(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn main() {
        \\    p := Point{ x: 1, y: 2 }
        \\    p = 42
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "typecheck: short var decl valid reassignment" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    x := 42
        \\    x = 100
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

// ── Sum type and pattern match exhaustiveness tests ─────────────────────────

test "typecheck: sum type registration" {
    const result = try testTypeCheck(
        \\type State = .loading | .ready(string) | .error(string)
        \\fn main() {
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: switch exhaustive on sum type" {
    const result = try testTypeCheck(
        \\type State = .loading | .ready(string) | .error(string)
        \\fn main() {
        \\    var s State = .loading
        \\    switch s {
        \\        .loading :: 0,
        \\        .ready(data) :: 1,
        \\        .error(msg) :: 2,
        \\    }
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: switch non-exhaustive on sum type missing variant" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\type State = .loading | .ready(string) | .error(string)
        \\fn main() {
        \\    var s State = .loading
        \\    switch s {
        \\        .loading :: 0,
        \\        .ready(data) :: 1,
        \\    }
        \\}
        \\
    , "non-exhaustive switch on 'State'");
    try std.testing.expect(has_err);
}

test "typecheck: switch non-exhaustive lists missing variants" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\type Color = .red | .green | .blue
        \\fn main() {
        \\    var c Color = .red
        \\    switch c {
        \\        .red :: 0,
        \\    }
        \\}
        \\
    , ".green, .blue");
    try std.testing.expect(has_err);
}

test "typecheck: switch with wildcard on sum type satisfies exhaustiveness" {
    const result = try testTypeCheck(
        \\type Color = .red | .green | .blue
        \\fn main() {
        \\    var c Color = .red
        \\    switch c {
        \\        .red :: 0,
        \\        _ :: 1,
        \\    }
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: switch duplicate variant on sum type" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\type Color = .red | .green | .blue
        \\fn main() {
        \\    var c Color = .red
        \\    switch c {
        \\        .red :: 0,
        \\        .red :: 1,
        \\        .green :: 2,
        \\        .blue :: 3,
        \\    }
        \\}
        \\
    , "duplicate variant '.red'");
    try std.testing.expect(has_err);
}

test "typecheck: switch invalid variant name on sum type" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\type Color = .red | .green | .blue
        \\fn main() {
        \\    var c Color = .red
        \\    switch c {
        \\        .red :: 0,
        \\        .green :: 1,
        \\        .yellow :: 2,
        \\    }
        \\}
        \\
    , "is not a variant of type 'Color'");
    try std.testing.expect(has_err);
}

test "typecheck: variant construction valid" {
    const result = try testTypeCheck(
        \\type State = .loading | .ready(string) | .error(string)
        \\fn main() {
        \\    var s State = .loading
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: variant construction with payload valid" {
    const result = try testTypeCheck(
        \\type State = .loading | .ready(string) | .error(string)
        \\fn main() {
        \\    var s State = .ready("hello")
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: variant construction invalid variant name" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\type State = .loading | .ready(string) | .error(string)
        \\fn main() {
        \\    var s State = .pending
        \\}
        \\
    , "is not a variant of type 'State'");
    try std.testing.expect(has_err);
}

test "typecheck: variant construction missing required payload" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\type State = .loading | .ready(string) | .error(string)
        \\fn main() {
        \\    var s State = .ready
        \\}
        \\
    , "requires data");
    try std.testing.expect(has_err);
}

test "typecheck: variant construction payload type mismatch" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\type State = .loading | .ready(string) | .error(string)
        \\fn main() {
        \\    var s State = .ready(42)
        \\}
        \\
    , "payload type mismatch");
    try std.testing.expect(has_err);
}

test "typecheck: variant construction unwanted payload" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\type State = .loading | .ready(string) | .error(string)
        \\fn main() {
        \\    var s State = .loading("extra")
        \\}
        \\
    , "does not carry data");
    try std.testing.expect(has_err);
}

test "typecheck: variant assignment valid" {
    const result = try testTypeCheck(
        \\type State = .loading | .ready(string) | .error(string)
        \\fn main() {
        \\    var s State = .loading
        \\    s = .ready("done")
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: variant assignment invalid variant" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\type State = .loading | .ready(string) | .error(string)
        \\fn main() {
        \\    var s State = .loading
        \\    s = .unknown
        \\}
        \\
    , "is not a variant of type 'State'");
    try std.testing.expect(has_err);
}

test "typecheck: sum type without payloads" {
    const result = try testTypeCheck(
        \\type Direction = .north | .south | .east | .west
        \\fn go(d Direction) int {
        \\    switch d {
        \\        .north :: 0,
        \\        .south :: 1,
        \\        .east :: 2,
        \\        .west :: 3,
        \\    }
        \\    return 0
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: switch variant payload not bound when required" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\type Result = .ok(int) | .err(string)
        \\fn main() {
        \\    var r Result = .ok(42)
        \\    switch r {
        \\        .ok :: 0,
        \\        .err(msg) :: 1,
        \\    }
        \\}
        \\
    , "carries data but pattern does not bind it");
    try std.testing.expect(has_err);
}

test "typecheck: use-after-move produces error" {
    const has_err = try testTypeCheckHasErrorContaining(
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

test "typecheck: owned variable without move has no error" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    let s = alloc([]int, 8)
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

// ── M2: Let immutability enforcement tests ──────────────────────────────────

test "typecheck: let reassignment rejected" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\fn main() {
        \\    let x int = 42
        \\    x = 100
        \\}
        \\
    , "cannot assign to immutable variable 'x'");
    try std.testing.expect(has_err);
}

test "typecheck: var reassignment allowed" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = 42
        \\    x = 100
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: let string reassignment rejected" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\fn main() {
        \\    let s string = "hello"
        \\    s = "world"
        \\}
        \\
    , "cannot assign to immutable variable");
    try std.testing.expect(has_err);
}

// ── M2: Const pointer write protection tests ────────────────────────────────

test "typecheck: const ptr field write rejected" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn update(p @Point) {
        \\    p.x = 42
        \\}
        \\
    , "cannot assign to field of read-only reference (@T)");
    try std.testing.expect(has_err);
}

test "typecheck: mutable ptr field write allowed" {
    const result = try testTypeCheck(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn update(p &Point) {
        \\    p.x = 42
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

// ── M2: Dereference validation tests ─────────────────────────────────────────

test "typecheck: deref non-pointer rejected" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\fn main() {
        \\    var x int = 42
        \\    var y = x.*
        \\}
        \\
    , "cannot dereference non-pointer type");
    try std.testing.expect(has_err);
}

test "typecheck: deref pointer valid" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = 42
        \\    var p &int = &x
        \\    var y = p.*
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

// ── M2: Pointer type compatibility tests ────────────────────────────────────

test "typecheck: pointer type variables" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = 42
        \\    var p &int = &x
        \\    var q @int = @x
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

// ── M2: Pointer type inference tests ────────────────────────────────────────

test "typecheck: addr_of creates mutable pointer" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = 42
        \\    var p &int = &x
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: addr_of_const creates const pointer" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var x int = 42
        \\    var p @int = @x
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

// ── M2: Ownership and move semantics tests ──────────────────────────────────

test "typecheck: use-after-move in expression" {
    const has_err = try testTypeCheckHasErrorContaining(
        \\fn main() {
        \\    var s = alloc([]int, 8)
        \\    var t = 0
        \\    t = s
        \\    t = s
        \\}
        \\
    , "use of moved value");
    try std.testing.expect(has_err);
}

test "typecheck: alloc without move is valid" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var s = alloc([]int, 8)
        \\    var t = alloc([]int, 4)
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: SIMD literal and arithmetic valid" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    let a = v4f32{ 1.0, 2.0, 3.0, 4.0 }
        \\    let b = v4f32{ 10.0, 20.0, 30.0, 40.0 }
        \\    let c = a + b
        \\    let m = c < b
        \\    let d = simd.select(m, c, b)
        \\    let s = simd.hadd(d)
        \\    let dot = simd.dot(d, b)
        \\    let width = simd.width()
        \\    let align = unsafe.alignof(v4f32)
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "typecheck: SIMD arithmetic mismatch rejected" {
    try std.testing.expect(try testTypeCheckHasErrorContaining(
        \\fn main() {
        \\    let a = v4f32{ 1.0, 2.0, 3.0, 4.0 }
        \\    let b = v8f32{ 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0 }
        \\    let c = a + b
        \\}
        \\
    , "requires matching vector operands"));
}

test "typecheck: SIMD shuffle indices must be literals" {
    try std.testing.expect(try testTypeCheckHasErrorContaining(
        \\fn main() {
        \\    let a = v4f32{ 1.0, 2.0, 3.0, 4.0 }
        \\    let i = 1
        \\    let b = simd.shuffle(a, i, 2, 3, 0)
        \\}
        \\
    , "indices must be integer literals"));
}

test "typecheck: SIMD select mask mismatch rejected" {
    try std.testing.expect(try testTypeCheckHasErrorContaining(
        \\fn main() {
        \\    let a = v4f32{ 1.0, 2.0, 3.0, 4.0 }
        \\    let b = v4f32{ 10.0, 20.0, 30.0, 40.0 }
        \\    let m = v8bool{ true, false, true, false, true, false, true, false }
        \\    let c = simd.select(m, a, b)
        \\}
        \\
    , "mask type mismatch"));
}

test "typecheck: SIMD load store with pointer-to-vector valid" {
    const result = try testTypeCheck(
        \\fn main() {
        \\    var ptr = alloc(v4f32)
        \\    let value = v4f32{ 1.0, 2.0, 3.0, 4.0 }
        \\    simd.store(ptr, value)
        \\    let roundtrip = simd.load(ptr)
        \\    let unaligned = simd.loadUnaligned(ptr)
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}
