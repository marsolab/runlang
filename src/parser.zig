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

    pub const Error = error{OutOfMemory};

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token, source: []const u8) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .source = source,
            .tree = Ast.init(allocator, source),
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

        // Store receiver and return type in extra data
        _ = try self.tree.addExtra(receiver_node);
        _ = try self.tree.addExtra(ret_type);

        return self.tree.addNode(.{
            .tag = .fn_decl,
            .main_token = fn_tok,
            .data = .{ .lhs = params_start, .rhs = body },
        });
    }

    fn parseReceiver(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        self.expect(.l_paren);

        // receiver name
        if (self.peekTag() != .identifier) {
            try self.addError(.expected_identifier, self.currentLoc(), null);
            return null_node;
        }
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
        const start: u32 = @intCast(self.tree.extra_data.items.len);
        var count: u32 = 0;

        while (self.peekTag() != .r_paren and !self.isAtEnd()) {
            if (count > 0) {
                self.expectToken(.comma);
            }
            const param = try self.parseParam();
            _ = try self.tree.addExtra(param);
            count += 1;
        }
        self.expectToken(.r_paren);
        _ = try self.tree.addExtra(count);
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

        // Parse fields
        var field_count: u32 = 0;
        while (self.peekTag() != .r_brace and !self.isAtEnd()) {
            self.skipNewlines();
            if (self.peekTag() == .r_brace) break;

            const field = try self.parseFieldDecl();
            _ = try self.tree.addExtra(field);
            field_count += 1;

            self.skipNewlines();
            // Optional comma between fields
            if (self.peekTag() == .comma) self.advance();
            self.skipNewlines();
        }
        self.expectToken(.r_brace);

        return self.tree.addNode(.{
            .tag = .struct_decl,
            .main_token = tok,
            .data = .{ .lhs = start, .rhs = field_count },
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

        const start: u32 = @intCast(self.tree.extra_data.items.len);
        var count: u32 = 0;

        while (self.peekTag() != .r_brace and !self.isAtEnd()) {
            self.skipNewlines();
            if (self.peekTag() == .r_brace) break;
            const method = try self.parseMethodSig();
            _ = try self.tree.addExtra(method);
            count += 1;
            self.skipNewlines();
        }
        self.expectToken(.r_brace);

        return self.tree.addNode(.{
            .tag = .interface_decl,
            .main_token = tok,
            .data = .{ .lhs = start, .rhs = count },
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
        self.expectToken(.equal);

        // Parse sum type variants: .loading | .ready(Data) | .error(string)
        const start: u32 = @intCast(self.tree.extra_data.items.len);
        var count: u32 = 0;

        const variant = try self.parseVariantDef();
        _ = try self.tree.addExtra(variant);
        count += 1;

        while (self.peekTag() == .pipe) {
            self.advance();
            const v = try self.parseVariantDef();
            _ = try self.tree.addExtra(v);
            count += 1;
        }

        return self.tree.addNode(.{
            .tag = .type_alias,
            .main_token = tok,
            .data = .{ .lhs = start, .rhs = count },
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

        // Store else in extra data
        _ = try self.tree.addExtra(else_node);

        return self.tree.addNode(.{
            .tag = .if_stmt,
            .main_token = tok,
            .data = .{ .lhs = condition, .rhs = then_block },
        });
    }

    /// Parse the rest of a ternary if-expression after condition has been parsed.
    /// Expects `::` as the current token.
    fn parseIfExprRest(self: *Parser, tok: u32, condition: NodeIndex) Error!NodeIndex {
        self.expectToken(.colon_colon);
        const then_expr = try self.parseExpr();
        self.expectToken(.kw_else);
        const else_expr = try self.parseExpr();

        _ = try self.tree.addExtra(else_expr);

        return self.tree.addNode(.{
            .tag = .if_expr,
            .main_token = tok,
            .data = .{ .lhs = condition, .rhs = then_expr },
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

        const start: u32 = @intCast(self.tree.extra_data.items.len);
        var count: u32 = 0;

        while (self.peekTag() != .r_brace and !self.isAtEnd()) {
            self.skipNewlines();
            if (self.peekTag() == .r_brace) break;
            const arm = try self.parseSwitchArm();
            _ = try self.tree.addExtra(arm);
            count += 1;
            self.skipNewlines();
            if (self.peekTag() == .comma) self.advance();
            self.skipNewlines();
        }
        self.expectToken(.r_brace);
        _ = try self.tree.addExtra(count);

        return self.tree.addNode(.{
            .tag = .switch_stmt,
            .main_token = tok,
            .data = .{ .lhs = subject, .rhs = start },
        });
    }

    fn parseSwitchArm(self: *Parser) Error!NodeIndex {
        const tok = self.pos;
        const pattern = try self.parseExpr();
        self.expectToken(.fat_arrow);
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

        const start: u32 = @intCast(self.tree.extra_data.items.len);
        var count: u32 = 0;

        while (self.peekTag() != .r_brace and !self.isAtEnd()) {
            self.skipNewlines();
            if (self.peekTag() == .r_brace) break;
            const stmt = try self.parseStmt();
            if (stmt != null_node) {
                _ = try self.tree.addExtra(stmt);
                count += 1;
            }
            self.skipNewlines();
        }
        self.expectToken(.r_brace);

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
            return self.tree.addNode(.{
                .tag = .try_expr,
                .main_token = tok,
                .data = .{ .lhs = operand, .rhs = null_node },
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
                    if (node_tag == .ident or node_tag == .field_access) {
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
        const start: u32 = @intCast(self.tree.extra_data.items.len);
        var count: u32 = 0;

        while (self.peekTag() != .r_paren and !self.isAtEnd()) {
            if (count > 0) self.expectToken(.comma);
            const arg = try self.parseExpr();
            _ = try self.tree.addExtra(arg);
            count += 1;
        }
        self.expectToken(.r_paren);
        _ = try self.tree.addExtra(count);

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

        const start: u32 = @intCast(self.tree.extra_data.items.len);
        var count: u32 = 0;

        while (self.peekTag() != .r_brace and !self.isAtEnd()) {
            self.skipNewlines();
            if (self.peekTag() == .r_brace) break;

            if (count > 0) {
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
            _ = try self.tree.addExtra(field_init);
            count += 1;
            self.skipNewlines();
        }
        self.expectToken(.r_brace);
        _ = try self.tree.addExtra(count);

        return self.tree.addNode(.{
            .tag = .struct_literal,
            .main_token = tok,
            .data = .{ .lhs = type_node, .rhs = start },
        });
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
                // Variant literal: .loading, .ready(data)
                const tok = self.pos;
                self.advance();
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

        // Channel: chan T
        if (self.peekTag() == .kw_chan) {
            const tok = self.pos;
            self.advance();
            const inner = try self.parseType();
            return self.tree.addNode(.{
                .tag = .type_chan,
                .main_token = tok,
                .data = .{ .lhs = inner, .rhs = null_node },
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

    fn isTypeStart(self: *const Parser) bool {
        const tag = self.peekTag();
        return tag == .identifier or tag == .ampersand or tag == .at or
            tag == .bang or tag == .l_bracket or tag == .kw_chan;
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
    const source = "fun main() {\n    return\n}";
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
