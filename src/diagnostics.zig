const std = @import("std");

pub const Severity = enum {
    @"error",
    warning,
    note,
};

/// ANSI color codes for terminal output.
pub const Color = struct {
    pub const red = "\x1b[1;31m";
    pub const yellow = "\x1b[1;33m";
    pub const blue = "\x1b[1;34m";
    pub const cyan = "\x1b[1;36m";
    pub const bold = "\x1b[1m";
    pub const reset = "\x1b[0m";
};

/// Information about a source line extracted from a byte offset.
pub const SourceLine = struct {
    /// The text of the line (without trailing newline).
    text: []const u8,
    /// 1-based line number.
    line_number: u32,
    /// 1-based column of the byte_offset within the line.
    col: u32,
    /// Byte offset of the start of this line in the source.
    line_start: u32,
};

/// Given source bytes and a byte_offset, return the full line text,
/// line number, column, and line start offset.
pub fn getSourceLine(source: []const u8, byte_offset: u32) SourceLine {
    const offset: usize = @min(byte_offset, source.len);

    // Find start of line
    var line_start: usize = 0;
    var line_number: u32 = 1;
    for (source[0..offset], 0..) |c, i| {
        if (c == '\n') {
            line_start = i + 1;
            line_number += 1;
        }
    }

    // Find end of line
    var line_end: usize = offset;
    while (line_end < source.len and source[line_end] != '\n') {
        line_end += 1;
    }

    const col: u32 = @intCast(offset - line_start + 1);

    return .{
        .text = source[line_start..line_end],
        .line_number = line_number,
        .col = col,
        .line_start = @intCast(line_start),
    };
}

pub const Diagnostic = struct {
    severity: Severity,
    byte_offset: u32,
    end_offset: u32,
    message: []const u8,
};

pub const DiagnosticList = struct {
    diagnostics: std.ArrayList(Diagnostic),
    allocated_messages: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DiagnosticList {
        return .{
            .diagnostics = .empty,
            .allocated_messages = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DiagnosticList) void {
        for (self.allocated_messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.allocated_messages.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
    }

    pub fn addError(self: *DiagnosticList, byte_offset: u32, end_offset: u32, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .severity = .@"error",
            .byte_offset = byte_offset,
            .end_offset = end_offset,
            .message = message,
        });
    }

    pub fn addWarning(self: *DiagnosticList, byte_offset: u32, end_offset: u32, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .severity = .warning,
            .byte_offset = byte_offset,
            .end_offset = end_offset,
            .message = message,
        });
    }

    pub fn addNote(self: *DiagnosticList, byte_offset: u32, end_offset: u32, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .severity = .note,
            .byte_offset = byte_offset,
            .end_offset = end_offset,
            .message = message,
        });
    }

    pub fn addErrorFmt(self: *DiagnosticList, byte_offset: u32, end_offset: u32, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(msg);
        try self.allocated_messages.append(self.allocator, msg);
        try self.addError(byte_offset, end_offset, msg);
    }

    pub fn addWarningFmt(self: *DiagnosticList, byte_offset: u32, end_offset: u32, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(msg);
        try self.allocated_messages.append(self.allocator, msg);
        try self.addWarning(byte_offset, end_offset, msg);
    }

    pub fn hasErrors(self: *const DiagnosticList) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    pub fn render(self: *const DiagnosticList, source: []const u8, writer: anytype) !void {
        for (self.diagnostics.items) |d| {
            const loc = computeLineCol(source, d.byte_offset);
            const severity_str = switch (d.severity) {
                .@"error" => "error",
                .warning => "warning",
                .note => "note",
            };
            try writer.print("{s}[{d}:{d}]: {s}\n", .{ severity_str, loc.line, loc.col, d.message });
        }
    }

    /// Render diagnostics with source context, carets, and optional color.
    pub fn renderRich(
        self: *const DiagnosticList,
        source: []const u8,
        file_path: []const u8,
        writer: anytype,
        use_color: bool,
    ) !void {
        for (self.diagnostics.items) |d| {
            try renderOneDiagnostic(d, source, file_path, writer, use_color);
        }
    }
};

/// Render a single diagnostic with source context and carets.
pub fn renderOneDiagnostic(d: Diagnostic, source: []const u8, file_path: []const u8, writer: anytype, use_color: bool) !void {
    const src_line = getSourceLine(source, d.byte_offset);

    // Severity header with color
    const sev_color = if (use_color) switch (d.severity) {
        .@"error" => Color.red,
        .warning => Color.yellow,
        .note => Color.blue,
    } else "";
    const reset = if (use_color) Color.reset else "";
    const bold = if (use_color) Color.bold else "";
    const cyan = if (use_color) Color.cyan else "";

    const severity_str = switch (d.severity) {
        .@"error" => "error",
        .warning => "warning",
        .note => "note",
    };

    // Line 1: severity: message
    try writer.print("{s}{s}{s}: {s}{s}{s}\n", .{
        sev_color, severity_str, reset,
        bold,      d.message,    reset,
    });

    // Line 2: --> file:line:col
    try writer.print(" {s}-->{s} {s}:{d}:{d}\n", .{
        cyan, reset, file_path, src_line.line_number, src_line.col,
    });

    // Compute gutter width for line number
    const line_num = src_line.line_number;
    const gutter_width = digitCount(line_num);

    // Line 3: empty gutter
    try writeSpaces(writer, gutter_width + 1);
    try writer.print("{s}|{s}\n", .{ cyan, reset });

    // Line 4: line number | source line
    try writer.print("{s}{d}{s} {s}|{s} {s}\n", .{
        bold, line_num, reset, cyan, reset, src_line.text,
    });

    // Line 5: caret line
    const col_offset = src_line.col - 1; // 0-based
    const span_len = blk: {
        if (d.end_offset > d.byte_offset) {
            const raw = d.end_offset - d.byte_offset;
            // Clamp to current line length
            const remaining = src_line.text.len - @min(col_offset, src_line.text.len);
            break :blk @min(raw, remaining);
        }
        break :blk @as(usize, 1);
    };

    try writeSpaces(writer, gutter_width + 1);
    try writer.print("{s}|{s} ", .{ cyan, reset });
    try writeSpaces(writer, col_offset);
    try writer.writeAll(sev_color);
    try writeChars(writer, '^', if (span_len == 0) 1 else span_len);
    try writer.print(" {s}{s}\n", .{ d.message, reset });

    // Line 6: empty gutter (trailing separator)
    try writeSpaces(writer, gutter_width + 1);
    try writer.print("{s}|{s}\n", .{ cyan, reset });
}

fn writeSpaces(writer: anytype, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.writeByte(' ');
    }
}

fn writeChars(writer: anytype, ch: u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.writeByte(ch);
    }
}

fn digitCount(n: u32) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        count += 1;
    }
    return count;
}

pub fn computeLineCol(source: []const u8, byte_offset: u32) struct { line: u32, col: u32 } {
    var line: u32 = 1;
    var col: u32 = 1;
    const offset: usize = @min(byte_offset, @as(u32, @intCast(source.len)));
    for (source[0..offset]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

// Tests

test "computeLineCol: first character" {
    const source = "hello\nworld";
    const loc = computeLineCol(source, 0);
    try std.testing.expectEqual(@as(u32, 1), loc.line);
    try std.testing.expectEqual(@as(u32, 1), loc.col);
}

test "computeLineCol: same line offset" {
    const source = "hello\nworld";
    const loc = computeLineCol(source, 3);
    try std.testing.expectEqual(@as(u32, 1), loc.line);
    try std.testing.expectEqual(@as(u32, 4), loc.col);
}

test "computeLineCol: second line" {
    const source = "hello\nworld";
    const loc = computeLineCol(source, 6);
    try std.testing.expectEqual(@as(u32, 2), loc.line);
    try std.testing.expectEqual(@as(u32, 1), loc.col);
}

test "computeLineCol: third line" {
    const source = "line1\nline2\nline3";
    const loc = computeLineCol(source, 14);
    try std.testing.expectEqual(@as(u32, 3), loc.line);
    try std.testing.expectEqual(@as(u32, 3), loc.col);
}

test "computeLineCol: offset beyond source" {
    const source = "ab";
    const loc = computeLineCol(source, 100);
    try std.testing.expectEqual(@as(u32, 1), loc.line);
    try std.testing.expectEqual(@as(u32, 3), loc.col);
}

test "DiagnosticList: addError and hasErrors" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    try std.testing.expect(!diags.hasErrors());

    try diags.addError(0, 5, "test error");
    try std.testing.expect(diags.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), diags.diagnostics.items.len);
    try std.testing.expectEqual(Severity.@"error", diags.diagnostics.items[0].severity);
}

test "DiagnosticList: addWarning does not count as error" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    try diags.addWarning(0, 5, "test warning");
    try std.testing.expect(!diags.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), diags.diagnostics.items.len);
    try std.testing.expectEqual(Severity.warning, diags.diagnostics.items[0].severity);
}

test "DiagnosticList: addNote" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    try diags.addNote(10, 15, "additional context");
    try std.testing.expect(!diags.hasErrors());
    try std.testing.expectEqual(Severity.note, diags.diagnostics.items[0].severity);
}

test "DiagnosticList: addErrorFmt formats message" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    try diags.addErrorFmt(10, 15, "undefined variable '{s}'", .{"x"});
    try std.testing.expect(diags.hasErrors());
    try std.testing.expectEqualStrings("undefined variable 'x'", diags.diagnostics.items[0].message);
}

test "DiagnosticList: addWarningFmt formats message" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    try diags.addWarningFmt(0, 1, "unused variable '{s}'", .{"y"});
    try std.testing.expect(!diags.hasErrors());
    try std.testing.expectEqualStrings("unused variable 'y'", diags.diagnostics.items[0].message);
}

test "DiagnosticList: render output format" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    const source = "var x int\nvar y int\n";
    //                0123456789 0123456789

    try diags.addError(4, 5, "undefined variable 'x'");
    try diags.addWarning(14, 15, "unused variable 'y'");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const writer = buf.writer(std.testing.allocator);

    try diags.render(source, writer);

    const expected =
        "error[1:5]: undefined variable 'x'\n" ++
        "warning[2:5]: unused variable 'y'\n";
    try std.testing.expectEqualStrings(expected, buf.items);
}

test "DiagnosticList: render empty list" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const writer = buf.writer(std.testing.allocator);

    try diags.render("", writer);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "DiagnosticList: multiple errors and warnings" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    try diags.addWarning(0, 1, "warning1");
    try std.testing.expect(!diags.hasErrors());

    try diags.addWarning(2, 3, "warning2");
    try std.testing.expect(!diags.hasErrors());

    try diags.addError(4, 5, "error1");
    try std.testing.expect(diags.hasErrors());

    try std.testing.expectEqual(@as(usize, 3), diags.diagnostics.items.len);
}

// Tests for getSourceLine

test "getSourceLine: first line" {
    const source = "hello world\nsecond line";
    const sl = getSourceLine(source, 6);
    try std.testing.expectEqualStrings("hello world", sl.text);
    try std.testing.expectEqual(@as(u32, 1), sl.line_number);
    try std.testing.expectEqual(@as(u32, 7), sl.col);
    try std.testing.expectEqual(@as(u32, 0), sl.line_start);
}

test "getSourceLine: second line" {
    const source = "hello\nworld";
    const sl = getSourceLine(source, 6);
    try std.testing.expectEqualStrings("world", sl.text);
    try std.testing.expectEqual(@as(u32, 2), sl.line_number);
    try std.testing.expectEqual(@as(u32, 1), sl.col);
    try std.testing.expectEqual(@as(u32, 6), sl.line_start);
}

test "getSourceLine: offset at start" {
    const source = "abc";
    const sl = getSourceLine(source, 0);
    try std.testing.expectEqualStrings("abc", sl.text);
    try std.testing.expectEqual(@as(u32, 1), sl.line_number);
    try std.testing.expectEqual(@as(u32, 1), sl.col);
}

test "getSourceLine: offset at end" {
    const source = "abc\ndef";
    const sl = getSourceLine(source, 6);
    try std.testing.expectEqualStrings("def", sl.text);
    try std.testing.expectEqual(@as(u32, 2), sl.line_number);
    try std.testing.expectEqual(@as(u32, 3), sl.col);
}

// Tests for renderRich (no color for testability)

test "renderRich: single error with source context" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    const source = "var x i32 = \"hello\"";
    try diags.addError(12, 19, "type mismatch");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const writer = buf.writer(std.testing.allocator);

    try diags.renderRich(source, "test.run", writer, false);

    const expected =
        "error: type mismatch\n" ++
        " --> test.run:1:13\n" ++
        "  |\n" ++
        "1 | var x i32 = \"hello\"\n" ++
        "  |             ^^^^^^^ type mismatch\n" ++
        "  |\n";
    try std.testing.expectEqualStrings(expected, buf.items);
}

test "renderRich: warning on second line" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    const source = "var x int\nvar y int";
    try diags.addWarning(14, 15, "unused variable 'y'");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const writer = buf.writer(std.testing.allocator);

    try diags.renderRich(source, "main.run", writer, false);

    const expected =
        "warning: unused variable 'y'\n" ++
        " --> main.run:2:5\n" ++
        "  |\n" ++
        "2 | var y int\n" ++
        "  |     ^ unused variable 'y'\n" ++
        "  |\n";
    try std.testing.expectEqualStrings(expected, buf.items);
}

test "renderRich: multiple diagnostics" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    const source = "var x int\nvar y int";
    try diags.addError(4, 5, "error here");
    try diags.addWarning(14, 15, "warning here");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const writer = buf.writer(std.testing.allocator);

    try diags.renderRich(source, "test.run", writer, false);

    // Just check that both are present
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "error: error here") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "warning: warning here") != null);
}

test "digitCount" {
    try std.testing.expectEqual(@as(usize, 1), digitCount(0));
    try std.testing.expectEqual(@as(usize, 1), digitCount(1));
    try std.testing.expectEqual(@as(usize, 1), digitCount(9));
    try std.testing.expectEqual(@as(usize, 2), digitCount(10));
    try std.testing.expectEqual(@as(usize, 3), digitCount(100));
}
