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
const Symbol = symbol_mod.Symbol;
const SymbolId = symbol_mod.SymbolId;
const SymbolTable = symbol_mod.SymbolTable;
const DiagnosticList = @import("diagnostics.zig").DiagnosticList;

/// Result of name resolution.
pub const ResolveResult = struct {
    symbols: SymbolTable,
    /// For each AST node, the resolved SymbolId (if any).
    resolution_map: std.ArrayList(?SymbolId),
    diagnostics: DiagnosticList,

    pub fn deinit(self: *ResolveResult, allocator: std.mem.Allocator) void {
        self.symbols.deinit(allocator);
        self.resolution_map.deinit(allocator);
        self.diagnostics.deinit();
    }
};

/// Resolves names in the AST. Three passes:
/// 1. Collect top-level declarations
/// 2. Bind methods to receiver types
/// 3. Resolve bodies (identifiers, scopes, local variables)
pub const Resolver = struct {
    tree: *const Ast,
    tokens: []const Token,
    source: []const u8,
    symbols: SymbolTable,
    resolution_map: std.ArrayList(?SymbolId),
    diagnostics: DiagnosticList,
    allocator: std.mem.Allocator,
    /// Tracks whether we are inside a loop (for break/continue checks).
    loop_depth: u32,
    /// Tracks whether we are inside a function (for return checks).
    fn_depth: u32,

    pub fn init(allocator: std.mem.Allocator, tree: *const Ast, tokens: []const Token) Resolver {
        var resolution_map: std.ArrayList(?SymbolId) = .empty;
        // Pre-fill with null for every node.
        resolution_map.appendNTimes(allocator, null, tree.nodes.items.len) catch {};
        return .{
            .tree = tree,
            .tokens = tokens,
            .source = tree.source,
            .symbols = SymbolTable.init(allocator),
            .resolution_map = resolution_map,
            .diagnostics = DiagnosticList.init(allocator),
            .allocator = allocator,
            .loop_depth = 0,
            .fn_depth = 0,
        };
    }

    pub fn resolve(self: *Resolver) !ResolveResult {
        try self.pass1_collectDecls();
        try self.pass2_bindMethods();
        try self.pass3_resolveBodies();
        return .{
            .symbols = self.symbols,
            .resolution_map = self.resolution_map,
            .diagnostics = self.diagnostics,
        };
    }

    /// Get the source text for a token.
    fn tokenSlice(self: *const Resolver, tok_index: u32) []const u8 {
        const tok = self.tokens[tok_index];
        return self.source[tok.loc.start..tok.loc.end];
    }

    fn tokenLoc(self: *const Resolver, tok_index: u32) Token.Loc {
        return self.tokens[tok_index].loc;
    }

    fn nodeMainToken(self: *const Resolver, node: NodeIndex) u32 {
        return self.tree.nodes.items[node].main_token;
    }

    fn nodeTag(self: *const Resolver, node: NodeIndex) Node.Tag {
        return self.tree.nodes.items[node].tag;
    }

    fn nodeData(self: *const Resolver, node: NodeIndex) Node.Data {
        return self.tree.nodes.items[node].data;
    }

    // ── Pass 1: Collect top-level declarations ──────────────────────────────

    fn pass1_collectDecls(self: *Resolver) ResolveError!void {
        const root = self.tree.nodes.items[0];
        const start = root.data.lhs;
        const count = root.data.rhs;
        const decl_indices = self.tree.extra_data.items[start .. start + count];

        for (decl_indices) |decl_idx| {
            try self.collectTopLevelDecl(decl_idx);
        }
    }

    fn collectTopLevelDecl(self: *Resolver, node: NodeIndex) ResolveError!void {
        if (node == null_node) return;
        const tag = self.nodeTag(node);
        switch (tag) {
            .pub_decl => {
                const inner = self.nodeData(node).lhs;
                try self.collectTopLevelDeclInner(inner, true);
            },
            .inline_decl => {
                const inner = self.nodeData(node).lhs;
                try self.collectTopLevelDecl(inner);
            },
            else => try self.collectTopLevelDeclInner(node, false),
        }
    }

    fn collectTopLevelDeclInner(self: *Resolver, node: NodeIndex, is_pub: bool) ResolveError!void {
        if (node == null_node) return;
        const tag = self.nodeTag(node);
        switch (tag) {
            .fn_decl => try self.collectFnDecl(node, is_pub),
            .var_decl => try self.collectVarDecl(node, is_pub, true),
            .let_decl => try self.collectVarDecl(node, is_pub, false),
            .struct_decl => try self.collectStructDecl(node, is_pub),
            .interface_decl => try self.collectInterfaceDecl(node, is_pub),
            .type_alias => try self.collectTypeAlias(node, is_pub),
            .type_decl => try self.collectTypeDecl(node, is_pub),
            .import_decl => try self.collectImportDecl(node),
            else => {},
        }
    }

    fn collectFnDecl(self: *Resolver, node: NodeIndex, is_pub: bool) ResolveError!void {
        const fn_tok = self.nodeMainToken(node);
        const has_receiver = self.tokens[fn_tok + 1].tag == .l_paren;
        if (has_receiver) return; // methods handled in pass 2

        const name_tok = fn_tok + 1;
        const name = self.tokenSlice(name_tok);

        try self.defineSymbol(name, .{
            .name = name,
            .kind = .function,
            .type_id = types.null_type, // will be filled during type checking
            .is_pub = is_pub,
            .is_mutable = false,
            .decl_node = node,
        }, name_tok);
    }

    fn findParamCount(self: *const Resolver, params_start: u32, extra: []const NodeIndex) u32 {
        _ = self;
        // From parseParamList: extra_data = [p1, p2, ..., pN, count]
        // The count value tells us how many params preceded it.
        // Strategy: read entries, check if entry at position params_start + N equals N.
        var n: u32 = 0;
        while (params_start + n < extra.len) {
            if (extra[params_start + n] == n) {
                return n;
            }
            n += 1;
        }
        return 0;
    }

    fn collectVarDecl(self: *Resolver, node: NodeIndex, is_pub: bool, is_mutable: bool) ResolveError!void {
        const main_tok = self.nodeMainToken(node);
        // main_token = kw_var or kw_let, name is next token
        const name_tok = main_tok + 1;
        const name = self.tokenSlice(name_tok);

        try self.defineSymbol(name, .{
            .name = name,
            .kind = .variable,
            .type_id = types.null_type,
            .is_pub = is_pub,
            .is_mutable = is_mutable,
            .decl_node = node,
        }, main_tok);
    }

    fn collectImportDecl(self: *Resolver, node: NodeIndex) ResolveError!void {
        // import_decl: main_token = string literal (the import path)
        const str_tok = self.nodeMainToken(node);
        const raw = self.tokenSlice(str_tok);
        // Strip quotes: "fmt" -> fmt
        const pkg_name = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;

        // Register the package name as a symbol so references like fmt.println resolve
        _ = self.symbols.define(self.allocator, pkg_name, .{
            .name = pkg_name,
            .kind = .package,
            .type_id = types.null_type,
            .is_pub = false,
            .is_mutable = false,
            .decl_node = node,
        }) catch |err| switch (err) {
            error.DuplicateSymbol => {}, // duplicate import is fine
            else => |e| return @as(ResolveError, e),
        };
    }

    fn collectStructDecl(self: *Resolver, node: NodeIndex, is_pub: bool) ResolveError!void {
        // struct_decl: main_token = name identifier
        const name_tok = self.nodeMainToken(node);
        const name = self.tokenSlice(name_tok);

        try self.defineSymbol(name, .{
            .name = name,
            .kind = .type_def,
            .type_id = types.null_type,
            .is_pub = is_pub,
            .is_mutable = false,
            .decl_node = node,
        }, name_tok);
    }

    fn collectInterfaceDecl(self: *Resolver, node: NodeIndex, is_pub: bool) ResolveError!void {
        const main_tok = self.nodeMainToken(node);
        const name_tok = switch (self.tokens[main_tok].tag) {
            .kw_type, .kw_interface => main_tok + 1,
            else => main_tok,
        };
        const name = self.tokenSlice(name_tok);

        try self.defineSymbol(name, .{
            .name = name,
            .kind = .type_def,
            .type_id = types.null_type,
            .is_pub = is_pub,
            .is_mutable = false,
            .decl_node = node,
        }, main_tok);
    }

    fn collectTypeAlias(self: *Resolver, node: NodeIndex, is_pub: bool) ResolveError!void {
        // type_alias: main_token = kw_type, name is next token
        const main_tok = self.nodeMainToken(node);
        const name_tok = main_tok + 1;
        const name = self.tokenSlice(name_tok);

        try self.defineSymbol(name, .{
            .name = name,
            .kind = .type_def,
            .type_id = types.null_type,
            .is_pub = is_pub,
            .is_mutable = false,
            .decl_node = node,
        }, main_tok);
    }

    fn collectTypeDecl(self: *Resolver, node: NodeIndex, is_pub: bool) ResolveError!void {
        // type_decl: main_token = kw_type, name is next token
        const main_tok = self.nodeMainToken(node);
        const name_tok = main_tok + 1;
        const name = self.tokenSlice(name_tok);

        try self.defineSymbol(name, .{
            .name = name,
            .kind = .type_def,
            .type_id = types.null_type,
            .is_pub = is_pub,
            .is_mutable = false,
            .decl_node = node,
        }, main_tok);
    }

    fn defineSymbol(self: *Resolver, name: []const u8, sym: Symbol, err_tok: u32) ResolveError!void {
        _ = self.symbols.define(self.allocator, name, sym) catch |err| switch (err) {
            error.DuplicateSymbol => {
                const loc = self.tokenLoc(err_tok);
                try self.diagnostics.addErrorFmt(loc.start, loc.end, "duplicate definition of '{s}'", .{name});
                return;
            },
            else => |e| return @as(ResolveError, e),
        };
    }

    // ── Pass 2: Bind methods to receiver types ──────────────────────────────

    fn pass2_bindMethods(self: *Resolver) ResolveError!void {
        const root = self.tree.nodes.items[0];
        const start = root.data.lhs;
        const count = root.data.rhs;
        const decl_indices = self.tree.extra_data.items[start .. start + count];

        for (decl_indices) |decl_idx| {
            var node = decl_idx;
            var is_pub = false;
            if (self.nodeTag(node) == .inline_decl) {
                node = self.nodeData(node).lhs;
            }
            if (self.nodeTag(node) == .pub_decl) {
                is_pub = true;
                node = self.nodeData(node).lhs;
            }
            if (self.nodeTag(node) == .fn_decl) {
                try self.bindMethod(node, is_pub);
            }
        }
    }

    fn bindMethod(self: *Resolver, node: NodeIndex, is_pub: bool) ResolveError!void {
        const fn_tok = self.nodeMainToken(node);
        const has_receiver = self.tokens[fn_tok + 1].tag == .l_paren;
        if (!has_receiver) return;

        // Find the function name. With receiver: fn (recv Type) name(params) ...
        // We need to scan tokens past the receiver to find the name.
        // Receiver syntax: ( name [:]  type_tokens... )
        // After r_paren is the function name.
        var tok_idx = fn_tok + 2; // skip fn, l_paren
        // Skip receiver name
        if (self.tokens[tok_idx].tag == .identifier) tok_idx += 1;
        // Skip optional colon
        if (self.tokens[tok_idx].tag == .colon) tok_idx += 1;
        // Skip receiver type tokens until r_paren
        var paren_depth: u32 = 1;
        // We started after the opening paren, so depth=1
        // Actually we're already past l_paren. We need to find the matching r_paren.
        while (tok_idx < self.tokens.len and paren_depth > 0) {
            if (self.tokens[tok_idx].tag == .l_paren) paren_depth += 1;
            if (self.tokens[tok_idx].tag == .r_paren) paren_depth -= 1;
            tok_idx += 1;
        }
        // tok_idx now points to the token after r_paren, which is the function name
        const name_tok = tok_idx;
        const name = self.tokenSlice(name_tok);

        // Find the receiver type name from the receiver node.
        const data = self.nodeData(node);
        const params_start = data.lhs;
        const extra = self.tree.extra_data.items;
        const param_count = self.findParamCount(params_start, extra);
        // After params: [count, receiver_node, ret_type]
        const receiver_node = extra[params_start + param_count + 1];

        if (receiver_node == null_node) return;

        // receiver node: tag = .receiver, lhs = type node
        const recv_type_node = self.nodeData(receiver_node).lhs;
        const recv_type_name = self.resolveTypeName(recv_type_node);

        if (recv_type_name) |type_name| {
            // Look up the receiver type in the symbol table.
            if (self.symbols.lookup(type_name)) |type_sym_id| {
                const type_sym = self.symbols.getSymbol(type_sym_id);
                if (type_sym.kind == .type_def) {
                    // Define the method as a symbol.
                    const method_sym_id = self.symbols.define(self.allocator, name, .{
                        .name = name,
                        .kind = .method,
                        .type_id = types.null_type,
                        .is_pub = is_pub,
                        .is_mutable = false,
                        .decl_node = node,
                    }) catch |err| switch (err) {
                        error.DuplicateSymbol => {
                            // Methods can shadow top-level names — that's ok.
                            // But duplicate method on same type is an error.
                            const loc = self.tokenLoc(name_tok);
                            try self.diagnostics.addErrorFmt(loc.start, loc.end, "duplicate method '{s}' on type '{s}'", .{ name, type_name });
                            return;
                        },
                        else => |e| return @as(ResolveError, e),
                    };
                    try self.symbols.defineMethod(type_sym.type_id, name, method_sym_id);
                } else {
                    const loc = self.tokenLoc(name_tok);
                    try self.diagnostics.addErrorFmt(loc.start, loc.end, "receiver type '{s}' is not a type", .{type_name});
                }
            } else {
                const loc = self.tokenLoc(name_tok);
                try self.diagnostics.addErrorFmt(loc.start, loc.end, "undefined receiver type '{s}'", .{type_name});
            }
        }
    }

    /// Extract the base type name from a type node (unwrapping &T, @T, etc.)
    fn resolveTypeName(self: *const Resolver, type_node: NodeIndex) ?[]const u8 {
        if (type_node == null_node) return null;
        const tag = self.nodeTag(type_node);
        return switch (tag) {
            .type_name, .ident => self.tokenSlice(self.nodeMainToken(type_node)),
            .type_ptr, .type_const_ptr => {
                // lhs = inner type
                const inner = self.nodeData(type_node).lhs;
                return self.resolveTypeName(inner);
            },
            else => null,
        };
    }

    // ── Pass 3: Resolve bodies ──────────────────────────────────────────────

    fn pass3_resolveBodies(self: *Resolver) ResolveError!void {
        const root = self.tree.nodes.items[0];
        const start = root.data.lhs;
        const count = root.data.rhs;
        const decl_indices = self.tree.extra_data.items[start .. start + count];

        for (decl_indices) |decl_idx| {
            var node = decl_idx;
            if (self.nodeTag(node) == .inline_decl) {
                node = self.nodeData(node).lhs;
            }
            if (self.nodeTag(node) == .pub_decl) {
                node = self.nodeData(node).lhs;
            }
            if (self.nodeTag(node) == .fn_decl) {
                try self.resolveFnBody(node);
            }
        }
    }

    fn resolveFnBody(self: *Resolver, node: NodeIndex) ResolveError!void {
        const data = self.nodeData(node);
        const body = data.rhs;
        if (body == null_node) return;

        try self.symbols.pushScope(self.allocator);
        defer self.symbols.popScope(self.allocator);

        // Register params and receiver.
        const params_start = data.lhs;
        const extra = self.tree.extra_data.items;
        const param_count = self.findParamCount(params_start, extra);

        // Register receiver if present.
        const receiver_node = extra[params_start + param_count + 1];
        if (receiver_node != null_node) {
            const recv_name_tok = self.nodeMainToken(receiver_node);
            const recv_name = self.tokenSlice(recv_name_tok);
            _ = self.symbols.define(self.allocator, recv_name, .{
                .name = recv_name,
                .kind = .param,
                .type_id = types.null_type,
                .is_pub = false,
                .is_mutable = false,
                .decl_node = receiver_node,
            }) catch |err| switch (err) {
                error.DuplicateSymbol => {},
                else => |e| return @as(ResolveError, e),
            };
        }

        // Register params.
        const param_nodes = extra[params_start .. params_start + param_count];
        for (param_nodes) |param_node| {
            if (param_node == null_node) continue;
            const param_name_tok = self.nodeMainToken(param_node);
            const param_name = self.tokenSlice(param_name_tok);
            _ = self.symbols.define(self.allocator, param_name, .{
                .name = param_name,
                .kind = .param,
                .type_id = types.null_type,
                .is_pub = false,
                .is_mutable = false,
                .decl_node = param_node,
            }) catch |err| switch (err) {
                error.DuplicateSymbol => {
                    const loc = self.tokenLoc(param_name_tok);
                    try self.diagnostics.addErrorFmt(loc.start, loc.end, "duplicate parameter '{s}'", .{param_name});
                },
                else => |e| return @as(ResolveError, e),
            };
        }

        self.fn_depth += 1;
        defer self.fn_depth -= 1;

        try self.resolveBlock(body);
    }

    fn resolveBlock(self: *Resolver, node: NodeIndex) ResolveError!void {
        if (node == null_node) return;
        const data = self.nodeData(node);
        const start = data.lhs;
        const count = data.rhs;

        try self.symbols.pushScope(self.allocator);
        defer self.symbols.popScope(self.allocator);

        const stmt_indices = self.tree.extra_data.items[start .. start + count];
        for (stmt_indices) |stmt_idx| {
            try self.resolveNode(stmt_idx);
        }
    }

    const ResolveError = error{OutOfMemory};

    fn resolveNode(self: *Resolver, node: NodeIndex) ResolveError!void {
        if (node == null_node) return;
        const tag = self.nodeTag(node);
        switch (tag) {
            // Variable declarations
            .var_decl => try self.resolveVarDecl(node, true),
            .let_decl => try self.resolveVarDecl(node, false),
            .short_var_decl => try self.resolveShortVarDecl(node),

            // Statements
            .return_stmt => try self.resolveReturn(node),
            .expr_stmt => try self.resolveNode(self.nodeData(node).lhs),
            .defer_stmt => try self.resolveNode(self.nodeData(node).lhs),
            .run_stmt => try self.resolveNode(self.nodeData(node).lhs),
            .block => try self.resolveBlock(node),
            .if_stmt => try self.resolveIfStmt(node),
            .if_expr => try self.resolveIfExpr(node),
            .for_stmt => try self.resolveForStmt(node),
            .switch_stmt => try self.resolveSwitchStmt(node),
            .assign => try self.resolveAssign(node),
            .chan_send => {
                try self.resolveNode(self.nodeData(node).lhs);
                try self.resolveNode(self.nodeData(node).rhs);
            },

            // Control flow
            .break_stmt => {
                if (self.loop_depth == 0) {
                    const loc = self.tokenLoc(self.nodeMainToken(node));
                    try self.diagnostics.addError(loc.start, loc.end, "'break' outside of loop");
                }
            },
            .continue_stmt => {
                if (self.loop_depth == 0) {
                    const loc = self.tokenLoc(self.nodeMainToken(node));
                    try self.diagnostics.addError(loc.start, loc.end, "'continue' outside of loop");
                }
            },

            // Expressions
            .ident => try self.resolveIdent(node),
            .binary_op => {
                try self.resolveNode(self.nodeData(node).lhs);
                try self.resolveNode(self.nodeData(node).rhs);
            },
            .unary_op => try self.resolveNode(self.nodeData(node).lhs),
            .call => try self.resolveCall(node),
            .field_access => try self.resolveNode(self.nodeData(node).lhs),
            .index_access => {
                try self.resolveNode(self.nodeData(node).lhs);
                try self.resolveNode(self.nodeData(node).rhs);
            },
            .addr_of, .addr_of_const, .deref, .chan_recv => {
                try self.resolveNode(self.nodeData(node).lhs);
            },
            .try_expr => {
                try self.resolveNode(self.nodeData(node).lhs);
                // rhs is context string (literal, no resolution needed)
            },
            .range => {
                try self.resolveNode(self.nodeData(node).lhs);
                try self.resolveNode(self.nodeData(node).rhs);
            },
            .struct_literal => try self.resolveStructLiteral(node),
            .simd_literal => try self.resolveSimdLiteral(node),
            .array_literal => {
                const data = self.nodeData(node);
                const extra = self.tree.extra_data.items;
                const elem_count = self.findTrailingCount(data.rhs, extra);
                const elem_nodes = extra[data.rhs .. data.rhs + elem_count];
                for (elem_nodes) |elem_node| {
                    try self.resolveNode(elem_node);
                }
            },
            .tuple_literal => {
                const data = self.nodeData(node);
                const extra = self.tree.extra_data.items;
                const elem_count = self.findTrailingCount(data.rhs, extra);
                const elem_nodes = extra[data.rhs .. data.rhs + elem_count];
                for (elem_nodes) |elem_node| {
                    try self.resolveNode(elem_node);
                }
            },
            .anon_struct_literal => try self.resolveAnonStructLiteral(node),
            .struct_field_init => try self.resolveNode(self.nodeData(node).lhs),
            .closure => try self.resolveClosure(node),
            .alloc_expr => try self.resolveAllocExpr(node),

            // Literals don't need resolution
            .int_literal, .float_literal, .string_literal, .bool_literal, .null_literal => {},

            // Type nodes don't need resolution in this pass
            .type_name,
            .type_ptr,
            .type_const_ptr,
            .type_nullable,
            .type_error_union,
            .type_slice,
            .type_chan,
            .type_map,
            .type_fn,
            .type_tuple,
            .type_array,
            .type_anon_struct,
            => {},

            // Variants
            .variant => try self.resolveNode(self.nodeData(node).lhs),

            // Assembly expressions — resolve input expressions
            .asm_expr => {
                const data = self.nodeData(node);
                const extra = self.tree.extra_data.items;
                const input_count = extra[data.lhs];
                var i: u32 = 0;
                while (i < input_count) : (i += 1) {
                    const input_node = extra[data.lhs + 1 + i];
                    // Resolve the expression in the asm_input
                    const input_data = self.nodeData(input_node);
                    try self.resolveNode(input_data.lhs);
                }
            },

            // These are handled by their parent or contain no resolvable names
            .asm_input, .asm_body, .asm_simple_body, .asm_platform => {},

            // These are handled by their parent
            .fn_decl,
            .pub_decl,
            .inline_decl,
            .struct_decl,
            .interface_decl,
            .type_alias,
            .type_decl,
            .package_decl,
            .import_decl,
            .field_decl,
            .method_sig,
            .param,
            .variadic_param,
            .receiver,
            .switch_arm,
            .root,
            => {},
        }
    }

    fn resolveVarDecl(self: *Resolver, node: NodeIndex, is_mutable: bool) ResolveError!void {
        const data = self.nodeData(node);
        const main_tok = self.nodeMainToken(node);
        const name_tok = main_tok + 1;
        const name = self.tokenSlice(name_tok);

        // Resolve initializer first (before defining the var, so it can't reference itself).
        if (data.rhs != null_node) {
            try self.resolveNode(data.rhs);
        }

        const sym_id = self.symbols.define(self.allocator, name, .{
            .name = name,
            .kind = .variable,
            .type_id = types.null_type,
            .is_pub = false,
            .is_mutable = is_mutable,
            .decl_node = node,
        }) catch |err| switch (err) {
            error.DuplicateSymbol => {
                const loc = self.tokenLoc(name_tok);
                try self.diagnostics.addErrorFmt(loc.start, loc.end, "duplicate definition of '{s}'", .{name});
                return;
            },
            else => |e| return @as(ResolveError, e),
        };

        self.resolution_map.items[node] = sym_id;
    }

    fn resolveShortVarDecl(self: *Resolver, node: NodeIndex) ResolveError!void {
        const data = self.nodeData(node);

        // Resolve RHS first.
        try self.resolveNode(data.rhs);

        // LHS is an ident expression node representing the variable name.
        const lhs_node = data.lhs;
        if (lhs_node != null_node and self.nodeTag(lhs_node) == .ident) {
            const name_tok = self.nodeMainToken(lhs_node);
            const name = self.tokenSlice(name_tok);

            const sym_id = self.symbols.define(self.allocator, name, .{
                .name = name,
                .kind = .variable,
                .type_id = types.null_type,
                .is_pub = false,
                .is_mutable = true,
                .decl_node = node,
            }) catch |err| switch (err) {
                error.DuplicateSymbol => {
                    const loc = self.tokenLoc(name_tok);
                    try self.diagnostics.addErrorFmt(loc.start, loc.end, "duplicate definition of '{s}'", .{name});
                    return;
                },
                else => |e| return @as(ResolveError, e),
            };

            self.resolution_map.items[lhs_node] = sym_id;
            self.resolution_map.items[node] = sym_id;
        }
    }

    fn resolveReturn(self: *Resolver, node: NodeIndex) ResolveError!void {
        if (self.fn_depth == 0) {
            const loc = self.tokenLoc(self.nodeMainToken(node));
            try self.diagnostics.addError(loc.start, loc.end, "'return' outside of function");
        }
        const data = self.nodeData(node);
        if (data.lhs != null_node) {
            try self.resolveNode(data.lhs);
        }
    }

    fn resolveIdent(self: *Resolver, node: NodeIndex) ResolveError!void {
        const name_tok = self.nodeMainToken(node);
        const name = self.tokenSlice(name_tok);

        // Skip if it's a primitive type name used as ident (e.g., in type position).
        if (types.TypePool.lookupPrimitive(name) != null) return;
        // Compiler-recognized pseudo-packages.
        if (std.mem.eql(u8, name, "simd") or std.mem.eql(u8, name, "unsafe") or std.mem.eql(u8, name, "close")) return;

        if (self.symbols.lookup(name)) |sym_id| {
            self.resolution_map.items[node] = sym_id;
        } else {
            const loc = self.tokenLoc(name_tok);
            try self.diagnostics.addErrorFmt(loc.start, loc.end, "undefined reference to '{s}'", .{name});
        }
    }

    fn resolveCall(self: *Resolver, node: NodeIndex) ResolveError!void {
        const data = self.nodeData(node);
        // Resolve callee.
        try self.resolveNode(data.lhs);

        // Resolve arguments.
        const args_start = data.rhs;
        const extra = self.tree.extra_data.items;
        // Args layout: [arg1, ..., argN, count]
        // We need to find count. Scan forward.
        const arg_count = self.findTrailingCount(args_start, extra);
        const arg_nodes = extra[args_start .. args_start + arg_count];
        for (arg_nodes) |arg| {
            try self.resolveNode(arg);
        }
    }

    fn resolveSimdLiteral(self: *Resolver, node: NodeIndex) ResolveError!void {
        const data = self.nodeData(node);
        const extra = self.tree.extra_data.items;
        const lane_count = self.findTrailingCount(data.rhs, extra);
        const lane_nodes = extra[data.rhs .. data.rhs + lane_count];
        for (lane_nodes) |lane_node| {
            try self.resolveNode(lane_node);
        }
    }

    /// Find a trailing count value in extra_data.
    /// Layout: [item1, ..., itemN, count] where count == N.
    fn findTrailingCount(self: *const Resolver, start: u32, extra: []const NodeIndex) u32 {
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

    fn resolveStructLiteral(self: *Resolver, node: NodeIndex) ResolveError!void {
        const data = self.nodeData(node);
        // Resolve type name.
        try self.resolveNode(data.lhs);
        // Resolve field initializers.
        const fields_start = data.rhs;
        const extra = self.tree.extra_data.items;
        const field_count = self.findTrailingCount(fields_start, extra);
        const field_nodes = extra[fields_start .. fields_start + field_count];
        for (field_nodes) |field| {
            try self.resolveNode(field);
        }
    }

    fn resolveAnonStructLiteral(self: *Resolver, node: NodeIndex) ResolveError!void {
        const data = self.nodeData(node);
        const fields_start = data.rhs;
        const extra = self.tree.extra_data.items;
        const field_count = self.findTrailingCount(fields_start, extra);
        const field_nodes = extra[fields_start .. fields_start + field_count];
        for (field_nodes) |field| {
            try self.resolveNode(field);
        }
    }

    fn resolveAssign(self: *Resolver, node: NodeIndex) ResolveError!void {
        const data = self.nodeData(node);
        try self.resolveNode(data.lhs);
        try self.resolveNode(data.rhs);

        // Check: if LHS resolves to a let-bound variable, error on reassignment.
        if (data.lhs != null_node and self.nodeTag(data.lhs) == .ident) {
            if (self.resolution_map.items[data.lhs]) |sym_id| {
                const sym = self.symbols.getSymbol(sym_id);
                if (!sym.is_mutable and sym.kind == .variable) {
                    const loc = self.tokenLoc(self.nodeMainToken(data.lhs));
                    try self.diagnostics.addErrorFmt(loc.start, loc.end, "cannot assign to immutable variable '{s}'", .{sym.name});
                }
            }
        }
    }

    fn resolveIfStmt(self: *Resolver, node: NodeIndex) ResolveError!void {
        const data = self.nodeData(node);
        const extra = self.tree.extra_data.items;
        try self.resolveNode(data.lhs); // condition

        // rhs = extra_data start, layout: [then_block, else_node]
        const then_block = extra[data.rhs];
        const else_node = extra[data.rhs + 1];

        try self.resolveBlock(then_block);
        if (else_node != null_node) {
            if (self.nodeTag(else_node) == .if_stmt) {
                try self.resolveIfStmt(else_node);
            } else {
                try self.resolveBlock(else_node);
            }
        }
    }

    fn resolveIfExpr(self: *Resolver, node: NodeIndex) ResolveError!void {
        const data = self.nodeData(node);
        const extra = self.tree.extra_data.items;
        try self.resolveNode(data.lhs); // condition

        // rhs = extra_data start, layout: [then_expr, else_expr]
        const then_expr = extra[data.rhs];
        const else_expr = extra[data.rhs + 1];

        try self.resolveNode(then_expr);
        try self.resolveNode(else_expr);
    }

    fn resolveForStmt(self: *Resolver, node: NodeIndex) ResolveError!void {
        const data = self.nodeData(node);
        const main_tok = self.nodeMainToken(node);

        self.loop_depth += 1;
        defer self.loop_depth -= 1;

        // Detect for-in: `for item in collection { body }`
        // Check tokens: main_tok = kw_for, main_tok+1 might be identifier, main_tok+2 might be kw_in
        const is_for_in = (main_tok + 2 < self.tokens.len and
            self.tokens[main_tok + 1].tag == .identifier and
            self.tokens[main_tok + 2].tag == .kw_in);

        if (is_for_in) {
            // Resolve the iterable expression first.
            try self.resolveNode(data.lhs);

            // Then create scope for body and register iteration variable.
            try self.symbols.pushScope(self.allocator);
            defer self.symbols.popScope(self.allocator);

            const iter_var_tok = main_tok + 1;
            const iter_var_name = self.tokenSlice(iter_var_tok);
            _ = self.symbols.define(self.allocator, iter_var_name, .{
                .name = iter_var_name,
                .kind = .variable,
                .type_id = types.null_type,
                .is_pub = false,
                .is_mutable = false, // for-in variables are immutable
                .decl_node = node,
            }) catch |err| switch (err) {
                error.DuplicateSymbol => {},
                else => |e| return @as(ResolveError, e),
            };

            // Resolve body. Since we already pushed a scope, resolve the block's
            // statements directly (without the block pushing another scope).
            if (data.rhs != null_node) {
                const block_data = self.nodeData(data.rhs);
                const start = block_data.lhs;
                const count = block_data.rhs;
                const stmts = self.tree.extra_data.items[start .. start + count];
                for (stmts) |stmt| {
                    try self.resolveNode(stmt);
                }
            }
        } else if (data.lhs == null_node) {
            // Infinite loop: `for { body }`
            if (data.rhs != null_node) {
                try self.resolveBlock(data.rhs);
            }
        } else {
            // `for condition { body }`
            try self.resolveNode(data.lhs);
            if (data.rhs != null_node) {
                try self.resolveBlock(data.rhs);
            }
        }
    }

    fn resolveSwitchStmt(self: *Resolver, node: NodeIndex) ResolveError!void {
        const data = self.nodeData(node);
        try self.resolveNode(data.lhs); // switch expression

        // Arms: extra_data[rhs..] = [arm1, ..., armN, count]
        const arms_start = data.rhs;
        const extra = self.tree.extra_data.items;
        const arm_count = self.findTrailingCount(arms_start, extra);
        const arm_nodes = extra[arms_start .. arms_start + arm_count];
        for (arm_nodes) |arm| {
            try self.resolveSwitchArm(arm);
        }
    }

    fn resolveSwitchArm(self: *Resolver, node: NodeIndex) ResolveError!void {
        if (node == null_node) return;
        const data = self.nodeData(node);

        // Create a scope for this arm so pattern-bound variables are visible in the body.
        try self.symbols.pushScope(self.allocator);
        defer self.symbols.popScope(self.allocator);

        // Resolve the pattern, binding payload variables instead of resolving them as idents.
        self.resolvePattern(data.lhs);

        // Body can be a block or an expression.
        if (data.rhs != null_node) {
            if (self.nodeTag(data.rhs) == .block) {
                try self.resolveBlock(data.rhs);
            } else {
                try self.resolveNode(data.rhs);
            }
        }
    }

    /// Resolve a switch arm pattern, binding payload identifiers as variables
    /// instead of trying to look them up in scope.
    fn resolvePattern(self: *Resolver, node: NodeIndex) void {
        if (node == null_node) return;
        const tag = self.nodeTag(node);
        switch (tag) {
            .variant => {
                // .name or .name(payload) — bind payload if present.
                const payload = self.nodeData(node).lhs;
                if (payload != null_node and self.nodeTag(payload) == .ident) {
                    const name_tok = self.nodeMainToken(payload);
                    const name = self.tokenSlice(name_tok);
                    // Skip wildcard `_`.
                    if (!std.mem.eql(u8, name, "_")) {
                        const sym_id = self.symbols.define(self.allocator, name, .{
                            .name = name,
                            .kind = .variable,
                            .type_id = types.null_type,
                            .is_pub = false,
                            .is_mutable = false,
                            .decl_node = payload,
                        }) catch |err| switch (err) {
                            error.DuplicateSymbol => return,
                            else => return,
                        };
                        self.resolution_map.items[payload] = sym_id;
                    }
                }
            },
            // Other patterns (ident wildcards, literals, null) need no binding.
            else => {},
        }
    }

    fn resolveClosure(self: *Resolver, node: NodeIndex) ResolveError!void {
        const data = self.nodeData(node);
        const body = data.rhs;
        if (body == null_node) return;

        try self.symbols.pushScope(self.allocator);
        defer self.symbols.popScope(self.allocator);

        // Register closure params.
        const params_start = data.lhs;
        const extra = self.tree.extra_data.items;
        const param_count = self.findParamCount(params_start, extra);

        const param_nodes = extra[params_start .. params_start + param_count];
        for (param_nodes) |param_node| {
            if (param_node == null_node) continue;
            const param_name_tok = self.nodeMainToken(param_node);
            const param_name = self.tokenSlice(param_name_tok);
            _ = self.symbols.define(self.allocator, param_name, .{
                .name = param_name,
                .kind = .param,
                .type_id = types.null_type,
                .is_pub = false,
                .is_mutable = false,
                .decl_node = param_node,
            }) catch |err| switch (err) {
                error.DuplicateSymbol => {
                    const loc = self.tokenLoc(param_name_tok);
                    try self.diagnostics.addErrorFmt(loc.start, loc.end, "duplicate parameter '{s}'", .{param_name});
                },
                else => |e| return @as(ResolveError, e),
            };
        }

        self.fn_depth += 1;
        defer self.fn_depth -= 1;

        try self.resolveBlock(body);
    }

    fn resolveAllocExpr(self: *Resolver, node: NodeIndex) ResolveError!void {
        const data = self.nodeData(node);
        // lhs = type node (skip for resolution)
        // rhs = extra_data start: [capacity_expr_or_null, allocator_expr_or_null]
        const extra_start = data.rhs;
        const extra = self.tree.extra_data.items;
        if (extra_start < extra.len) {
            const cap = extra[extra_start];
            if (cap != null_node) try self.resolveNode(cap);
            if (extra_start + 1 < extra.len) {
                const alloc_expr = extra[extra_start + 1];
                if (alloc_expr != null_node) try self.resolveNode(alloc_expr);
            }
        }
    }
};

/// Run name resolution on an AST.
pub fn resolveNames(allocator: std.mem.Allocator, tree: *const Ast, tokens: []const Token) !ResolveResult {
    var resolver = Resolver.init(allocator, tree, tokens);
    return resolver.resolve();
}

// ── Tests ───────────────────────────────────────────────────────────────────────

const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;

fn testResolveBasic(source: []const u8) !struct { has_errors: bool, error_count: usize } {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(source);
    var token_list = try lexer.tokenize(allocator);
    defer token_list.deinit(allocator);

    const toks = token_list.items;

    var parser = Parser.init(allocator, toks, source);
    defer parser.deinit();
    _ = try parser.parseFile();

    // Run resolution
    var result = try resolveNames(allocator, &parser.tree, toks);
    defer result.deinit(allocator);

    return .{
        .has_errors = result.diagnostics.hasErrors(),
        .error_count = result.diagnostics.diagnostics.items.len,
    };
}

test "resolve: simple function definition" {
    const result = try testResolveBasic("fn main() {\n}\n");
    try std.testing.expect(!result.has_errors);
}

test "resolve: variable declaration and use" {
    const result = try testResolveBasic(
        \\fn main() {
        \\    var x int = 42
        \\    return x
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "resolve: undefined variable" {
    const result = try testResolveBasic(
        \\fn main() {
        \\    return y
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "resolve: duplicate top-level definition" {
    const result = try testResolveBasic(
        \\fn foo() {
        \\}
        \\fn foo() {
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "resolve: break outside loop" {
    const result = try testResolveBasic(
        \\fn main() {
        \\    break
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "resolve: break inside loop" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main() {
        \\    for true {
        \\        break
        \\    }
        \\}
        \\
    ;
    var lexer = Lexer.init(source);
    var token_list = try lexer.tokenize(allocator);
    defer token_list.deinit(allocator);
    var parser = Parser.init(allocator, token_list.items, source);
    defer parser.deinit();
    _ = try parser.parseFile();
    var result = try resolveNames(allocator, &parser.tree, token_list.items);
    defer result.deinit(allocator);

    if (result.diagnostics.hasErrors()) {
        for (result.diagnostics.diagnostics.items) |d| {
            std.debug.print("  diag: {s}\n", .{d.message});
        }
    }
    try std.testing.expect(!result.diagnostics.hasErrors());
}

test "resolve: continue outside loop" {
    const result = try testResolveBasic(
        \\fn main() {
        \\    continue
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "resolve: let reassignment" {
    const result = try testResolveBasic(
        \\fn main() {
        \\    let x int = 1
        \\    x = 2
        \\}
        \\
    );
    try std.testing.expect(result.has_errors);
}

test "resolve: var reassignment is ok" {
    const result = try testResolveBasic(
        \\fn main() {
        \\    var x int = 1
        \\    x = 2
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "resolve: function params are in scope" {
    const result = try testResolveBasic(
        \\fn add(a int, b int) int {
        \\    return a
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "resolve: short var decl" {
    const result = try testResolveBasic(
        \\fn main() {
        \\    x := 42
        \\    return x
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "resolve: forward reference to function" {
    const result = try testResolveBasic(
        \\fn main() {
        \\    foo()
        \\}
        \\fn foo() {
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "resolve: struct declaration" {
    const result = try testResolveBasic(
        \\Point struct {
        \\    x int
        \\    y int
        \\}
        \\fn main() {
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}

test "resolve: return outside function" {
    // return at top level is caught. But our parser only allows fn_decl at top level,
    // so return would be inside a fn. This test would require a special structure.
    // Let's skip this edge case for now — the parser doesn't allow top-level return.
    // Instead test that return inside fn is fine.
    const result = try testResolveBasic(
        \\fn main() {
        \\    return 42
        \\}
        \\
    );
    try std.testing.expect(!result.has_errors);
}
