const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Token = @import("token.zig").Token;
const Ast = @import("ast.zig");
const formatter = @import("formatter.zig");

const allocator = std.heap.wasm_allocator;

/// Result buffer managed by WASM — JS reads from this after each call.
var result_ptr: [*]const u8 = undefined;
var result_len: usize = 0;

export fn getResultPtr() [*]const u8 {
    return result_ptr;
}

export fn getResultLen() usize {
    return result_len;
}

/// Allocate memory for JS to write source code into.
export fn alloc(len: usize) ?[*]u8 {
    const buf = allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

/// Free memory previously allocated by `alloc`.
export fn dealloc(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

/// Free the current result buffer.
fn freeResult() void {
    if (result_len > 0) {
        allocator.free(result_ptr[0..result_len]);
        result_len = 0;
    }
}

fn setResult(data: []const u8) void {
    freeResult();
    result_ptr = data.ptr;
    result_len = data.len;
}

fn setResultOwned(data: []u8) void {
    freeResult();
    result_ptr = data.ptr;
    result_len = data.len;
}

// ── JSON helpers ──────────────────────────────────────────────────────

fn appendJsonString(buf: *std.ArrayList(u8), s: []const u8) void {
    buf.append(allocator, '"') catch return;
    for (s) |c| {
        switch (c) {
            '"' => buf.appendSlice(allocator, "\\\"") catch return,
            '\\' => buf.appendSlice(allocator, "\\\\") catch return,
            '\n' => buf.appendSlice(allocator, "\\n") catch return,
            '\r' => buf.appendSlice(allocator, "\\r") catch return,
            '\t' => buf.appendSlice(allocator, "\\t") catch return,
            else => {
                if (c < 0x20) {
                    buf.appendSlice(allocator, "\\u00") catch return;
                    const hex = "0123456789abcdef";
                    buf.append(allocator, hex[c >> 4]) catch return;
                    buf.append(allocator, hex[c & 0xf]) catch return;
                } else {
                    buf.append(allocator, c) catch return;
                }
            },
        }
    }
    buf.append(allocator, '"') catch return;
}

fn appendNumber(buf: *std.ArrayList(u8), n: anytype) void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return;
    buf.appendSlice(allocator, s) catch return;
}

// ── Source location helper ────────────────────────────────────────────

const Location = struct {
    line: u32,
    col: u32,
};

fn getLocation(source: []const u8, offset: u32) Location {
    const off: usize = @min(offset, source.len);
    var line: u32 = 1;
    var line_start: usize = 0;
    for (source[0..off], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{
        .line = line,
        .col = @intCast(off - line_start + 1),
    };
}

// ── Exported operations ───────────────────────────────────────────────

/// Check source: parse and return diagnostics as JSON.
/// Returns: { "ok": true/false, "errors": [...], "nodeCount": N }
export fn check(src_ptr: [*]const u8, src_len: usize) void {
    const source = src_ptr[0..src_len];

    var lexer = Lexer.init(source);
    var tokens = lexer.tokenize(allocator) catch {
        setResult("{\"ok\":false,\"errors\":[{\"line\":1,\"col\":1,\"message\":\"out of memory\"}],\"nodeCount\":0}");
        return;
    };
    defer tokens.deinit(allocator);

    var parser = Parser.init(allocator, tokens.items, source);
    defer parser.deinit();

    _ = parser.parseFile() catch {
        setResult("{\"ok\":false,\"errors\":[{\"line\":1,\"col\":1,\"message\":\"out of memory\"}],\"nodeCount\":0}");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;

    if (parser.tree.errors.items.len > 0) {
        buf.appendSlice(allocator, "{\"ok\":false,\"errors\":[") catch return;

        for (parser.tree.errors.items, 0..) |err, i| {
            if (i > 0) buf.append(allocator, ',') catch return;
            const loc = getLocation(source, err.loc.start);
            buf.appendSlice(allocator, "{\"line\":") catch return;
            appendNumber(&buf, loc.line);
            buf.appendSlice(allocator, ",\"col\":") catch return;
            appendNumber(&buf, loc.col);
            buf.appendSlice(allocator, ",\"message\":") catch return;
            const message = switch (err.tag) {
                .expected_token => "expected token",
                .expected_expression => "expected expression",
                .expected_type => "expected type",
                .expected_identifier => "expected identifier",
                .expected_package_decl => "expected package declaration",
                .expected_main_entrypoint => "expected main entrypoint",
                .expected_block => "expected block",
                .expected_string_literal => "expected string literal",
                .invalid_token => "invalid token",
                .invalid_alloc_type => "invalid alloc type",
                .expected_asm_register => "expected register name in assembly input binding",
                .expected_arrow_right => "expected '->' in assembly input binding",
                .unexpected_eof => "unexpected end of file",
            };
            appendJsonString(&buf, message);
            buf.append(allocator, '}') catch return;
        }
        buf.appendSlice(allocator, "],\"nodeCount\":") catch return;
        appendNumber(&buf, parser.tree.nodes.items.len);
        buf.append(allocator, '}') catch return;
    } else {
        buf.appendSlice(allocator, "{\"ok\":true,\"errors\":[],\"nodeCount\":") catch return;
        appendNumber(&buf, parser.tree.nodes.items.len);
        buf.append(allocator, '}') catch return;
    }

    setResultOwned(buf.items);
}

/// Tokenize source and return tokens as JSON array.
/// Returns: [{ "tag": "...", "text": "...", "line": N, "col": N }, ...]
export fn tokenize(src_ptr: [*]const u8, src_len: usize) void {
    const source = src_ptr[0..src_len];
    var buf: std.ArrayList(u8) = .empty;

    buf.append(allocator, '[') catch return;

    var lexer = Lexer.init(source);
    var count: usize = 0;

    while (true) {
        const tok = lexer.next();
        if (count > 0) buf.append(allocator, ',') catch return;

        const loc = getLocation(source, tok.loc.start);
        const text = if (tok.loc.start < tok.loc.end) tok.slice(source) else "";

        buf.appendSlice(allocator, "{\"tag\":") catch return;
        appendJsonString(&buf, @tagName(tok.tag));
        buf.appendSlice(allocator, ",\"text\":") catch return;
        appendJsonString(&buf, text);
        buf.appendSlice(allocator, ",\"line\":") catch return;
        appendNumber(&buf, loc.line);
        buf.appendSlice(allocator, ",\"col\":") catch return;
        appendNumber(&buf, loc.col);
        buf.append(allocator, '}') catch return;

        count += 1;
        if (tok.tag == .eof) break;
    }

    buf.append(allocator, ']') catch return;
    setResultOwned(buf.items);
}

/// Parse source and return AST nodes as JSON array.
/// Returns: [{ "index": N, "tag": "...", "token": "...", "lhs": N, "rhs": N }, ...]
export fn parse(src_ptr: [*]const u8, src_len: usize) void {
    const source = src_ptr[0..src_len];

    var lexer = Lexer.init(source);
    var tokens = lexer.tokenize(allocator) catch {
        setResult("[]");
        return;
    };
    defer tokens.deinit(allocator);

    var parser = Parser.init(allocator, tokens.items, source);
    defer parser.deinit();

    _ = parser.parseFile() catch {
        setResult("[]");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    buf.append(allocator, '[') catch return;

    for (parser.tree.nodes.items, 0..) |node, i| {
        if (i > 0) buf.append(allocator, ',') catch return;

        const text = if (node.main_token < tokens.items.len and
            tokens.items[node.main_token].loc.start < tokens.items[node.main_token].loc.end)
            tokens.items[node.main_token].slice(source)
        else
            "";

        buf.appendSlice(allocator, "{\"index\":") catch return;
        appendNumber(&buf, i);
        buf.appendSlice(allocator, ",\"tag\":") catch return;
        appendJsonString(&buf, @tagName(node.tag));
        buf.appendSlice(allocator, ",\"token\":") catch return;
        appendJsonString(&buf, text);
        buf.appendSlice(allocator, ",\"lhs\":") catch return;
        appendNumber(&buf, node.data.lhs);
        buf.appendSlice(allocator, ",\"rhs\":") catch return;
        appendNumber(&buf, node.data.rhs);
        buf.append(allocator, '}') catch return;
    }

    buf.append(allocator, ']') catch return;
    setResultOwned(buf.items);
}

/// Format source code. Returns: { "ok": true/false, "result": "..." }
export fn format(src_ptr: [*]const u8, src_len: usize) void {
    const source = src_ptr[0..src_len];

    const formatted = formatter.formatSource(allocator, source) catch {
        setResult("{\"ok\":false,\"result\":\"parse error\"}");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(allocator, "{\"ok\":true,\"result\":") catch {
        allocator.free(formatted);
        return;
    };
    appendJsonString(&buf, formatted);
    buf.append(allocator, '}') catch {
        allocator.free(formatted);
        return;
    };
    allocator.free(formatted);
    setResultOwned(buf.items);
}

// ── Tree-walking interpreter ──────────────────────────────────────────

const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    none,
};

const Interpreter = struct {
    nodes: []const Ast.Node,
    extra_data: []const Ast.NodeIndex,
    tokens: []const Token,
    source: []const u8,
    output: *std.ArrayList(u8),
    /// Variable scope — simple flat list, push/pop for blocks.
    vars: std.ArrayList(Binding),
    step_count: u32 = 0,
    has_error: bool = false,
    err_msg: []const u8 = "",

    const Binding = struct {
        name: []const u8,
        value: Value,
    };

    const max_steps: u32 = 100_000;

    fn init(
        nodes: []const Ast.Node,
        extra_data: []const Ast.NodeIndex,
        tokens: []const Token,
        source: []const u8,
        output: *std.ArrayList(u8),
    ) Interpreter {
        return .{
            .nodes = nodes,
            .extra_data = extra_data,
            .tokens = tokens,
            .source = source,
            .output = output,
            .vars = .empty,
        };
    }

    fn deinit(self: *Interpreter) void {
        self.vars.deinit(allocator);
    }

    fn setError(self: *Interpreter, msg: []const u8) void {
        self.has_error = true;
        self.err_msg = msg;
    }

    fn stepCheck(self: *Interpreter) bool {
        self.step_count += 1;
        if (self.step_count > max_steps) {
            self.setError("execution limit exceeded (possible infinite loop)");
            return false;
        }
        return true;
    }

    fn lookupVar(self: *Interpreter, name: []const u8) ?Value {
        // Search backwards for most recent binding
        var i = self.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.vars.items[i].name, name)) {
                return self.vars.items[i].value;
            }
        }
        return null;
    }

    fn tokenText(self: *Interpreter, tok_idx: u32) []const u8 {
        if (tok_idx >= self.tokens.len) return "";
        const tok = self.tokens[tok_idx];
        if (tok.loc.start >= tok.loc.end) return "";
        return self.source[tok.loc.start..tok.loc.end];
    }

    fn findMainFn(self: *Interpreter) ?Ast.NodeIndex {
        for (self.nodes, 0..) |node, i| {
            const idx: Ast.NodeIndex = @intCast(i);
            switch (node.tag) {
                .fn_decl => {
                    // main_token is kw_fun; function name is next non-newline token
                    const name = self.getFnName(node.main_token);
                    if (std.mem.eql(u8, name, "main")) return idx;
                },
                .pub_decl => {
                    // lhs = inner declaration
                    if (node.data.lhs != Ast.null_node) {
                        const inner = self.nodes[node.data.lhs];
                        if (inner.tag == .fn_decl) {
                            const name = self.getFnName(inner.main_token);
                            if (std.mem.eql(u8, name, "main")) return node.data.lhs;
                        }
                    }
                },
                .inline_decl => {
                    if (node.data.lhs != Ast.null_node) {
                        var inner = self.nodes[node.data.lhs];
                        var fn_node_idx = node.data.lhs;
                        if (inner.tag == .pub_decl and inner.data.lhs != Ast.null_node) {
                            fn_node_idx = inner.data.lhs;
                            inner = self.nodes[fn_node_idx];
                        }
                        if (inner.tag == .fn_decl) {
                            const name = self.getFnName(inner.main_token);
                            if (std.mem.eql(u8, name, "main")) return fn_node_idx;
                        }
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn getFnName(self: *Interpreter, fn_tok: u32) []const u8 {
        // Skip past kw_fun and any newlines/receiver to find function name
        var pos = fn_tok + 1;
        while (pos < self.tokens.len) {
            const tag = self.tokens[pos].tag;
            if (tag == .newline) {
                pos += 1;
                continue;
            }
            // Skip receiver: (self &Type)
            if (tag == .l_paren) {
                // Find matching r_paren
                var depth: u32 = 1;
                pos += 1;
                while (pos < self.tokens.len and depth > 0) {
                    if (self.tokens[pos].tag == .l_paren) depth += 1;
                    if (self.tokens[pos].tag == .r_paren) depth -= 1;
                    pos += 1;
                }
                // Skip newlines after receiver
                while (pos < self.tokens.len and self.tokens[pos].tag == .newline) pos += 1;
                break;
            }
            break;
        }
        if (pos < self.tokens.len and self.tokens[pos].tag == .identifier) {
            return self.tokenText(pos);
        }
        return "";
    }

    fn execBlock(self: *Interpreter, node_idx: Ast.NodeIndex) void {
        if (self.has_error) return;
        const node = self.nodes[node_idx];
        if (node.tag != .block) return;

        const start = node.data.lhs;
        const count = node.data.rhs;
        const saved_vars_len = self.vars.items.len;

        var j: u32 = 0;
        while (j < count) : (j += 1) {
            if (self.has_error) break;
            const stmt_idx = self.extra_data[start + j];
            self.execStmt(stmt_idx);
        }

        // Pop scope
        self.vars.shrinkRetainingCapacity(saved_vars_len);
    }

    fn execStmt(self: *Interpreter, node_idx: Ast.NodeIndex) void {
        if (self.has_error) return;
        if (!self.stepCheck()) return;

        const node = self.nodes[node_idx];
        switch (node.tag) {
            .let_decl, .var_decl => {
                // main_token = kw_let/kw_var, next identifier is var name
                var pos = node.main_token + 1;
                while (pos < self.tokens.len and self.tokens[pos].tag == .newline) pos += 1;
                const name = self.tokenText(pos);
                const val = if (node.data.rhs != Ast.null_node) self.evalExpr(node.data.rhs) else Value{ .none = {} };
                self.vars.append(allocator, .{ .name = name, .value = val }) catch {
                    self.setError("out of memory");
                };
            },
            .short_var_decl => {
                // main_token = identifier, := follows
                const name = self.tokenText(node.main_token);
                const val = if (node.data.rhs != Ast.null_node) self.evalExpr(node.data.rhs) else Value{ .none = {} };
                self.vars.append(allocator, .{ .name = name, .value = val }) catch {
                    self.setError("out of memory");
                };
            },
            .assign => {
                // lhs = target (ident), rhs = value
                const target = self.nodes[node.data.lhs];
                if (target.tag == .ident) {
                    const name = self.tokenText(target.main_token);
                    const val = self.evalExpr(node.data.rhs);
                    // Find and update existing variable
                    var i = self.vars.items.len;
                    while (i > 0) {
                        i -= 1;
                        if (std.mem.eql(u8, self.vars.items[i].name, name)) {
                            self.vars.items[i].value = val;
                            return;
                        }
                    }
                    self.setError("undefined variable in assignment");
                }
            },
            .expr_stmt => {
                _ = self.evalExpr(node.data.lhs);
            },
            .if_stmt => {
                const cond = self.evalExpr(node.data.lhs);
                const is_true = switch (cond) {
                    .boolean => |b| b,
                    .int => |n| n != 0,
                    .none => false,
                    else => true,
                };
                // extra_data: [then_block, else_node]
                const then_node = self.extra_data[node.data.rhs];
                const else_node = self.extra_data[node.data.rhs + 1];
                if (is_true) {
                    self.execBlock(then_node);
                } else if (else_node != Ast.null_node) {
                    const else_n = self.nodes[else_node];
                    if (else_n.tag == .block) {
                        self.execBlock(else_node);
                    } else if (else_n.tag == .if_stmt) {
                        self.execStmt(else_node);
                    }
                }
            },
            .for_stmt => {
                self.execFor(node_idx);
            },
            .return_stmt => {
                // Simple return — just stop executing current block
                // (we don't support return values in the interpreter yet)
                return;
            },
            .block => {
                self.execBlock(node_idx);
            },
            else => {
                // Skip unsupported statements
            },
        }
    }

    fn execFor(self: *Interpreter, node_idx: Ast.NodeIndex) void {
        const node = self.nodes[node_idx];
        const lhs_node = self.nodes[node.data.lhs];

        // Check if this is a for-in-range loop
        if (node.data.lhs != Ast.null_node and lhs_node.tag == .range) {
            // for <var> in <start>..<end> { body }
            // Get iteration variable name from tokens after kw_for
            var pos = node.main_token + 1;
            while (pos < self.tokens.len and self.tokens[pos].tag == .newline) pos += 1;
            const iter_name = self.tokenText(pos);

            const start_val = self.evalExpr(lhs_node.data.lhs);
            const end_val = self.evalExpr(lhs_node.data.rhs);

            const start_int = switch (start_val) {
                .int => |n| n,
                else => {
                    self.setError("range start must be an integer");
                    return;
                },
            };
            const end_int = switch (end_val) {
                .int => |n| n,
                else => {
                    self.setError("range end must be an integer");
                    return;
                },
            };

            const saved_vars_len = self.vars.items.len;
            self.vars.append(allocator, .{ .name = iter_name, .value = .{ .int = start_int } }) catch {
                self.setError("out of memory");
                return;
            };
            const var_idx = self.vars.items.len - 1;

            var i = start_int;
            while (i < end_int) : (i += 1) {
                if (self.has_error) break;
                if (!self.stepCheck()) break;
                self.vars.items[var_idx].value = .{ .int = i };
                self.execBlock(node.data.rhs);
            }

            self.vars.shrinkRetainingCapacity(saved_vars_len);
        } else if (node.data.lhs == Ast.null_node) {
            // Infinite loop: for { body } — run with step limit
            while (!self.has_error) {
                if (!self.stepCheck()) break;
                self.execBlock(node.data.rhs);
            }
        } else {
            // Conditional loop: for cond { body }
            while (!self.has_error) {
                if (!self.stepCheck()) break;
                const cond = self.evalExpr(node.data.lhs);
                const is_true = switch (cond) {
                    .boolean => |b| b,
                    .int => |n| n != 0,
                    .none => false,
                    else => true,
                };
                if (!is_true) break;
                self.execBlock(node.data.rhs);
            }
        }
    }

    fn evalExpr(self: *Interpreter, node_idx: Ast.NodeIndex) Value {
        if (self.has_error) return .{ .none = {} };
        if (node_idx == Ast.null_node) return .{ .none = {} };
        if (!self.stepCheck()) return .{ .none = {} };

        const node = self.nodes[node_idx];
        switch (node.tag) {
            .int_literal => {
                const text = self.tokenText(node.main_token);
                const val = std.fmt.parseInt(i64, text, 10) catch 0;
                return .{ .int = val };
            },
            .float_literal => {
                const text = self.tokenText(node.main_token);
                const val = std.fmt.parseFloat(f64, text) catch 0.0;
                return .{ .float = val };
            },
            .string_literal => {
                const text = self.tokenText(node.main_token);
                // Strip surrounding quotes
                if (text.len >= 2) {
                    return .{ .string = text[1 .. text.len - 1] };
                }
                return .{ .string = "" };
            },
            .bool_literal => {
                const text = self.tokenText(node.main_token);
                return .{ .boolean = std.mem.eql(u8, text, "true") };
            },
            .null_literal => {
                return .{ .none = {} };
            },
            .ident => {
                const name = self.tokenText(node.main_token);
                if (self.lookupVar(name)) |val| return val;
                self.setError("undefined variable");
                return .{ .none = {} };
            },
            .binary_op => {
                return self.evalBinaryOp(node_idx);
            },
            .unary_op => {
                const operand = self.evalExpr(node.data.lhs);
                const op_text = self.tokenText(node.main_token);
                if (std.mem.eql(u8, op_text, "-")) {
                    switch (operand) {
                        .int => |n| return .{ .int = -n },
                        .float => |n| return .{ .float = -n },
                        else => return .{ .none = {} },
                    }
                }
                if (std.mem.eql(u8, op_text, "!") or std.mem.eql(u8, op_text, "not")) {
                    switch (operand) {
                        .boolean => |b| return .{ .boolean = !b },
                        else => return .{ .none = {} },
                    }
                }
                return .{ .none = {} };
            },
            .call => {
                return self.evalCall(node_idx);
            },
            .if_expr => {
                const cond = self.evalExpr(node.data.lhs);
                const is_true = switch (cond) {
                    .boolean => |b| b,
                    .int => |n| n != 0,
                    .none => false,
                    else => true,
                };
                const then_expr = self.extra_data[node.data.rhs];
                const else_expr = self.extra_data[node.data.rhs + 1];
                return if (is_true) self.evalExpr(then_expr) else self.evalExpr(else_expr);
            },
            else => {
                return .{ .none = {} };
            },
        }
    }

    fn evalBinaryOp(self: *Interpreter, node_idx: Ast.NodeIndex) Value {
        const node = self.nodes[node_idx];
        const lhs = self.evalExpr(node.data.lhs);
        const rhs = self.evalExpr(node.data.rhs);
        const op_text = self.tokenText(node.main_token);

        // String concatenation with +
        if (std.mem.eql(u8, op_text, "+")) {
            switch (lhs) {
                .string => |ls| {
                    switch (rhs) {
                        .string => |rs| {
                            var buf = allocator.alloc(u8, ls.len + rs.len) catch return .{ .none = {} };
                            @memcpy(buf[0..ls.len], ls);
                            @memcpy(buf[ls.len..], rs);
                            return .{ .string = buf };
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        // Integer arithmetic
        const l = switch (lhs) {
            .int => |n| n,
            else => return .{ .none = {} },
        };
        const r = switch (rhs) {
            .int => |n| n,
            else => return .{ .none = {} },
        };

        if (std.mem.eql(u8, op_text, "+")) return .{ .int = l + r };
        if (std.mem.eql(u8, op_text, "-")) return .{ .int = l - r };
        if (std.mem.eql(u8, op_text, "*")) return .{ .int = l * r };
        if (std.mem.eql(u8, op_text, "/")) {
            if (r == 0) {
                self.setError("division by zero");
                return .{ .none = {} };
            }
            return .{ .int = @divTrunc(l, r) };
        }
        if (std.mem.eql(u8, op_text, "%")) {
            if (r == 0) {
                self.setError("modulo by zero");
                return .{ .none = {} };
            }
            return .{ .int = @mod(l, r) };
        }
        if (std.mem.eql(u8, op_text, "==")) return .{ .boolean = l == r };
        if (std.mem.eql(u8, op_text, "!=")) return .{ .boolean = l != r };
        if (std.mem.eql(u8, op_text, "<")) return .{ .boolean = l < r };
        if (std.mem.eql(u8, op_text, ">")) return .{ .boolean = l > r };
        if (std.mem.eql(u8, op_text, "<=")) return .{ .boolean = l <= r };
        if (std.mem.eql(u8, op_text, ">=")) return .{ .boolean = l >= r };

        return .{ .none = {} };
    }

    fn evalCall(self: *Interpreter, node_idx: Ast.NodeIndex) Value {
        const node = self.nodes[node_idx];
        const callee_node = self.nodes[node.data.lhs];

        // Get function name
        var fn_name: []const u8 = "";
        if (callee_node.tag == .ident) {
            fn_name = self.tokenText(callee_node.main_token);
        }

        // Get args from extra_data: [arg1, ..., argN, count]
        const extra_start = node.data.rhs;
        // Read count from end
        const count_pos = self.findCallArgCount(extra_start);
        const arg_count = self.extra_data[count_pos];

        // Evaluate args
        var args: [16]Value = undefined;
        const n = @min(arg_count, 16);
        for (0..n) |i| {
            args[i] = self.evalExpr(self.extra_data[extra_start + i]);
        }

        // Built-in functions
        if (std.mem.eql(u8, fn_name, "println")) {
            for (0..n) |i| {
                if (i > 0) self.output.append(allocator, ' ') catch {};
                self.writeValue(args[i]);
            }
            self.output.append(allocator, '\n') catch {};
            return .{ .none = {} };
        }
        if (std.mem.eql(u8, fn_name, "print")) {
            for (0..n) |i| {
                if (i > 0) self.output.append(allocator, ' ') catch {};
                self.writeValue(args[i]);
            }
            return .{ .none = {} };
        }

        // Not a built-in — skip silently
        return .{ .none = {} };
    }

    fn findCallArgCount(self: *Interpreter, extra_start: u32) u32 {
        // The call extra_data layout is: [arg1, arg2, ..., argN, count]
        // We need to find count. Read the value at extra_start, which is arg1 or count if 0 args.
        // Actually we need to scan: the count is stored after all args.
        // But we don't know how many args there are without the count...
        // The count is at extra_start + arg_count. We can iterate:
        // Try reading potential count values and check if they match position.
        // Simpler: count is always the last entry. We know that arg values are
        // node indices (typically > 0), and count is typically small.
        // Actually, the layout is fixed: after all args, the count is stored.
        // We need to scan: for a call at extra_start, try count = extra_data[extra_start + i]
        // where i == extra_data[extra_start + i].
        var i: u32 = 0;
        while (extra_start + i < self.extra_data.len) : (i += 1) {
            if (self.extra_data[extra_start + i] == i) {
                return extra_start + i;
            }
            if (i > 16) break; // safety limit
        }
        return extra_start; // fallback: 0 args
    }

    fn writeValue(self: *Interpreter, val: Value) void {
        switch (val) {
            .int => |n| {
                var tmp: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return;
                self.output.appendSlice(allocator, s) catch {};
            },
            .float => |n| {
                var tmp: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return;
                self.output.appendSlice(allocator, s) catch {};
            },
            .string => |s| {
                self.output.appendSlice(allocator, s) catch {};
            },
            .boolean => |b| {
                self.output.appendSlice(allocator, if (b) "true" else "false") catch {};
            },
            .none => {
                self.output.appendSlice(allocator, "null") catch {};
            },
        }
    }
};

/// Run source: interpret and return program output as JSON.
/// Returns: { "ok": true/false, "output": "...", "error": "..." }
export fn run(src_ptr: [*]const u8, src_len: usize) void {
    const source = src_ptr[0..src_len];

    var lexer = Lexer.init(source);
    var tokens = lexer.tokenize(allocator) catch {
        setResult("{\"ok\":false,\"output\":\"\",\"error\":\"out of memory\"}");
        return;
    };
    defer tokens.deinit(allocator);

    var parser = Parser.init(allocator, tokens.items, source);
    defer parser.deinit();

    _ = parser.parseFile() catch {
        setResult("{\"ok\":false,\"output\":\"\",\"error\":\"out of memory\"}");
        return;
    };

    if (parser.tree.errors.items.len > 0) {
        const err = parser.tree.errors.items[0];
        const loc = getLocation(source, err.loc.start);
        var buf: std.ArrayList(u8) = .empty;
        buf.appendSlice(allocator, "{\"ok\":false,\"output\":\"\",\"error\":\"parse error at line ") catch return;
        appendNumber(&buf, loc.line);
        buf.appendSlice(allocator, ", col ") catch return;
        appendNumber(&buf, loc.col);
        buf.appendSlice(allocator, "\"}") catch return;
        setResultOwned(buf.items);
        return;
    }

    var output_buf: std.ArrayList(u8) = .empty;
    var interp = Interpreter.init(
        parser.tree.nodes.items,
        parser.tree.extra_data.items,
        tokens.items,
        source,
        &output_buf,
    );
    defer interp.deinit();

    const main_fn = interp.findMainFn();
    if (main_fn == null) {
        setResult("{\"ok\":false,\"output\":\"\",\"error\":\"no main function found\"}");
        output_buf.deinit(allocator);
        return;
    }

    const fn_node = interp.nodes[main_fn.?];
    if (fn_node.data.rhs != Ast.null_node) {
        interp.execBlock(fn_node.data.rhs);
    }

    var buf: std.ArrayList(u8) = .empty;
    if (interp.has_error) {
        buf.appendSlice(allocator, "{\"ok\":false,\"output\":") catch return;
        appendJsonString(&buf, output_buf.items);
        buf.appendSlice(allocator, ",\"error\":") catch return;
        appendJsonString(&buf, interp.err_msg);
        buf.append(allocator, '}') catch return;
    } else {
        buf.appendSlice(allocator, "{\"ok\":true,\"output\":") catch return;
        appendJsonString(&buf, output_buf.items);
        buf.appendSlice(allocator, "}") catch return;
    }

    output_buf.deinit(allocator);
    setResultOwned(buf.items);
}
