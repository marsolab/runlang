const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Token = @import("token.zig").Token;
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
