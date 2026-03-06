const std = @import("std");
const Token = @import("token.zig").Token;
const Tag = Token.Tag;
const Lexer = @import("lexer.zig").Lexer;
const ast = @import("ast.zig");
const Ast = ast.Ast;
const Node = ast.Node;
const NodeIndex = ast.NodeIndex;
const null_node = ast.null_node;

pub const Parser = struct {
    tokens: []const Token,
    pos: u32,
    source: []const u8,
    tree: Ast,
    allow_struct_literals: bool,

    pub const Error = error{OutOfMemory};

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token, source: []const u8) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .source = source,
            .tree = Ast.init(allocator, source),
            .allow_struct_literals = true,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.tree.deinit();
    }

    /// Parse the full source file into a list of top-level declaration node indices.
    pub fn parseFile(self: *Parser) ![]const NodeIndex {
        var decls: std.ArrayList(NodeIndex) = .empty;
        defer decls.deinit(self.tree.allocator);

        self.skipNewlines();

        while (!self.isAtEnd()) {
            if (self.peekTag() == .newline) {
                self.advance();
                continue;
            }
            const decl = try self.parseTopLevel();
            if (decl != null_node) {
                try decls.append(self.tree.allocator, decl);
            }
        }

        // Store all top-level declarations in extra_data
        const start: u32 = @intCast(self.tree.extra_data.items.len);
        for (decls.items) |d| {
            _ = try self.tree.addExtra(d);
        }
        const count: u32 = @intCast(decls.items.len);

        // Update the root node
        self.tree.nodes.items[0] = .{
            .tag = .root,
            .main_token = 0,
            .data = .{ .lhs = start, .rhs = count },
        };

        return self.tree.extra_data.items[start .. start + count];
    }

    // --- Top-level parsing ---

    fn parseTopLevel(self: *Parser) Error!NodeIndex {
        return switch (self.peekTag()) {
            .kw_pub => self.parsePubDecl(),
            .kw_fn => self.parseFnDecl(),
            .kw_interface => self.parseInterfaceDecl(),
            .kw_type => self.parseTypeAlias(),
            .kw_import => self.parseImportDecl(),
            .kw_var => self.parseVarDecl(),
            .kw_let => self.parseLetDecl(),
            .identifier => if (self.peekTagAt(1) == .kw_struct) self.parseStructDecl() else {
                try self.addError(.expected_expression, self.currentLoc(), null);
                self.advance();
                return null_node;
            },
            else => {
                try self.addError(.expected_expression, self.currentLoc(), null);
                self.advance();
                return null_node;
            },
        };
    }

    fn parsePubDecl(self: *Parser) Error!NodeIndex {
        const pub_tok = self.pos;
        self.expect(.kw_pub);

        const inner = switch (self.peekTag()) {
            .kw_fn => try self.parseFnDecl(),
            .kw_interface => try self.parseInterfaceDecl(),
            .kw_type => try self.parseTypeAlias(),
            .kw_var => try self.parseVarDecl(),
            .kw_let => try self.parseLetDecl(),
            .identifier => if (self.peekTagAt(1) == .kw_struct) try self.parseStructDecl() else blk: {
                try self.addError(.expected_expression, self.currentLoc(), null);
                break :blk null_node;
            },
            else => blk: {
                try self.addError(.expected_expression, self.currentLoc(), null);
                break :blk null_node;
            },
        };

        return self.tree.addNode(.{
            .tag = .pub_decl,
            .main_token = pub_tok,
            .data = .{ .lhs = inner, .rhs = null_node },
        });
    }

    fn parseFnDecl(self: *Parser) Error!NodeIndex {
        const fn_tok = self.pos;
        self.expect(.kw_fn);

        // Check for method receiver: fn (p: &Type) name(...)
        var receiver_node: NodeIndex = null_node;
        if (self.peekTag() == .l_paren) {
            receiver_node = try self.parseReceiver();
        }

        // Function name
        if (self.peekTag() != .identifier) {
            try self.addError(.expected_identifier, self.currentLoc(), null);
            return null_node;
        }
        self.advance(); // consume name

        // Parameters
        const params_start = try self.parseParamList();

        // Reserve extra_data slots for receiver and return type immediately
        // after the param list so the layout is always:
        //   [param1, ..., paramN, count, receiver_node, ret_type]
        // Parsing the return type or body could append to extra_data,
        // so we reserve now and patch later to keep the layout contiguous.
        const receiver_slot = try self.tree.addExtra(null_node);
        const ret_type_slot = try self.tree.addExtra(null_node);

        // Return type (optional - if next token starts a type, parse it)
        var ret_type: NodeIndex = null_node;
        if (self.isTypeStart()) {
            ret_type = try self.parseType();
        }

        self.skipNewlines();

        // Body
        var body: NodeIndex = null_node;
        if (self.peekTag() == .l_brace) {
            body = try self.parseBlock();
        }

        // Patch the reserved slots
        self.tree.extra_data.items[receiver_slot] = receiver_node;
        self.tree.extra_data.items[ret_type_slot] = ret_type;

        return self.tree.addNode(.{
            .tag = .fn_decl,
            .main_token = fn_tok,
            .data = .{ .lhs = params_start, .rhs = body },
        });
    }

    fn parseReceiver(self: *Parser) Error!NodeIndex {
        self.expect(.l_paren);

        // receiver name
        if (self.peekTag() != .identifier) {
            try self.addError(.expected_identifier, self.currentLoc(), null);
            return null_node;
        }
        const tok = self.pos; // points to receiver name identifier
        self.advance(); // consume name

        // Optional colon between name and type
        if (self.peekTag() == .colon) self.advance();

        // receiver type
        const type_node = try self.parseType();

        self.expectToken(.r_paren);

        return self.tree.addNode(.{
            .tag = .receiver,
            .main_token = tok,
            .data = .{ .lhs = type_node, .rhs = null_node },
        });
    }

    fn parseParamList(self: *Parser) Error!u32 {
        self.expectToken(.l_paren);

        // Collect params first — parseParam calls parseType which could
        // trigger type_anon_struct, adding to extra_data.
        var params: std.ArrayList(NodeIndex) = .empty;
        defer params.deinit(self.tree.allocator);

        while (self.peekTag() != .r_paren and !self.isAtEnd()) {
            if (params.items.len > 0) {
                self.expectToken(.comma);
            }
            const param = try self.parseParam();
            try params.append(self.tree.allocator, param);
        }
        self.expectToken(.r_paren);

        const start: u32 = @intCast(self.tree.extra_data.items.len);
        for (params.items) |p| {
            _ = try self.tree.addExtra(p);
        }
        _ = try self.tree.addExtra(@as(NodeIndex, @intCast(params.items.len)));
        return start;
    }

    fn parseParam(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        if (self.peekTag() != .identifier) {
            try self.addError(.expected_identifier, self.currentLoc(), null);
            return null_node;
        }
        self.advance(); // param name
        // Optional colon between name and type
        if (self.peekTag() == .colon) self.advance();
        const type_node = try self.parseType();
        return self.tree.addNode(.{
            .tag = .param,
            .main_token = tok,
            .data = .{ .lhs = type_node, .rhs = null_node },
        });
    }

    fn parseStructDecl(self: *Parser) Error!NodeIndex {
        // Name struct { ... }
        const tok = self.pos; // points to the name identifier
        if (self.peekTag() != .identifier) {
            try self.addError(.expected_identifier, self.currentLoc(), null);
            return null_node;
        }
        self.advance(); // consume name
        self.expect(.kw_struct);

        self.skipNewlines();
        self.expectToken(.l_brace);
        self.skipNewlines();

        const start: u32 = @intCast(self.tree.extra_data.items.len);

        // Parse optional implements block
        var implements_count: u32 = 0;
        // Reserve slot for implements_count
        const count_slot = try self.tree.addExtra(0);
        if (self.peekTag() == .kw_implements) {
            self.advance(); // consume 'implements'
            self.skipNewlines();
            self.expectToken(.l_paren);
            self.skipNewlines();

            while (self.peekTag() != .r_paren and !self.isAtEnd()) {
                self.skipNewlines();
                if (self.peekTag() == .r_paren) break;

                if (self.peekTag() != .identifier) {
                    try self.addError(.expected_identifier, self.currentLoc(), null);
                    break;
                }
                const iface_node = try self.tree.addNode(.{
                    .tag = .ident,
                    .main_token = self.pos,
                    .data = .{ .lhs = null_node, .rhs = null_node },
                });
                self.advance();
                _ = try self.tree.addExtra(iface_node);
                implements_count += 1;

                self.skipNewlines();
                if (self.peekTag() == .comma) self.advance();
                self.skipNewlines();
            }
            self.expectToken(.r_paren);
            self.skipNewlines();
        }
        // Patch the implements count
        self.tree.extra_data.items[count_slot] = implements_count;

        // Collect fields first — parseFieldDecl can call parseExpr for default
        // values, which may recursively add to extra_data.
        var field_nodes: std.ArrayList(NodeIndex) = .empty;
        defer field_nodes.deinit(self.tree.allocator);

        while (self.peekTag() != .r_brace and !self.isAtEnd()) {
            self.skipNewlines();
            if (self.peekTag() == .r_brace) break;

            const field = try self.parseFieldDecl();
            try field_nodes.append(self.tree.allocator, field);

            self.skipNewlines();
            // Optional comma between fields
            if (self.peekTag() == .comma) self.advance();
            self.skipNewlines();
        }
        self.expectToken(.r_brace);

        for (field_nodes.items) |f| {
            _ = try self.tree.addExtra(f);
        }

        return self.tree.addNode(.{
            .tag = .struct_decl,
            .main_token = tok,
            .data = .{ .lhs = start, .rhs = @as(NodeIndex, @intCast(field_nodes.items.len)) },
        });
    }

    fn parseFieldDecl(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        if (self.peekTag() != .identifier) {
            try self.addError(.expected_identifier, self.currentLoc(), null);
            return null_node;
        }
        self.advance(); // field name
        // Optional colon between name and type
        if (self.peekTag() == .colon) self.advance();
        const type_node = try self.parseType();

        // Optional default value
        var default_val: NodeIndex = null_node;
        if (self.peekTag() == .equal) {
            self.advance();
            default_val = try self.parseExpr();
        }

        return self.tree.addNode(.{
            .tag = .field_decl,
            .main_token = tok,
            .data = .{ .lhs = type_node, .rhs = default_val },
        });
    }

    fn parseInterfaceDecl(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expect(.kw_interface);

        if (self.peekTag() != .identifier) {
            try self.addError(.expected_identifier, self.currentLoc(), null);
            return null_node;
        }
        self.advance();

        self.skipNewlines();
        self.expectToken(.l_brace);
        self.skipNewlines();

        // Collect method sigs first — parseMethodSig calls parseParamList
        // which appends to extra_data.
        var methods: std.ArrayList(NodeIndex) = .empty;
        defer methods.deinit(self.tree.allocator);

        while (self.peekTag() != .r_brace and !self.isAtEnd()) {
            self.skipNewlines();
            if (self.peekTag() == .r_brace) break;
            const method = try self.parseMethodSig();
            try methods.append(self.tree.allocator, method);
            self.skipNewlines();
        }
        self.expectToken(.r_brace);

        const start: u32 = @intCast(self.tree.extra_data.items.len);
        for (methods.items) |m| {
            _ = try self.tree.addExtra(m);
        }

        return self.tree.addNode(.{
            .tag = .interface_decl,
            .main_token = tok,
            .data = .{ .lhs = start, .rhs = @as(NodeIndex, @intCast(methods.items.len)) },
        });
    }

    /// Parse a bare method signature: `name(params) ret_type`
    fn parseMethodSig(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        if (self.peekTag() != .identifier) {
            try self.addError(.expected_identifier, self.currentLoc(), null);
            return null_node;
        }
        self.advance(); // consume method name

        // Parameters
        const params_start = try self.parseParamList();

        // Return type (optional)
        var ret_type: NodeIndex = null_node;
        if (self.isTypeStart()) {
            ret_type = try self.parseType();
        }

        // Store return type in extra data
        _ = try self.tree.addExtra(ret_type);

        return self.tree.addNode(.{
            .tag = .method_sig,
            .main_token = tok,
            .data = .{ .lhs = params_start, .rhs = null_node },
        });
    }

    fn parseTypeAlias(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expect(.kw_type);

        if (self.peekTag() != .identifier) {
            try self.addError(.expected_identifier, self.currentLoc(), null);
            return null_node;
        }
        self.advance(); // type name

        // Disambiguate: `type Name = .variants` (sum type) vs `type Name <type>` (type decl)
        if (self.peekTag() == .equal) {
            self.advance(); // consume '='

            // Parse sum type variants: .loading | .ready(Data) | .error(string)
            var variants: std.ArrayList(NodeIndex) = .empty;
            defer variants.deinit(self.tree.allocator);

            const first_variant = try self.parseVariantDef();
            try variants.append(self.tree.allocator, first_variant);

            while (self.peekTag() == .pipe) {
                self.advance();
                const v = try self.parseVariantDef();
                try variants.append(self.tree.allocator, v);
            }

            const start: u32 = @intCast(self.tree.extra_data.items.len);
            for (variants.items) |vv| {
                _ = try self.tree.addExtra(vv);
            }
            const count: u32 = @intCast(variants.items.len);

            return self.tree.addNode(.{
                .tag = .type_alias,
                .main_token = tok,
                .data = .{ .lhs = start, .rhs = count },
            });
        }

        // Simple type declaration: `type Name <type>`
        if (!self.isTypeStart()) {
            try self.addError(.expected_type, self.currentLoc(), null);
            return null_node;
        }
        const type_node = try self.parseType();

        return self.tree.addNode(.{
            .tag = .type_decl,
            .main_token = tok,
            .data = .{ .lhs = type_node, .rhs = null_node },
        });
    }

    fn parseVariantDef(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expectToken(.dot);
        if (self.peekTag() != .identifier) {
            try self.addError(.expected_identifier, self.currentLoc(), null);
            return null_node;
        }
        self.advance(); // variant name

        var data_type: NodeIndex = null_node;
        if (self.peekTag() == .l_paren) {
            self.advance();
            data_type = try self.parseType();
            self.expectToken(.r_paren);
        }

        return self.tree.addNode(.{
            .tag = .variant,
            .main_token = tok,
            .data = .{ .lhs = data_type, .rhs = null_node },
        });
    }

    fn parseImportDecl(self: *Parser) Error!NodeIndex {
        _ = self.pos; // skip import keyword position
        self.expect(.kw_import);

        if (self.peekTag() != .string_literal) {
            try self.addError(.expected_expression, self.currentLoc(), null);
            return null_node;
        }
        const str_tok = self.pos;
        self.advance();

        return self.tree.addNode(.{
            .tag = .import_decl,
            .main_token = str_tok,
            .data = .{ .lhs = null_node, .rhs = null_node },
        });
    }

    fn parseVarDecl(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expect(.kw_var);

        if (self.peekTag() != .identifier) {
            try self.addError(.expected_identifier, self.currentLoc(), null);
            return null_node;
        }
        self.advance();

        // Optional type
        var type_node: NodeIndex = null_node;
        if (self.isTypeStart()) {
            type_node = try self.parseType();
        }

        // Optional initializer
        var init_expr: NodeIndex = null_node;
        if (self.peekTag() == .equal) {
            self.advance();
            init_expr = try self.parseExpr();
        }

        return self.tree.addNode(.{
            .tag = .var_decl,
            .main_token = tok,
            .data = .{ .lhs = type_node, .rhs = init_expr },
        });
    }

    fn parseLetDecl(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expect(.kw_let);

        if (self.peekTag() != .identifier) {
            try self.addError(.expected_identifier, self.currentLoc(), null);
            return null_node;
        }
        self.advance();

        // Optional type
        var type_node: NodeIndex = null_node;
        if (self.isTypeStart()) {
            type_node = try self.parseType();
        }

        // Required initializer — immutable variables must be initialized
        self.expectToken(.equal);
        const init_expr = try self.parseExpr();

        return self.tree.addNode(.{
            .tag = .let_decl,
            .main_token = tok,
            .data = .{ .lhs = type_node, .rhs = init_expr },
        });
    }

    // --- Statements ---

    fn parseStmt(self: *Parser) Error!NodeIndex {
        return switch (self.peekTag()) {
            .kw_return => self.parseReturn(),
            .kw_defer => self.parseDefer(),
            .kw_break => self.parseBreak(),
            .kw_continue => self.parseContinue(),
            .kw_if => self.parseIf(),
            .kw_for => self.parseFor(),
            .kw_switch => self.parseSwitch(),
            .kw_var => self.parseVarDecl(),
            .kw_let => self.parseLetDecl(),
            .kw_run => self.parseRun(),
            else => self.parseExprOrAssign(),
        };
    }

    fn parseReturn(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expect(.kw_return);
        var expr: NodeIndex = null_node;
        if (self.peekTag() != .newline and self.peekTag() != .r_brace and !self.isAtEnd()) {
            expr = try self.parseExpr();
        }
        return self.tree.addNode(.{
            .tag = .return_stmt,
            .main_token = tok,
            .data = .{ .lhs = expr, .rhs = null_node },
        });
    }

    fn parseDefer(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expect(.kw_defer);
        const expr = try self.parseExpr();
        return self.tree.addNode(.{
            .tag = .defer_stmt,
            .main_token = tok,
            .data = .{ .lhs = expr, .rhs = null_node },
        });
    }

    fn parseBreak(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expect(.kw_break);
        return self.tree.addNode(.{
            .tag = .break_stmt,
            .main_token = tok,
            .data = .{ .lhs = null_node, .rhs = null_node },
        });
    }

    fn parseContinue(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expect(.kw_continue);
        return self.tree.addNode(.{
            .tag = .continue_stmt,
            .main_token = tok,
            .data = .{ .lhs = null_node, .rhs = null_node },
        });
    }

    fn parseRun(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expect(.kw_run);
        const expr = try self.parseExpr();
        return self.tree.addNode(.{
            .tag = .run_stmt,
            .main_token = tok,
            .data = .{ .lhs = expr, .rhs = null_node },
        });
    }

    fn parseIf(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expect(.kw_if);
        const condition = try self.parseExpr();

        // Ternary form: if cond :: then_expr else else_expr
        if (self.peekTag() == .colon_colon) {
            return self.parseIfExprRest(tok, condition);
        }

        self.skipNewlines();
        const then_block = try self.parseBlock();

        var else_node: NodeIndex = null_node;
        self.skipNewlines();
        if (self.peekTag() == .kw_else) {
            self.advance();
            self.skipNewlines();
            if (self.peekTag() == .kw_if) {
                else_node = try self.parseIf();
            } else {
                else_node = try self.parseBlock();
            }
        }

        // Store then and else in extra_data so both are retrievable
        const start: u32 = @intCast(self.tree.extra_data.items.len);
        _ = try self.tree.addExtra(then_block);
        _ = try self.tree.addExtra(else_node);

        return self.tree.addNode(.{
            .tag = .if_stmt,
            .main_token = tok,
            .data = .{ .lhs = condition, .rhs = start },
        });
    }

    /// Parse the rest of a ternary if-expression after condition has been parsed.
    /// Expects `::` as the current token.
    fn parseIfExprRest(self: *Parser, tok: u32, condition: NodeIndex) Error!NodeIndex {
        self.expectToken(.colon_colon);
        const then_expr = try self.parseExpr();
        self.expectToken(.kw_else);
        const else_expr = try self.parseExpr();

        // Store then and else in extra_data so both are retrievable
        const start: u32 = @intCast(self.tree.extra_data.items.len);
        _ = try self.tree.addExtra(then_expr);
        _ = try self.tree.addExtra(else_expr);

        return self.tree.addNode(.{
            .tag = .if_expr,
            .main_token = tok,
            .data = .{ .lhs = condition, .rhs = start },
        });
    }

    fn parseFor(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expect(.kw_for);

        self.skipNewlines();

        // `for { }` — infinite loop
        if (self.peekTag() == .l_brace) {
            const body = try self.parseBlock();
            return self.tree.addNode(.{
                .tag = .for_stmt,
                .main_token = tok,
                .data = .{ .lhs = null_node, .rhs = body },
            });
        }

        // Parse first expression — could be condition or iterator variable
        const first = try self.parseExpr();

        // Check for `in` keyword: `for item in collection { }`
        if (self.peekTag() == .kw_in) {
            self.advance();
            const prev_allow_struct_literals = self.allow_struct_literals;
            self.allow_struct_literals = false;
            defer self.allow_struct_literals = prev_allow_struct_literals;
            const iterable = try self.parseExpr();
            // Store the iteration variable (first) and iterable in extra data
            _ = try self.tree.addExtra(first);
            self.skipNewlines();
            const body = try self.parseBlock();
            return self.tree.addNode(.{
                .tag = .for_stmt,
                .main_token = tok,
                .data = .{ .lhs = iterable, .rhs = body },
            });
        }

        // `for condition { body }`
        self.skipNewlines();
        const body = try self.parseBlock();
        return self.tree.addNode(.{
            .tag = .for_stmt,
            .main_token = tok,
            .data = .{ .lhs = first, .rhs = body },
        });
    }

    fn parseSwitch(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expect(.kw_switch);
        const subject = try self.parseExpr();
        self.skipNewlines();
        self.expectToken(.l_brace);
        self.skipNewlines();

        // Collect arms first — parseSwitchArm can call parseBlock/parseExpr
        // which append to extra_data, so we batch-append afterwards.
        var arms: std.ArrayList(NodeIndex) = .empty;
        defer arms.deinit(self.tree.allocator);

        while (self.peekTag() != .r_brace and !self.isAtEnd()) {
            self.skipNewlines();
            if (self.peekTag() == .r_brace) break;
            const arm = try self.parseSwitchArm();
            try arms.append(self.tree.allocator, arm);
            self.skipNewlines();
            if (self.peekTag() == .comma) self.advance();
            self.skipNewlines();
        }
        self.expectToken(.r_brace);

        const start: u32 = @intCast(self.tree.extra_data.items.len);
        for (arms.items) |a| {
            _ = try self.tree.addExtra(a);
        }
        _ = try self.tree.addExtra(@as(NodeIndex, @intCast(arms.items.len)));

        return self.tree.addNode(.{
            .tag = .switch_stmt,
            .main_token = tok,
            .data = .{ .lhs = subject, .rhs = start },
        });
    }

    fn parseSwitchArm(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        const pattern = try self.parseExpr();
        self.expectToken(.colon_colon);
        self.skipNewlines();

        var body: NodeIndex = null_node;
        if (self.peekTag() == .l_brace) {
            body = try self.parseBlock();
        } else {
            body = try self.parseExpr();
        }

        return self.tree.addNode(.{
            .tag = .switch_arm,
            .main_token = tok,
            .data = .{ .lhs = pattern, .rhs = body },
        });
    }

    fn parseExprOrAssign(self: *Parser) Error!NodeIndex {
        const lhs = try self.parseExpr();

        // Short variable declaration: `name := expr`
        if (self.peekTag() == .colon_equal) {
            const tok = self.pos;
            self.advance();
            const rhs = try self.parseExpr();
            return self.tree.addNode(.{
                .tag = .short_var_decl,
                .main_token = tok,
                .data = .{ .lhs = lhs, .rhs = rhs },
            });
        }

        // Assignment: `lhs = rhs`
        if (self.peekTag() == .equal) {
            const tok = self.pos;
            self.advance();
            const rhs = try self.parseExpr();
            return self.tree.addNode(.{
                .tag = .assign,
                .main_token = tok,
                .data = .{ .lhs = lhs, .rhs = rhs },
            });
        }

        // Channel send: `ch <- val`
        if (self.peekTag() == .arrow_left) {
            const tok = self.pos;
            self.advance();
            const val = try self.parseExpr();
            return self.tree.addNode(.{
                .tag = .chan_send,
                .main_token = tok,
                .data = .{ .lhs = lhs, .rhs = val },
            });
        }

        // Expression statement
        return self.tree.addNode(.{
            .tag = .expr_stmt,
            .main_token = self.pos,
            .data = .{ .lhs = lhs, .rhs = null_node },
        });
    }

    fn parseBlock(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expectToken(.l_brace);
        self.skipNewlines();

        // Collect statements in a local list first, then batch-append to
        // extra_data.  Appending inline would interleave with extra_data
        // written by nested blocks/calls inside the statements, corrupting
        // the contiguous index range this block expects.
        var stmts: std.ArrayList(NodeIndex) = .empty;
        defer stmts.deinit(self.tree.allocator);

        while (self.peekTag() != .r_brace and !self.isAtEnd()) {
            self.skipNewlines();
            if (self.peekTag() == .r_brace) break;
            const stmt = try self.parseStmt();
            if (stmt != null_node) {
                try stmts.append(self.tree.allocator, stmt);
            }
            self.skipNewlines();
        }
        self.expectToken(.r_brace);

        const start: u32 = @intCast(self.tree.extra_data.items.len);
        for (stmts.items) |s| {
            _ = try self.tree.addExtra(s);
        }
        const count: u32 = @intCast(stmts.items.len);

        return self.tree.addNode(.{
            .tag = .block,
            .main_token = tok,
            .data = .{ .lhs = start, .rhs = count },
        });
    }

    // --- Expressions (precedence climbing) ---

    fn parseExpr(self: *Parser) Error!NodeIndex {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) Error!NodeIndex {
        var lhs = try self.parseAnd();
        while (self.peekTag() == .kw_or) {
            const tok = self.pos;
            self.advance();
            const rhs = try self.parseAnd();
            lhs = try self.tree.addNode(.{
                .tag = .binary_op,
                .main_token = tok,
                .data = .{ .lhs = lhs, .rhs = rhs },
            });
        }
        return lhs;
    }

    fn parseAnd(self: *Parser) Error!NodeIndex {
        var lhs = try self.parseComparison();
        while (self.peekTag() == .kw_and) {
            const tok = self.pos;
            self.advance();
            const rhs = try self.parseComparison();
            lhs = try self.tree.addNode(.{
                .tag = .binary_op,
                .main_token = tok,
                .data = .{ .lhs = lhs, .rhs = rhs },
            });
        }
        return lhs;
    }

    fn parseComparison(self: *Parser) Error!NodeIndex {
        var lhs = try self.parseRange();
        while (self.peekTag() == .equal_equal or
            self.peekTag() == .bang_equal or
            self.peekTag() == .less or
            self.peekTag() == .greater or
            self.peekTag() == .less_equal or
            self.peekTag() == .greater_equal)
        {
            const tok = self.pos;
            self.advance();
            const rhs = try self.parseRange();
            lhs = try self.tree.addNode(.{
                .tag = .binary_op,
                .main_token = tok,
                .data = .{ .lhs = lhs, .rhs = rhs },
            });
        }
        return lhs;
    }

    fn parseRange(self: *Parser) Error!NodeIndex {
        var lhs = try self.parseAddSub();
        if (self.peekTag() == .dot_dot) {
            const tok = self.pos;
            self.advance();
            const rhs = try self.parseAddSub();
            lhs = try self.tree.addNode(.{
                .tag = .range,
                .main_token = tok,
                .data = .{ .lhs = lhs, .rhs = rhs },
            });
        }
        return lhs;
    }

    fn parseAddSub(self: *Parser) Error!NodeIndex {
        var lhs = try self.parseMulDiv();
        while (self.peekTag() == .plus or self.peekTag() == .minus) {
            const tok = self.pos;
            self.advance();
            const rhs = try self.parseMulDiv();
            lhs = try self.tree.addNode(.{
                .tag = .binary_op,
                .main_token = tok,
                .data = .{ .lhs = lhs, .rhs = rhs },
            });
        }
        return lhs;
    }

    fn parseMulDiv(self: *Parser) Error!NodeIndex {
        var lhs = try self.parseUnary();
        while (self.peekTag() == .star or self.peekTag() == .slash or self.peekTag() == .percent) {
            const tok = self.pos;
            self.advance();
            const rhs = try self.parseUnary();
            lhs = try self.tree.addNode(.{
                .tag = .binary_op,
                .main_token = tok,
                .data = .{ .lhs = lhs, .rhs = rhs },
            });
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) Error!NodeIndex {
        if (self.peekTag() == .minus or self.peekTag() == .bang or self.peekTag() == .kw_not) {
            const tok = self.pos;
            self.advance();
            const operand = try self.parseUnary();
            return self.tree.addNode(.{
                .tag = .unary_op,
                .main_token = tok,
                .data = .{ .lhs = operand, .rhs = null_node },
            });
        }
        if (self.peekTag() == .ampersand) {
            const tok = self.pos;
            self.advance();
            const operand = try self.parseUnary();
            return self.tree.addNode(.{
                .tag = .addr_of,
                .main_token = tok,
                .data = .{ .lhs = operand, .rhs = null_node },
            });
        }
        if (self.peekTag() == .at) {
            const tok = self.pos;
            self.advance();
            const operand = try self.parseUnary();
            return self.tree.addNode(.{
                .tag = .addr_of_const,
                .main_token = tok,
                .data = .{ .lhs = operand, .rhs = null_node },
            });
        }
        if (self.peekTag() == .arrow_left) {
            const tok = self.pos;
            self.advance();
            const operand = try self.parseUnary();
            return self.tree.addNode(.{
                .tag = .chan_recv,
                .main_token = tok,
                .data = .{ .lhs = operand, .rhs = null_node },
            });
        }
        if (self.peekTag() == .kw_try) {
            const tok = self.pos;
            self.advance();
            const operand = try self.parseUnary();
            var context_node: NodeIndex = null_node;
            if (self.peekTag() == .colon_colon) {
                self.advance();
                if (self.peekTag() == .string_literal) {
                    context_node = try self.tree.addNode(.{
                        .tag = .string_literal,
                        .main_token = self.pos,
                        .data = .{ .lhs = null_node, .rhs = null_node },
                    });
                    self.advance();
                } else {
                    try self.addError(.expected_string_literal, self.currentLoc(), null);
                }
            }
            return self.tree.addNode(.{
                .tag = .try_expr,
                .main_token = tok,
                .data = .{ .lhs = operand, .rhs = context_node },
            });
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) Error!NodeIndex {
        var node = try self.parsePrimary();

        while (true) {
            switch (self.peekTag()) {
                .l_paren => {
                    // Function call
                    node = try self.parseCall(node);
                },
                .dot => {
                    // Field access
                    const tok = self.pos;
                    self.advance();
                    if (self.peekTag() != .identifier) {
                        try self.addError(.expected_identifier, self.currentLoc(), null);
                        return node;
                    }
                    self.advance();
                    node = try self.tree.addNode(.{
                        .tag = .field_access,
                        .main_token = tok,
                        .data = .{ .lhs = node, .rhs = null_node },
                    });
                },
                .l_brace => {
                    // Struct literal: Type{ field: val, ... }
                    // Only valid after an identifier (type name) or field access
                    const node_tag = self.tree.nodes.items[node].tag;
                    if (self.allow_struct_literals and (node_tag == .ident or node_tag == .field_access)) {
                        node = try self.parseStructLiteral(node);
                    } else {
                        break;
                    }
                },
                .l_bracket => {
                    // Index access
                    const tok = self.pos;
                    self.advance();
                    const index = try self.parseExpr();
                    self.expectToken(.r_bracket);
                    node = try self.tree.addNode(.{
                        .tag = .index_access,
                        .main_token = tok,
                        .data = .{ .lhs = node, .rhs = index },
                    });
                },
                .question => {
                    // Nullable postfix (in type position)
                    // Skip for now in expression context
                    break;
                },
                else => break,
            }
        }
        return node;
    }

    fn parseCall(self: *Parser, callee: NodeIndex) Error!NodeIndex {
        const tok = self.pos;
        self.expectToken(.l_paren);

        // Collect args first — arg expressions can contain nested calls
        // that would interleave extra_data.
        var args: std.ArrayList(NodeIndex) = .empty;
        defer args.deinit(self.tree.allocator);

        while (self.peekTag() != .r_paren and !self.isAtEnd()) {
            if (args.items.len > 0) self.expectToken(.comma);
            const arg = try self.parseExpr();
            try args.append(self.tree.allocator, arg);
        }
        self.expectToken(.r_paren);

        const start: u32 = @intCast(self.tree.extra_data.items.len);
        for (args.items) |a| {
            _ = try self.tree.addExtra(a);
        }
        _ = try self.tree.addExtra(@as(NodeIndex, @intCast(args.items.len)));

        return self.tree.addNode(.{
            .tag = .call,
            .main_token = tok,
            .data = .{ .lhs = callee, .rhs = start },
        });
    }

    fn parseStructLiteral(self: *Parser, type_node: NodeIndex) Error!NodeIndex {
        const tok = self.pos;
        self.expectToken(.l_brace);
        self.skipNewlines();

        // Collect field inits first — field values can be calls/nested
        // expressions that append to extra_data.
        var fields: std.ArrayList(NodeIndex) = .empty;
        defer fields.deinit(self.tree.allocator);

        while (self.peekTag() != .r_brace and !self.isAtEnd()) {
            self.skipNewlines();
            if (self.peekTag() == .r_brace) break;

            if (fields.items.len > 0) {
                self.expectToken(.comma);
                self.skipNewlines();
            }

            // field_name: value
            const field_tok = self.pos;
            if (self.peekTag() != .identifier) {
                try self.addError(.expected_identifier, self.currentLoc(), null);
                break;
            }
            self.advance();
            self.expectToken(.colon);
            const val = try self.parseExpr();

            const field_init = try self.tree.addNode(.{
                .tag = .struct_field_init,
                .main_token = field_tok,
                .data = .{ .lhs = val, .rhs = null_node },
            });
            try fields.append(self.tree.allocator, field_init);
            self.skipNewlines();
        }
        self.expectToken(.r_brace);

        const start: u32 = @intCast(self.tree.extra_data.items.len);
        for (fields.items) |f| {
            _ = try self.tree.addExtra(f);
        }
        _ = try self.tree.addExtra(@as(NodeIndex, @intCast(fields.items.len)));

        return self.tree.addNode(.{
            .tag = .struct_literal,
            .main_token = tok,
            .data = .{ .lhs = type_node, .rhs = start },
        });
    }

    fn parseAnonStructLiteral(self: *Parser, dot_tok: u32) Error!NodeIndex {
        self.expectToken(.l_brace);
        self.skipNewlines();

        var fields: std.ArrayList(NodeIndex) = .empty;
        defer fields.deinit(self.tree.allocator);

        while (self.peekTag() != .r_brace and !self.isAtEnd()) {
            self.skipNewlines();
            if (self.peekTag() == .r_brace) break;

            if (fields.items.len > 0) {
                self.expectToken(.comma);
                self.skipNewlines();
            }

            // field_name: value
            const field_tok = self.pos;
            if (self.peekTag() != .identifier) {
                try self.addError(.expected_identifier, self.currentLoc(), null);
                break;
            }
            self.advance();
            self.expectToken(.colon);
            const val = try self.parseExpr();

            const field_init = try self.tree.addNode(.{
                .tag = .struct_field_init,
                .main_token = field_tok,
                .data = .{ .lhs = val, .rhs = null_node },
            });
            try fields.append(self.tree.allocator, field_init);
            self.skipNewlines();
        }
        self.expectToken(.r_brace);

        const start: u32 = @intCast(self.tree.extra_data.items.len);
        for (fields.items) |f| {
            _ = try self.tree.addExtra(f);
        }
        _ = try self.tree.addExtra(@as(NodeIndex, @intCast(fields.items.len)));

        return self.tree.addNode(.{
            .tag = .anon_struct_literal,
            .main_token = dot_tok,
            .data = .{ .lhs = null_node, .rhs = start },
        });
    }

    fn parseAllocExpr(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expect(.kw_alloc);
        self.expectToken(.l_paren);

        const alloc_type = try self.parseType();
        if (!self.isAllocType(alloc_type)) {
            try self.addError(.invalid_alloc_type, self.currentLoc(), null);
        }

        var capacity: NodeIndex = null_node;
        var allocator_expr: NodeIndex = null_node;

        if (self.peekTag() == .comma) {
            self.advance();

            if (self.isAllocatorArgStart()) {
                allocator_expr = try self.parseAllocatorArg();
            } else {
                capacity = try self.parseExpr();

                if (self.peekTag() == .comma) {
                    self.advance();
                    if (self.isAllocatorArgStart()) {
                        allocator_expr = try self.parseAllocatorArg();
                    } else {
                        // Third alloc argument must be named for readability:
                        // alloc([]int, 64, allocator: mem.arena)
                        try self.addError(.expected_identifier, self.currentLoc(), null);
                        _ = try self.parseExpr();
                    }
                }
            }
        }

        self.expectToken(.r_paren);

        const extra_start: u32 = @intCast(self.tree.extra_data.items.len);
        _ = try self.tree.addExtra(capacity);
        _ = try self.tree.addExtra(allocator_expr);

        return self.tree.addNode(.{
            .tag = .alloc_expr,
            .main_token = tok,
            .data = .{ .lhs = alloc_type, .rhs = extra_start },
        });
    }

    fn isAllocatorArgStart(self: *const Parser) bool {
        if (self.peekTag() != .identifier) return false;
        if (self.peekTagAt(1) != .colon) return false;

        const name = self.tokens[self.pos].slice(self.source);
        return std.mem.eql(u8, name, "allocator");
    }

    fn parseAllocatorArg(self: *Parser) Error!NodeIndex {
        if (!self.isAllocatorArgStart()) {
            try self.addError(.expected_identifier, self.currentLoc(), null);
            return null_node;
        }

        self.advance(); // allocator
        self.expectToken(.colon);
        return self.parseExpr();
    }

    fn parsePrimary(self: *Parser) Error!NodeIndex {
        return switch (self.peekTag()) {
            .int_literal => {
                const tok = self.pos;
                self.advance();
                return self.tree.addNode(.{
                    .tag = .int_literal,
                    .main_token = tok,
                    .data = .{ .lhs = null_node, .rhs = null_node },
                });
            },
            .float_literal => {
                const tok = self.pos;
                self.advance();
                return self.tree.addNode(.{
                    .tag = .float_literal,
                    .main_token = tok,
                    .data = .{ .lhs = null_node, .rhs = null_node },
                });
            },
            .string_literal => {
                const tok = self.pos;
                self.advance();
                return self.tree.addNode(.{
                    .tag = .string_literal,
                    .main_token = tok,
                    .data = .{ .lhs = null_node, .rhs = null_node },
                });
            },
            .kw_true, .kw_false => {
                const tok = self.pos;
                self.advance();
                return self.tree.addNode(.{
                    .tag = .bool_literal,
                    .main_token = tok,
                    .data = .{ .lhs = null_node, .rhs = null_node },
                });
            },
            .kw_null => {
                const tok = self.pos;
                self.advance();
                return self.tree.addNode(.{
                    .tag = .null_literal,
                    .main_token = tok,
                    .data = .{ .lhs = null_node, .rhs = null_node },
                });
            },
            .identifier => {
                const tok = self.pos;
                self.advance();
                return self.tree.addNode(.{
                    .tag = .ident,
                    .main_token = tok,
                    .data = .{ .lhs = null_node, .rhs = null_node },
                });
            },
            .dot => {
                const tok = self.pos;
                self.advance();

                // Anonymous struct literal: .{ field: val, ... }
                if (self.peekTag() == .l_brace) {
                    return self.parseAnonStructLiteral(tok);
                }

                // Variant literal: .loading, .ready(data)
                if (self.peekTag() != .identifier) {
                    try self.addError(.expected_identifier, self.currentLoc(), null);
                    return null_node;
                }
                self.advance();

                var data: NodeIndex = null_node;
                if (self.peekTag() == .l_paren) {
                    self.advance();
                    data = try self.parseExpr();
                    self.expectToken(.r_paren);
                }

                return self.tree.addNode(.{
                    .tag = .variant,
                    .main_token = tok,
                    .data = .{ .lhs = data, .rhs = null_node },
                });
            },
            .l_paren => {
                // Grouped expression
                self.advance();
                const expr = try self.parseExpr();
                self.expectToken(.r_paren);
                return expr;
            },
            .kw_if => {
                // Ternary if-expression: if cond :: then_expr else else_expr
                const tok = self.pos;
                self.expect(.kw_if);
                const condition = try self.parseExpr();
                return self.parseIfExprRest(tok, condition);
            },
            .kw_fn => {
                // Closure: fn(params) ret { body }
                return self.parseClosure();
            },
            .kw_alloc => {
                return self.parseAllocExpr();
            },
            .eof => {
                try self.addError(.unexpected_eof, self.currentLoc(), null);
                return null_node;
            },
            else => {
                try self.addError(.expected_expression, self.currentLoc(), null);
                self.advance();
                return null_node;
            },
        };
    }

    fn parseClosure(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expect(.kw_fn);
        const params_start = try self.parseParamList();

        var ret_type: NodeIndex = null_node;
        if (self.isTypeStart()) {
            ret_type = try self.parseType();
        }

        self.skipNewlines();
        const body = try self.parseBlock();
        _ = try self.tree.addExtra(ret_type);

        return self.tree.addNode(.{
            .tag = .closure,
            .main_token = tok,
            .data = .{ .lhs = params_start, .rhs = body },
        });
    }

    // --- Types ---

    fn parseType(self: *Parser) Error!NodeIndex {
        // Error union: !T
        if (self.peekTag() == .bang) {
            const tok = self.pos;
            self.advance();
            const inner = try self.parseType();
            return self.tree.addNode(.{
                .tag = .type_error_union,
                .main_token = tok,
                .data = .{ .lhs = inner, .rhs = null_node },
            });
        }

        // Pointer: &T
        if (self.peekTag() == .ampersand) {
            const tok = self.pos;
            self.advance();
            const inner = try self.parseType();
            return self.tree.addNode(.{
                .tag = .type_ptr,
                .main_token = tok,
                .data = .{ .lhs = inner, .rhs = null_node },
            });
        }

        // Const pointer: @T
        if (self.peekTag() == .at) {
            const tok = self.pos;
            self.advance();
            const inner = try self.parseType();
            return self.tree.addNode(.{
                .tag = .type_const_ptr,
                .main_token = tok,
                .data = .{ .lhs = inner, .rhs = null_node },
            });
        }

        // Slice: []T
        if (self.peekTag() == .l_bracket) {
            const tok = self.pos;
            self.advance();
            self.expectToken(.r_bracket);
            const inner = try self.parseType();
            return self.tree.addNode(.{
                .tag = .type_slice,
                .main_token = tok,
                .data = .{ .lhs = inner, .rhs = null_node },
            });
        }

        // Channel: chan T or chan[T]
        if (self.peekTag() == .kw_chan) {
            const tok = self.pos;
            self.advance();

            var inner: NodeIndex = null_node;
            if (self.peekTag() == .l_bracket) {
                self.advance();
                inner = try self.parseType();
                self.expectToken(.r_bracket);
            } else {
                inner = try self.parseType();
            }

            return self.tree.addNode(.{
                .tag = .type_chan,
                .main_token = tok,
                .data = .{ .lhs = inner, .rhs = null_node },
            });
        }

        // Map: map[K]V
        if (self.peekTag() == .kw_map) {
            const tok = self.pos;
            self.advance();
            self.expectToken(.l_bracket);
            const key_type = try self.parseType();
            self.expectToken(.r_bracket);
            const value_type = try self.parseType();

            const extra_start: u32 = @intCast(self.tree.extra_data.items.len);
            _ = try self.tree.addExtra(key_type);
            _ = try self.tree.addExtra(value_type);

            return self.tree.addNode(.{
                .tag = .type_map,
                .main_token = tok,
                .data = .{ .lhs = extra_start, .rhs = null_node },
            });
        }

        // Anonymous struct type: struct { field1 type1, field2 type2 }
        if (self.peekTag() == .kw_struct) {
            const tok = self.pos;
            self.advance(); // consume 'struct'
            self.skipNewlines();
            self.expectToken(.l_brace);
            self.skipNewlines();

            var field_nodes: std.ArrayList(NodeIndex) = .empty;
            defer field_nodes.deinit(self.tree.allocator);

            while (self.peekTag() != .r_brace and !self.isAtEnd()) {
                self.skipNewlines();
                if (self.peekTag() == .r_brace) break;

                const field = try self.parseFieldDecl();
                try field_nodes.append(self.tree.allocator, field);

                self.skipNewlines();
                if (self.peekTag() == .comma) self.advance();
                self.skipNewlines();
            }
            self.expectToken(.r_brace);

            const start: u32 = @intCast(self.tree.extra_data.items.len);
            for (field_nodes.items) |f| {
                _ = try self.tree.addExtra(f);
            }

            return self.tree.addNode(.{
                .tag = .type_anon_struct,
                .main_token = tok,
                .data = .{ .lhs = start, .rhs = @as(NodeIndex, @intCast(field_nodes.items.len)) },
            });
        }

        // Named type: int, string, MyStruct, etc.
        if (self.peekTag() == .identifier) {
            const tok = self.pos;
            self.advance();
            var node = try self.tree.addNode(.{
                .tag = .type_name,
                .main_token = tok,
                .data = .{ .lhs = null_node, .rhs = null_node },
            });

            // Nullable postfix: T?
            if (self.peekTag() == .question) {
                const q_tok = self.pos;
                self.advance();
                node = try self.tree.addNode(.{
                    .tag = .type_nullable,
                    .main_token = q_tok,
                    .data = .{ .lhs = node, .rhs = null_node },
                });
            }

            return node;
        }

        try self.addError(.expected_type, self.currentLoc(), null);
        return null_node;
    }

    fn isAllocType(self: *const Parser, node: NodeIndex) bool {
        if (node == null_node) return false;
        const tag = self.tree.nodes.items[node].tag;
        return tag == .type_slice or tag == .type_map or tag == .type_chan;
    }

    fn isTypeStart(self: *const Parser) bool {
        const tag = self.peekTag();
        return tag == .identifier or tag == .ampersand or tag == .at or
            tag == .bang or tag == .l_bracket or tag == .kw_chan or tag == .kw_map or tag == .kw_struct;
    }

    // --- Helpers ---

    fn peekTag(self: *const Parser) Tag {
        if (self.pos >= self.tokens.len) return .eof;
        return self.tokens[self.pos].tag;
    }

    fn peekTagAt(self: *const Parser, offset: u32) Tag {
        const idx = self.pos + offset;
        if (idx >= self.tokens.len) return .eof;
        return self.tokens[idx].tag;
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.tokens.len) {
            self.pos += 1;
        }
    }

    fn expect(self: *Parser, tag: Tag) void {
        if (self.peekTag() == tag) {
            self.advance();
        }
    }

    fn expectToken(self: *Parser, tag: Tag) void {
        if (self.peekTag() == tag) {
            self.advance();
        } else {
            self.addError(.expected_token, self.currentLoc(), tag) catch {};
        }
    }

    fn currentLoc(self: *const Parser) Token.Loc {
        if (self.pos >= self.tokens.len) {
            return .{ .start = @intCast(self.source.len), .end = @intCast(self.source.len) };
        }
        return self.tokens[self.pos].loc;
    }

    fn isAtEnd(self: *const Parser) bool {
        return self.pos >= self.tokens.len or self.tokens[self.pos].tag == .eof;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.peekTag() == .newline) {
            self.advance();
        }
    }

    fn addError(self: *Parser, tag: Ast.ErrorTag, loc: Token.Loc, expected: ?Tag) !void {
        try self.tree.errors.append(self.tree.allocator, .{
            .tag = tag,
            .loc = loc,
            .expected = expected,
        });
    }
};

// --- Tests ---

test "parse var declaration" {
    const source = "var x int = 42";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_var = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .var_decl) {
            found_var = true;
            break;
        }
    }
    try std.testing.expect(found_var);
}

test "parse var declaration without init" {
    const source = "var x int";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);
}

test "parse let declaration" {
    const source = "let x int = 42";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_let = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .let_decl) {
            found_let = true;
            break;
        }
    }
    try std.testing.expect(found_let);
}

test "parse let declaration without type" {
    const source = "let x = 42";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);
}

test "parse short variable declaration" {
    const source = "fn main() {\n    x := 42\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);
}

test "parse var and let in function body" {
    const source = "fn main() {\n    var x int = 0\n    let y int = 42\n    x = 10\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);
}

test "parse function definition" {
    const source = "pub fn add(a int, b int) int {\n    return a + b\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);
}

test "parse struct" {
    const source = "Point struct {\n    x f64,\n    y f64\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);
}

test "parse pub struct" {
    const source = "pub Rectangle struct {\n    x int\n    y int\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);
}

test "parse struct with implements" {
    const source = "pub Rectangle struct {\n    implements (\n        Figure,\n    )\n\n    x int\n    y int\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    // Verify a struct_decl node was created
    var found_struct = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .struct_decl) {
            found_struct = true;
            break;
        }
    }
    try std.testing.expect(found_struct);
}

test "parse struct with implements and colons" {
    const source = "pub Point struct {\n    implements (\n        Stringer,\n        Writer,\n    )\n\n    x: f64\n    y: f64\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_struct = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .struct_decl) {
            found_struct = true;
            break;
        }
    }
    try std.testing.expect(found_struct);
}

test "parse interface" {
    const source = "pub interface Stringer {\n    string() string\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    // Verify an interface_decl and method_sig node were created
    var found_interface = false;
    var found_method_sig = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .interface_decl) found_interface = true;
        if (node.tag == .method_sig) found_method_sig = true;
    }
    try std.testing.expect(found_interface);
    try std.testing.expect(found_method_sig);
}

test "parse interface with multiple methods" {
    const source = "interface ReadWriter {\n    read(buf: []byte) !int\n    write(buf: []byte) !int\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var method_sig_count: u32 = 0;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .method_sig) method_sig_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), method_sig_count);
}

test "parse sum type" {
    const source = "type State = .loading | .ready(Data) | .error(string)";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);
}

test "parse method with receiver" {
    const source = "fn (p &Point) distance(other @Point) f64 {\n    return 0.0\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);
}

test "parse method with receiver using colons" {
    const source = "fn (self: @Point) string() string {\n    return \"point\"\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);
}

test "parse fun keyword as alias for fn" {
    const source = "pub fun main() {\n    return\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_fn = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .fn_decl) {
            found_fn = true;
            break;
        }
    }
    try std.testing.expect(found_fn);
}

test "parse ternary if expression in assignment" {
    const source = "fn main() {\n    x := if a < b :: 1 else 2\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    // Verify an if_expr node was created
    var found_if_expr = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .if_expr) {
            found_if_expr = true;
            break;
        }
    }
    try std.testing.expect(found_if_expr);
}

test "parse ternary if expression as statement" {
    const source = "fn main() {\n    if x > 0 :: foo() else bar()\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);
}

test "parse nested ternary if expression" {
    const source = "fn main() {\n    x := if a :: if b :: 1 else 2 else 3\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);
}

test "parse for-in string iteration (default characters)" {
    const source = "fn main() {\n    for ch in s {\n        foo(ch)\n    }\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    // Verify a for_stmt node was created
    var found_for = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .for_stmt) {
            found_for = true;
            break;
        }
    }
    try std.testing.expect(found_for);
}

test "parse for-in string.bytes iteration" {
    const source = "fn main() {\n    for b in s.bytes {\n        foo(b)\n    }\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    // Verify for_stmt and field_access nodes were created
    var found_for = false;
    var found_field_access = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .for_stmt) found_for = true;
        if (node.tag == .field_access) found_field_access = true;
    }
    try std.testing.expect(found_for);
    try std.testing.expect(found_field_access);
}

test "parse function returning anonymous struct" {
    const source = "fn divmod(a int, b int) struct { quotient int, remainder int } {\n    return .{ quotient: a / b, remainder: a % b }\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_fn = false;
    var found_anon_struct_type = false;
    var found_anon_struct_literal = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .fn_decl) found_fn = true;
        if (node.tag == .type_anon_struct) found_anon_struct_type = true;
        if (node.tag == .anon_struct_literal) found_anon_struct_literal = true;
    }
    try std.testing.expect(found_fn);
    try std.testing.expect(found_anon_struct_type);
    try std.testing.expect(found_anon_struct_literal);
}

test "parse anonymous struct literal" {
    const source = "fn main() {\n    result := .{ x: 1, y: 2 }\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_anon_struct = false;
    var field_init_count: u32 = 0;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .anon_struct_literal) found_anon_struct = true;
        if (node.tag == .struct_field_init) field_init_count += 1;
    }
    try std.testing.expect(found_anon_struct);
    try std.testing.expectEqual(@as(u32, 2), field_init_count);
}

test "parse anonymous struct type with field colons" {
    const source = "fn swap(a int, b int) struct { first: int, second: int } {\n    return .{ first: b, second: a }\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_type = false;
    var field_count: u32 = 0;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .type_anon_struct) found_type = true;
        if (node.tag == .field_decl) field_count += 1;
    }
    try std.testing.expect(found_type);
    try std.testing.expectEqual(@as(u32, 2), field_count);
}

test "parse error union of anonymous struct" {
    const source = "fn parse(s string) !struct { value int, rest string } {\n    return .{ value: 0, rest: s }\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_error_union = false;
    var found_anon_struct_type = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .type_error_union) found_error_union = true;
        if (node.tag == .type_anon_struct) found_anon_struct_type = true;
    }
    try std.testing.expect(found_error_union);
    try std.testing.expect(found_anon_struct_type);
}

test "parse anonymous struct in closure return type" {
    const source = "fn main() {\n    f := fn(x int) struct { doubled int, tripled int } {\n        return .{ doubled: x * 2, tripled: x * 3 }\n    }\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_closure = false;
    var found_anon_struct_type = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .closure) found_closure = true;
        if (node.tag == .type_anon_struct) found_anon_struct_type = true;
    }
    try std.testing.expect(found_closure);
    try std.testing.expect(found_anon_struct_type);
}

test "parse anonymous struct with newline-separated fields" {
    const source = "fn coords() struct {\n    x int\n    y int\n    z int\n} {\n    return .{ x: 1, y: 2, z: 3 }\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var field_count: u32 = 0;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .field_decl) field_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 3), field_count);
}

test "parse pointer to anonymous struct type" {
    const source = "fn make() &struct { x int, y int } {\n    return .{ x: 0, y: 0 }\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_ptr = false;
    var found_anon_struct = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .type_ptr) found_ptr = true;
        if (node.tag == .type_anon_struct) found_anon_struct = true;
    }
    try std.testing.expect(found_ptr);
    try std.testing.expect(found_anon_struct);
}

test "parse method returning anonymous struct" {
    const source = "fn (p @Point) decompose() struct { x f64, y f64 } {\n    return .{ x: p.x, y: p.y }\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_receiver = false;
    var found_anon_struct_type = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .receiver) found_receiver = true;
        if (node.tag == .type_anon_struct) found_anon_struct_type = true;
    }
    try std.testing.expect(found_receiver);
    try std.testing.expect(found_anon_struct_type);
}

test "parse public method with receiver" {
    const source = "pub fn (p &Point) translate(dx f64, dy f64) {\n    p.x = p.x + dx\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_pub = false;
    var found_fn = false;
    var found_receiver = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .pub_decl) found_pub = true;
        if (node.tag == .fn_decl) found_fn = true;
        if (node.tag == .receiver) found_receiver = true;
    }
    try std.testing.expect(found_pub);
    try std.testing.expect(found_fn);
    try std.testing.expect(found_receiver);
}

test "parse method with value receiver" {
    const source = "fn (p Point) area() f64 {\n    return 0.0\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_receiver = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .receiver) {
            found_receiver = true;
            // Value receiver type should be type_name (not type_ptr or type_const_ptr)
            const type_node = parser.tree.nodes.items[node.data.lhs];
            try std.testing.expectEqual(.type_name, type_node.tag);
            // Verify the type name is "Point"
            const type_name = tokens.items[type_node.main_token].slice(source);
            try std.testing.expectEqualStrings("Point", type_name);
        }
    }
    try std.testing.expect(found_receiver);
}

test "parse method with error union return type" {
    const source = "fn (c &Connection) read(buf []byte) !int {\n    return 0\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_receiver = false;
    var found_error_union = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .receiver) found_receiver = true;
        if (node.tag == .type_error_union) found_error_union = true;
    }
    try std.testing.expect(found_receiver);
    try std.testing.expect(found_error_union);
}

test "parse method with no params" {
    const source = "fn (s @Circle) area() f64 {\n    return 0.0\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_receiver = false;
    var param_count: u32 = 0;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .receiver) found_receiver = true;
        if (node.tag == .param) param_count += 1;
    }
    try std.testing.expect(found_receiver);
    try std.testing.expectEqual(@as(u32, 0), param_count);
}

test "receiver main_token points to name identifier" {
    const source = "fn (self &Point) origin() {\n    return\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    for (parser.tree.nodes.items) |node| {
        if (node.tag == .receiver) {
            // main_token should point to the receiver name "self"
            const name = tokens.items[node.main_token].slice(source);
            try std.testing.expectEqualStrings("self", name);
            break;
        }
    }
}

test "parse multiple methods on same type" {
    const source = "fn (p &Point) getX() f64 {\n    return 0.0\n}\nfn (p &Point) getY() f64 {\n    return 0.0\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var fn_count: u32 = 0;
    var receiver_count: u32 = 0;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .fn_decl) fn_count += 1;
        if (node.tag == .receiver) receiver_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), fn_count);
    try std.testing.expectEqual(@as(u32, 2), receiver_count);
}

test "parse type declaration with simple type" {
    const source = "type A int";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_type_decl = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .type_decl) {
            found_type_decl = true;
            break;
        }
    }
    try std.testing.expect(found_type_decl);
}

test "parse pub type declaration" {
    const source = "pub type A int";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_pub = false;
    var found_type_decl = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .pub_decl) found_pub = true;
        if (node.tag == .type_decl) found_type_decl = true;
    }
    try std.testing.expect(found_pub);
    try std.testing.expect(found_type_decl);
}

test "parse type declaration with float type" {
    const source = "type B f64";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);
}

test "parse type declaration with pointer type" {
    const source = "type Ref &int";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_type_decl = false;
    var found_type_ptr = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .type_decl) found_type_decl = true;
        if (node.tag == .type_ptr) found_type_ptr = true;
    }
    try std.testing.expect(found_type_decl);
    try std.testing.expect(found_type_ptr);
}

test "parse type declaration with slice type" {
    const source = "type Bytes []byte";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var found_type_decl = false;
    var found_type_slice = false;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .type_decl) found_type_decl = true;
        if (node.tag == .type_slice) found_type_slice = true;
    }
    try std.testing.expect(found_type_decl);
    try std.testing.expect(found_type_slice);
}

test "parse multiple type declarations" {
    const source = "pub type A int\ntype B f64";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    var type_decl_count: u32 = 0;
    for (parser.tree.nodes.items) |node| {
        if (node.tag == .type_decl) type_decl_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), type_decl_count);
}

test "parse try without context" {
    const source = "fn main() {\n    x := try do_work()\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    for (parser.tree.nodes.items) |node| {
        if (node.tag == .try_expr) {
            // rhs should be null_node when no context is provided
            try std.testing.expectEqual(null_node, node.data.rhs);
            return;
        }
    }
    return error.TestUnexpectedResult; // no try_expr found
}

test "parse try with context string" {
    const source = "fn main() {\n    x := try read_file(path) :: \"loading config\"\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    for (parser.tree.nodes.items) |node| {
        if (node.tag == .try_expr) {
            // rhs should point to a string_literal node (not null_node)
            try std.testing.expect(node.data.rhs != null_node);
            const context_node = parser.tree.nodes.items[node.data.rhs];
            try std.testing.expectEqual(Node.Tag.string_literal, context_node.tag);
            return;
        }
    }
    return error.TestUnexpectedResult; // no try_expr found
}

test "parse try context in return statement" {
    const source = "fn load() !int {\n    return try parse(data) :: \"parsing data\"\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len == 0);

    for (parser.tree.nodes.items) |node| {
        if (node.tag == .try_expr) {
            try std.testing.expect(node.data.rhs != null_node);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "parse try context error on missing string" {
    const source = "fn main() {\n    x := try do_work() :: 42\n}";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    // Should have an error because :: is not followed by a string literal
    try std.testing.expect(parser.tree.errors.items.len > 0);
    try std.testing.expectEqual(Ast.ErrorTag.expected_string_literal, parser.tree.errors.items[0].tag);
}

test "parse alloc expression for slice/map/channel" {
    const source =
        "fn main() {\n" ++
        "    a := alloc([]int, 50)\n" ++
        "    b := alloc(map[string]string, 10)\n" ++
        "    c := alloc(chan[int], allocator: mem.arena)\n" ++
        "}\n";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expectEqual(@as(usize, 0), parser.tree.errors.items.len);

    var alloc_count: u32 = 0;
    var has_map_type = false;
    var has_chan_type = false;

    for (parser.tree.nodes.items) |node| {
        if (node.tag == .alloc_expr) {
            alloc_count += 1;
        }
        if (node.tag == .type_map) has_map_type = true;
        if (node.tag == .type_chan) has_chan_type = true;
    }

    try std.testing.expectEqual(@as(u32, 3), alloc_count);
    try std.testing.expect(has_map_type);
    try std.testing.expect(has_chan_type);
}

test "parse alloc defaults without capacity" {
    const source =
        "fn main() {\n" ++
        "    s := alloc([]int)\n" ++
        "    m := alloc(map[string]string)\n" ++
        "    c := alloc(chan[int])\n" ++
        "}\n";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expectEqual(@as(usize, 0), parser.tree.errors.items.len);

    for (parser.tree.nodes.items) |node| {
        if (node.tag == .alloc_expr) {
            const start = node.data.rhs;
            try std.testing.expectEqual(null_node, parser.tree.extra_data.items[start]);
            try std.testing.expectEqual(null_node, parser.tree.extra_data.items[start + 1]);
        }
    }
}

test "parse alloc rejects non-collection type" {
    const source = "fn main() {\n    a := alloc(int, 1)\n}\n";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len > 0);
    try std.testing.expectEqual(Ast.ErrorTag.invalid_alloc_type, parser.tree.errors.items[0].tag);
}

test "parse alloc named allocator after capacity" {
    const source = "fn main() {\n    s := alloc([]int, 32, allocator: mem.arena)\n}\n";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expectEqual(@as(usize, 0), parser.tree.errors.items.len);

    for (parser.tree.nodes.items) |node| {
        if (node.tag == .alloc_expr) {
            const start = node.data.rhs;
            try std.testing.expect(parser.tree.extra_data.items[start] != null_node);
            try std.testing.expect(parser.tree.extra_data.items[start + 1] != null_node);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "parse alloc rejects positional third argument" {
    const source = "fn main() {\n    s := alloc([]int, 32, mem.arena)\n}\n";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    var parser = Parser.init(std.testing.allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();
    try std.testing.expect(parser.tree.errors.items.len > 0);
}
