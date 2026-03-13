const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Token = @import("token.zig").Token;
const Ast = @import("ast.zig").Ast;
const Node = @import("ast.zig").Node;
const NodeIndex = @import("ast.zig").NodeIndex;
const null_node = @import("ast.zig").null_node;

const File = std.fs.File;

/// JSON-RPC message header/body reader over stdin/stdout.
pub const Transport = struct {
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,
    read_buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, reader: std.io.AnyReader, writer: std.io.AnyWriter) Transport {
        return .{
            .reader = reader,
            .writer = writer,
            .read_buf = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Transport) void {
        self.read_buf.deinit(self.allocator);
    }

    /// Read a complete JSON-RPC message from the transport.
    /// Returns the parsed JSON value. Caller must call deinit on the returned Parsed.
    pub fn readMessage(self: *Transport) !std.json.Parsed(std.json.Value) {
        // Read headers until empty line
        var content_length: ?usize = null;
        var header_buf: [1024]u8 = undefined;

        while (true) {
            const line = self.reader.readUntilDelimiter(&header_buf, '\n') catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                else => return error.InvalidMessage,
            };
            // Strip trailing \r
            const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;

            if (trimmed.len == 0) break; // empty line = end of headers

            // Parse Content-Length header
            const prefix = "Content-Length: ";
            if (std.mem.startsWith(u8, trimmed, prefix)) {
                content_length = std.fmt.parseInt(usize, trimmed[prefix.len..], 10) catch return error.InvalidMessage;
            }
        }

        const length = content_length orelse return error.InvalidMessage;

        // Read body
        self.read_buf.clearRetainingCapacity();
        try self.read_buf.resize(self.allocator, length);
        self.reader.readNoEof(self.read_buf.items) catch return error.InvalidMessage;

        // Parse JSON
        return std.json.parseFromSlice(std.json.Value, self.allocator, self.read_buf.items, .{
            .allocate = .alloc_always,
        }) catch return error.InvalidMessage;
    }

    /// Write a JSON-RPC message to the transport.
    pub fn writeMessage(self: *Transport, json_bytes: []const u8) !void {
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{json_bytes.len}) catch unreachable;
        try self.writer.writeAll(header);
        try self.writer.writeAll(json_bytes);
    }
};

/// Per-document state: source text and latest parse results.
const Document = struct {
    source: []const u8,
    tokens: ?std.ArrayList(Token),
    tree: ?Ast,
    parser: ?Parser,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, source: []const u8) Document {
        const owned = allocator.dupe(u8, source) catch @panic("OOM");
        return .{
            .source = owned,
            .tokens = null,
            .tree = null,
            .parser = null,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Document) void {
        if (self.parser) |*p| p.deinit();
        if (self.tokens) |*t| t.deinit(self.allocator);
        self.allocator.free(self.source);
    }

    fn update(self: *Document, new_source: []const u8) void {
        // Clean up old parse results
        if (self.parser) |*p| p.deinit();
        if (self.tokens) |*t| t.deinit(self.allocator);
        self.parser = null;
        self.tokens = null;
        self.tree = null;
        self.allocator.free(self.source);
        self.source = self.allocator.dupe(u8, new_source) catch @panic("OOM");
    }

    fn ensureParsed(self: *Document) void {
        if (self.tree != null) return;

        var lexer = Lexer.init(self.source);
        self.tokens = lexer.tokenize(self.allocator) catch return;

        self.parser = Parser.init(self.allocator, self.tokens.?.items, self.source);
        _ = self.parser.?.parseFile() catch return;
        self.tree = self.parser.?.tree;
    }
};

/// The LSP server state.
pub const Server = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    documents: std.StringHashMap(Document),
    initialized: bool,
    shutdown_requested: bool,

    pub fn init(allocator: std.mem.Allocator, reader: std.io.AnyReader, writer: std.io.AnyWriter) Server {
        return .{
            .allocator = allocator,
            .transport = Transport.init(allocator, reader, writer),
            .documents = std.StringHashMap(Document).init(allocator),
            .initialized = false,
            .shutdown_requested = false,
        };
    }

    pub fn deinit(self: *Server) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.documents.deinit();
        self.transport.deinit();
    }

    /// Main loop: read messages and dispatch.
    pub fn run(self: *Server) !void {
        while (!self.shutdown_requested) {
            var msg = self.transport.readMessage() catch |err| switch (err) {
                error.EndOfStream => return,
                else => continue,
            };
            defer msg.deinit();

            self.handleMessage(msg.value) catch continue;
        }
    }

    fn handleMessage(self: *Server, msg: std.json.Value) !void {
        const obj = switch (msg) {
            .object => |o| o,
            else => return,
        };

        const method_val = obj.get("method") orelse return;
        const method = switch (method_val) {
            .string => |s| s,
            else => return,
        };

        const id = obj.get("id");
        const params = obj.get("params");

        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(id);
        } else if (std.mem.eql(u8, method, "initialized")) {
            self.initialized = true;
        } else if (std.mem.eql(u8, method, "shutdown")) {
            self.shutdown_requested = true;
            try self.sendResult(id, .null);
        } else if (std.mem.eql(u8, method, "exit")) {
            return;
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handleDidOpen(params);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.handleDidChange(params);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try self.handleDidClose(params);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.handleHover(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            try self.handleDefinition(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.handleCompletion(id, params);
        } else {
            // Unknown method — if it has an id, send method not found
            if (id != null) {
                try self.sendError(id, -32601, "Method not found");
            }
        }
    }

    fn handleInitialize(self: *Server, id: ?std.json.Value) !void {
        // Build capabilities response
        const response =
            \\{"capabilities":{"textDocumentSync":1,"hoverProvider":true,"definitionProvider":true,"completionProvider":{"triggerCharacters":["."]}}}
        ;

        try self.sendResultRaw(id, response);
    }

    fn handleDidOpen(self: *Server, params: ?std.json.Value) !void {
        const p = params orelse return;
        const td = getObject(p, "textDocument") orelse return;
        const uri = getString(td, "uri") orelse return;
        const text = getString(td, "text") orelse return;

        const uri_owned = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(uri_owned);

        var doc = Document.init(self.allocator, text);
        doc.ensureParsed();

        // Remove old entry if exists
        if (self.documents.fetchRemove(uri)) |old| {
            self.allocator.free(old.key);
            var old_doc = old.value;
            old_doc.deinit();
        }

        try self.documents.put(uri_owned, doc);
        try self.publishDiagnostics(uri, &self.documents.getPtr(uri_owned).?.*);
    }

    fn handleDidChange(self: *Server, params: ?std.json.Value) !void {
        const p = params orelse return;
        const td = getObject(p, "textDocument") orelse return;
        const uri = getString(td, "uri") orelse return;

        const changes = getArray(p, "contentChanges") orelse return;
        if (changes.len == 0) return;

        // Full sync: use last change's text
        const last_change = changes[changes.len - 1];
        const text = getString(last_change, "text") orelse return;

        if (self.documents.getPtr(uri)) |doc| {
            doc.update(text);
            doc.ensureParsed();
            try self.publishDiagnostics(uri, doc);
        }
    }

    fn handleDidClose(self: *Server, params: ?std.json.Value) !void {
        const p = params orelse return;
        const td = getObject(p, "textDocument") orelse return;
        const uri = getString(td, "uri") orelse return;

        if (self.documents.fetchRemove(uri)) |old| {
            self.allocator.free(old.key);
            var old_doc = old.value;
            old_doc.deinit();
        }

        // Clear diagnostics for closed document
        try self.publishDiagnosticsRaw(uri, "[]");
    }

    fn handleHover(self: *Server, id: ?std.json.Value, params: ?std.json.Value) !void {
        const p = params orelse return try self.sendResult(id, .null);
        const td = getObject(p, "textDocument") orelse return try self.sendResult(id, .null);
        const uri = getString(td, "uri") orelse return try self.sendResult(id, .null);
        const position = getObject(p, "position") orelse return try self.sendResult(id, .null);
        const line = getInt(position, "line") orelse return try self.sendResult(id, .null);
        const character = getInt(position, "character") orelse return try self.sendResult(id, .null);

        const doc = self.documents.getPtr(uri) orelse return try self.sendResult(id, .null);
        doc.ensureParsed();

        const tokens = if (doc.tokens) |t| t.items else return try self.sendResult(id, .null);

        // Convert line/character to byte offset
        const offset = lineColToOffset(doc.source, line, character) orelse return try self.sendResult(id, .null);

        // Find token at offset
        const tok_idx = findTokenAtOffset(tokens, offset) orelse return try self.sendResult(id, .null);
        const tok = tokens[tok_idx];

        // Generate hover content based on what we find
        const hover_text = self.getHoverInfo(doc, tokens, tok_idx) orelse return try self.sendResult(id, .null);

        // Build hover response
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        const start_loc = offsetToLineCol(doc.source, tok.loc.start);
        const end_loc = offsetToLineCol(doc.source, tok.loc.end);

        try writer.print(
            \\{{"contents":{{"kind":"markdown","value":"{s}"}},"range":{{"start":{{"line":{d},"character":{d}}},"end":{{"line":{d},"character":{d}}}}}}}
        , .{ hover_text, start_loc.line, start_loc.col, end_loc.line, end_loc.col });

        try self.sendResultRaw(id, buf.items);
    }

    fn handleDefinition(self: *Server, id: ?std.json.Value, params: ?std.json.Value) !void {
        const p = params orelse return try self.sendResult(id, .null);
        const td = getObject(p, "textDocument") orelse return try self.sendResult(id, .null);
        const uri = getString(td, "uri") orelse return try self.sendResult(id, .null);
        const position = getObject(p, "position") orelse return try self.sendResult(id, .null);
        const line = getInt(position, "line") orelse return try self.sendResult(id, .null);
        const character = getInt(position, "character") orelse return try self.sendResult(id, .null);

        const doc = self.documents.getPtr(uri) orelse return try self.sendResult(id, .null);
        doc.ensureParsed();

        const tokens = if (doc.tokens) |t| t.items else return try self.sendResult(id, .null);
        const tree = if (doc.tree) |t| t else return try self.sendResult(id, .null);

        const offset = lineColToOffset(doc.source, line, character) orelse return try self.sendResult(id, .null);
        const tok_idx = findTokenAtOffset(tokens, offset) orelse return try self.sendResult(id, .null);

        if (tokens[tok_idx].tag != .identifier) return try self.sendResult(id, .null);

        const name = tokens[tok_idx].slice(doc.source);

        // Search for definition in AST
        const def_tok = findDefinition(tree, tokens, name) orelse return try self.sendResult(id, .null);
        const def_loc = tokens[def_tok].loc;

        const start_loc = offsetToLineCol(doc.source, def_loc.start);
        const end_loc = offsetToLineCol(doc.source, def_loc.end);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        try writer.print(
            \\{{"uri":"{s}","range":{{"start":{{"line":{d},"character":{d}}},"end":{{"line":{d},"character":{d}}}}}}}
        , .{ uri, start_loc.line, start_loc.col, end_loc.line, end_loc.col });

        try self.sendResultRaw(id, buf.items);
    }

    fn handleCompletion(self: *Server, id: ?std.json.Value, params: ?std.json.Value) !void {
        const p = params orelse return try self.sendResult(id, .null);
        const td = getObject(p, "textDocument") orelse return try self.sendResultRaw(id, "[]");
        const uri = getString(td, "uri") orelse return try self.sendResultRaw(id, "[]");

        const doc = self.documents.getPtr(uri) orelse return try self.sendResultRaw(id, "[]");
        doc.ensureParsed();

        const tokens = if (doc.tokens) |t| t.items else return try self.sendResultRaw(id, "[]");
        const tree = if (doc.tree) |t| t else return try self.sendResultRaw(id, "[]");

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        try writer.writeAll("[");

        var first = true;

        // Add keywords
        const kw_list = [_][]const u8{
            "fn",        "pub",     "var",       "let",     "return",
            "if",        "else",    "for",       "in",      "switch",
            "break",     "continue", "defer",    "run",     "try",
            "package",   "use",     "struct",    "interface",
            "implements", "type",   "chan",       "map",     "alloc",
            "true",      "false",   "null",      "and",     "or",
            "not",
        };

        for (kw_list) |kw| {
            if (!first) try writer.writeAll(",");
            first = false;
            try writer.print(
                \\{{"label":"{s}","kind":14}}
            , .{kw});
        }

        // Add identifiers from the document (functions, variables, types)
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        for (tree.nodes.items, 0..) |node, i| {
            _ = i;
            const name_tok: ?u32 = switch (node.tag) {
                .fn_decl => blk: {
                    // Function name is token after 'fn'
                    if (node.main_token + 1 < tokens.len and tokens[node.main_token + 1].tag == .identifier) {
                        break :blk node.main_token + 1;
                    }
                    break :blk null;
                },
                .var_decl, .let_decl => blk: {
                    if (node.main_token + 1 < tokens.len and tokens[node.main_token + 1].tag == .identifier) {
                        break :blk node.main_token + 1;
                    }
                    break :blk null;
                },
                .short_var_decl => blk: {
                    if (tokens[node.main_token].tag == .identifier) {
                        break :blk node.main_token;
                    }
                    break :blk null;
                },
                .struct_decl => blk: {
                    if (tokens[node.main_token].tag == .identifier) {
                        break :blk node.main_token;
                    }
                    break :blk null;
                },
                .type_alias, .type_decl => blk: {
                    // type keyword followed by name
                    if (node.main_token + 1 < tokens.len and tokens[node.main_token + 1].tag == .identifier) {
                        break :blk node.main_token + 1;
                    }
                    break :blk null;
                },
                else => null,
            };

            if (name_tok) |nt| {
                const name = tokens[nt].slice(doc.source);
                if (!seen.contains(name)) {
                    try seen.put(name, {});
                    if (!first) try writer.writeAll(",");
                    first = false;

                    const kind: u8 = switch (node.tag) {
                        .fn_decl => 3, // Function
                        .var_decl, .let_decl, .short_var_decl => 6, // Variable
                        .struct_decl => 22, // Struct
                        .type_alias, .type_decl => 22, // Struct (used for types)
                        else => 1, // Text
                    };
                    try writer.print(
                        \\{{"label":"{s}","kind":{d}}}
                    , .{ name, kind });
                }
            }
        }

        try writer.writeAll("]");
        try self.sendResultRaw(id, buf.items);
    }

    fn publishDiagnostics(self: *Server, uri: []const u8, doc: *Document) !void {
        doc.ensureParsed();

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        try writer.writeAll("[");

        const tree = doc.tree orelse {
            try self.publishDiagnosticsRaw(uri, "[]");
            return;
        };

        var first = true;
        for (tree.errors.items) |err| {
            if (!first) try writer.writeAll(",");
            first = false;

            const start_loc = offsetToLineCol(doc.source, err.loc.start);
            const end_loc = offsetToLineCol(doc.source, err.loc.end);

            // Escape the tag name for JSON
            const msg = @tagName(err.tag);

            try writer.print(
                \\{{"range":{{"start":{{"line":{d},"character":{d}}},"end":{{"line":{d},"character":{d}}}}},"severity":1,"source":"run","message":"{s}"}}
            , .{ start_loc.line, start_loc.col, end_loc.line, end_loc.col, msg });
        }

        try writer.writeAll("]");
        try self.publishDiagnosticsRaw(uri, buf.items);
    }

    fn publishDiagnosticsRaw(self: *Server, uri: []const u8, diagnostics_json: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        try writer.print(
            \\{{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{{"uri":"{s}","diagnostics":{s}}}}}
        , .{ uri, diagnostics_json });

        try self.transport.writeMessage(buf.items);
    }

    fn getHoverInfo(self: *Server, doc: *Document, tokens: []const Token, tok_idx: usize) ?[]const u8 {
        _ = self;
        const tok = tokens[tok_idx];

        // For keywords, show keyword description
        if (tok.tag.isKeyword()) {
            return keywordDescription(tok.tag);
        }

        if (tok.tag != .identifier) return null;

        const name = tok.slice(doc.source);
        const tree = doc.tree orelse return null;

        // Search for the identifier's declaration in the AST
        for (tree.nodes.items) |node| {
            switch (node.tag) {
                .fn_decl => {
                    if (node.main_token + 1 < tokens.len and
                        tokens[node.main_token + 1].tag == .identifier and
                        std.mem.eql(u8, tokens[node.main_token + 1].slice(doc.source), name))
                    {
                        return "function";
                    }
                },
                .var_decl => {
                    if (node.main_token + 1 < tokens.len and
                        tokens[node.main_token + 1].tag == .identifier and
                        std.mem.eql(u8, tokens[node.main_token + 1].slice(doc.source), name))
                    {
                        return "var (mutable variable)";
                    }
                },
                .let_decl => {
                    if (node.main_token + 1 < tokens.len and
                        tokens[node.main_token + 1].tag == .identifier and
                        std.mem.eql(u8, tokens[node.main_token + 1].slice(doc.source), name))
                    {
                        return "let (immutable variable)";
                    }
                },
                .short_var_decl => {
                    if (tokens[node.main_token].tag == .identifier and
                        std.mem.eql(u8, tokens[node.main_token].slice(doc.source), name))
                    {
                        return "variable (short declaration)";
                    }
                },
                .struct_decl => {
                    if (tokens[node.main_token].tag == .identifier and
                        std.mem.eql(u8, tokens[node.main_token].slice(doc.source), name))
                    {
                        return "struct";
                    }
                },
                .interface_decl => {
                    if (node.main_token + 1 < tokens.len and
                        tokens[node.main_token + 1].tag == .identifier and
                        std.mem.eql(u8, tokens[node.main_token + 1].slice(doc.source), name))
                    {
                        return "interface";
                    }
                },
                .type_alias, .type_decl => {
                    if (node.main_token + 1 < tokens.len and
                        tokens[node.main_token + 1].tag == .identifier and
                        std.mem.eql(u8, tokens[node.main_token + 1].slice(doc.source), name))
                    {
                        return "type";
                    }
                },
                .param => {
                    if (tokens[node.main_token].tag == .identifier and
                        std.mem.eql(u8, tokens[node.main_token].slice(doc.source), name))
                    {
                        return "parameter";
                    }
                },
                else => {},
            }
        }

        return null;
    }

    // --- JSON-RPC response helpers ---

    fn sendResult(self: *Server, id: ?std.json.Value, result: std.json.Value) !void {
        _ = result;
        try self.sendResultRaw(id, "null");
    }

    fn sendResultRaw(self: *Server, id: ?std.json.Value, result_json: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        if (id) |id_val| {
            switch (id_val) {
                .integer => |n| try writer.print("{d}", .{n}),
                .string => |s| try writer.print("\"{s}\"", .{s}),
                else => try writer.writeAll("null"),
            }
        } else {
            try writer.writeAll("null");
        }
        try writer.print(",\"result\":{s}}}", .{result_json});

        try self.transport.writeMessage(buf.items);
    }

    fn sendError(self: *Server, id: ?std.json.Value, code: i32, message: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        if (id) |id_val| {
            switch (id_val) {
                .integer => |n| try writer.print("{d}", .{n}),
                .string => |s| try writer.print("\"{s}\"", .{s}),
                else => try writer.writeAll("null"),
            }
        } else {
            try writer.writeAll("null");
        }
        try writer.print(",\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ code, message });

        try self.transport.writeMessage(buf.items);
    }
};

// --- Utility functions ---

fn getObject(val: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (val) {
        .object => |obj| obj.get(key),
        else => null,
    };
}

fn getString(val: std.json.Value, key: []const u8) ?[]const u8 {
    const v = getObject(val, key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getInt(val: std.json.Value, key: []const u8) ?u32 {
    const v = getObject(val, key) orelse return null;
    return switch (v) {
        .integer => |n| @intCast(n),
        else => null,
    };
}

fn getArray(val: std.json.Value, key: []const u8) ?[]std.json.Value {
    const v = getObject(val, key) orelse return null;
    return switch (v) {
        .array => |a| a.items,
        else => null,
    };
}

/// Convert 0-based line/col to byte offset.
fn lineColToOffset(source: []const u8, line: u32, col: u32) ?u32 {
    var current_line: u32 = 0;
    var i: u32 = 0;
    while (i < source.len) : (i += 1) {
        if (current_line == line) {
            const result = i + col;
            return if (result <= source.len) result else null;
        }
        if (source[i] == '\n') {
            current_line += 1;
        }
    }
    if (current_line == line) {
        const result = i + col;
        return if (result <= source.len) result else null;
    }
    return null;
}

/// Convert byte offset to 0-based line/col.
fn offsetToLineCol(source: []const u8, byte_offset: u32) struct { line: u32, col: u32 } {
    var line: u32 = 0;
    var col: u32 = 0;
    const max: u32 = @intCast(@min(byte_offset, source.len));
    for (source[0..max]) |c| {
        if (c == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

/// Find the token at a given byte offset.
fn findTokenAtOffset(tokens: []const Token, offset: u32) ?usize {
    for (tokens, 0..) |tok, i| {
        if (tok.tag == .eof) break;
        if (tok.tag == .newline) continue;
        if (tok.loc.start <= offset and offset < tok.loc.end) {
            return i;
        }
    }
    return null;
}

/// Find the definition token for an identifier name in the AST.
fn findDefinition(tree: Ast, tokens: []const Token, name: []const u8) ?u32 {
    const source = tree.source;
    for (tree.nodes.items) |node| {
        switch (node.tag) {
            .fn_decl => {
                if (node.main_token + 1 < tokens.len and
                    tokens[node.main_token + 1].tag == .identifier and
                    std.mem.eql(u8, tokens[node.main_token + 1].slice(source), name))
                {
                    return node.main_token + 1;
                }
            },
            .var_decl, .let_decl => {
                if (node.main_token + 1 < tokens.len and
                    tokens[node.main_token + 1].tag == .identifier and
                    std.mem.eql(u8, tokens[node.main_token + 1].slice(source), name))
                {
                    return node.main_token + 1;
                }
            },
            .short_var_decl => {
                if (tokens[node.main_token].tag == .identifier and
                    std.mem.eql(u8, tokens[node.main_token].slice(source), name))
                {
                    return node.main_token;
                }
            },
            .struct_decl => {
                if (tokens[node.main_token].tag == .identifier and
                    std.mem.eql(u8, tokens[node.main_token].slice(source), name))
                {
                    return node.main_token;
                }
            },
            .interface_decl => {
                if (node.main_token + 1 < tokens.len and
                    tokens[node.main_token + 1].tag == .identifier and
                    std.mem.eql(u8, tokens[node.main_token + 1].slice(source), name))
                {
                    return node.main_token + 1;
                }
            },
            .type_alias, .type_decl => {
                if (node.main_token + 1 < tokens.len and
                    tokens[node.main_token + 1].tag == .identifier and
                    std.mem.eql(u8, tokens[node.main_token + 1].slice(source), name))
                {
                    return node.main_token + 1;
                }
            },
            .param => {
                if (tokens[node.main_token].tag == .identifier and
                    std.mem.eql(u8, tokens[node.main_token].slice(source), name))
                {
                    return node.main_token;
                }
            },
            .pub_decl => {
                // Check inner decl
                const inner_idx = node.data.lhs;
                if (inner_idx == null_node) continue;
                const inner = tree.nodes.items[inner_idx];
                switch (inner.tag) {
                    .fn_decl => {
                        if (inner.main_token + 1 < tokens.len and
                            tokens[inner.main_token + 1].tag == .identifier and
                            std.mem.eql(u8, tokens[inner.main_token + 1].slice(source), name))
                        {
                            return inner.main_token + 1;
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
    return null;
}

fn keywordDescription(tag: Token.Tag) []const u8 {
    return switch (tag) {
        .kw_fun => "fun — function declaration",
        .kw_pub => "pub — public visibility modifier",
        .kw_var => "var — mutable variable declaration",
        .kw_let => "let — immutable variable declaration",
        .kw_return => "return — return from function",
        .kw_if => "if — conditional expression/statement",
        .kw_else => "else — alternative branch",
        .kw_for => "for — loop statement",
        .kw_in => "in — iterator binding",
        .kw_switch => "switch — pattern matching",
        .kw_break => "break — exit loop",
        .kw_continue => "continue — skip to next iteration",
        .kw_defer => "defer — deferred execution",
        .kw_run => "run — spawn green thread",
        .kw_try => "try — error propagation",
        .kw_package => "package — package declaration",
        .kw_import => "use — import module",
        .kw_struct => "struct — struct type declaration",
        .kw_interface => "interface — interface declaration",
        .kw_implements => "implements — interface implementation",
        .kw_type => "type — type alias/declaration",
        .kw_chan => "chan — channel type",
        .kw_map => "map — map type",
        .kw_alloc => "alloc — heap allocation",
        .kw_true => "true — boolean literal",
        .kw_false => "false — boolean literal",
        .kw_null => "null — null literal",
        .kw_and => "and — logical AND",
        .kw_or => "or — logical OR",
        .kw_not => "not — logical NOT",
        else => "keyword",
    };
}

/// Entry point: run the LSP server on stdin/stdout.
pub fn serve(allocator: std.mem.Allocator) !void {
    const stdin = File.stdin().deprecatedReader();
    const stdout = File.stdout().deprecatedWriter();

    var server = Server.init(allocator, stdin.any(), stdout.any());
    defer server.deinit();

    try server.run();
}

// --- Tests ---

test "lineColToOffset: first line" {
    const source = "hello\nworld\n";
    try std.testing.expectEqual(@as(?u32, 0), lineColToOffset(source, 0, 0));
    try std.testing.expectEqual(@as(?u32, 3), lineColToOffset(source, 0, 3));
    try std.testing.expectEqual(@as(?u32, 6), lineColToOffset(source, 1, 0));
    try std.testing.expectEqual(@as(?u32, 9), lineColToOffset(source, 1, 3));
}

test "offsetToLineCol: basic" {
    const source = "hello\nworld\n";
    const loc0 = offsetToLineCol(source, 0);
    try std.testing.expectEqual(@as(u32, 0), loc0.line);
    try std.testing.expectEqual(@as(u32, 0), loc0.col);

    const loc6 = offsetToLineCol(source, 6);
    try std.testing.expectEqual(@as(u32, 1), loc6.line);
    try std.testing.expectEqual(@as(u32, 0), loc6.col);
}

test "findTokenAtOffset: finds identifier" {
    const source = "var x int";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    // 'x' starts at offset 4
    const idx = findTokenAtOffset(tokens.items, 4);
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(Token.Tag.identifier, tokens.items[idx.?].tag);
}

test "findTokenAtOffset: returns null for whitespace" {
    const source = "var  x";
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    // offset 4 is a space between 'var' and 'x'
    const idx = findTokenAtOffset(tokens.items, 4);
    try std.testing.expect(idx == null);
}

test "keywordDescription: returns descriptions" {
    const desc = keywordDescription(.kw_fun);
    try std.testing.expect(std.mem.indexOf(u8, desc, "function") != null);
}

test "Transport: writeMessage format" {
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(std.testing.allocator);

    var empty_buf: [0]u8 = .{};
    var empty_stream = std.io.fixedBufferStream(&empty_buf);

    var transport = Transport.init(
        std.testing.allocator,
        empty_stream.reader().any(),
        out_buf.writer(std.testing.allocator).any(),
    );
    defer transport.deinit();

    try transport.writeMessage("{\"test\":true}");

    const expected = "Content-Length: 13\r\n\r\n{\"test\":true}";
    try std.testing.expectEqualStrings(expected, out_buf.items);
}
