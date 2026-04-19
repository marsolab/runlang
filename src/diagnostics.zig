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

pub const AnnotationKind = enum {
    note,
    help,
    hint,
};

pub const Annotation = struct {
    kind: AnnotationKind,
    /// Byte offset in source. 0 with end_offset 0 means text-only (no source location).
    byte_offset: u32,
    end_offset: u32,
    message: []const u8,
};

pub const Diagnostic = struct {
    severity: Severity,
    byte_offset: u32,
    end_offset: u32,
    message: []const u8,
    /// Optional shorter label for the caret line. If null, message is used.
    label: ?[]const u8 = null,
    /// Chained annotations (notes, help, hints) rendered after this diagnostic.
    annotations: []const Annotation = &.{},
};

pub const DiagnosticList = struct {
    diagnostics: std.ArrayList(Diagnostic),
    allocated_messages: std.ArrayList([]const u8),
    allocated_annotations: std.ArrayList([]const Annotation),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DiagnosticList {
        return .{
            .diagnostics = .empty,
            .allocated_messages = .empty,
            .allocated_annotations = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DiagnosticList) void {
        for (self.allocated_messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.allocated_messages.deinit(self.allocator);
        for (self.allocated_annotations.items) |ann| {
            self.allocator.free(ann);
        }
        self.allocated_annotations.deinit(self.allocator);
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

    pub fn addErrorWithLabel(self: *DiagnosticList, byte_offset: u32, end_offset: u32, message: []const u8, label: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .severity = .@"error",
            .byte_offset = byte_offset,
            .end_offset = end_offset,
            .message = message,
            .label = label,
        });
    }

    pub fn addErrorAnnotated(
        self: *DiagnosticList,
        byte_offset: u32,
        end_offset: u32,
        message: []const u8,
        label: ?[]const u8,
        annotations: []const Annotation,
    ) !void {
        const owned = try self.allocator.dupe(Annotation, annotations);
        errdefer self.allocator.free(owned);
        try self.allocated_annotations.append(self.allocator, owned);
        try self.diagnostics.append(self.allocator, .{
            .severity = .@"error",
            .byte_offset = byte_offset,
            .end_offset = end_offset,
            .message = message,
            .label = label,
            .annotations = owned,
        });
    }

    pub fn addErrorAnnotatedFmt(
        self: *DiagnosticList,
        byte_offset: u32,
        end_offset: u32,
        comptime fmt: []const u8,
        args: anytype,
        label: ?[]const u8,
        annotations: []const Annotation,
    ) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(msg);
        try self.allocated_messages.append(self.allocator, msg);
        const owned = try self.allocator.dupe(Annotation, annotations);
        errdefer self.allocator.free(owned);
        try self.allocated_annotations.append(self.allocator, owned);
        try self.diagnostics.append(self.allocator, .{
            .severity = .@"error",
            .byte_offset = byte_offset,
            .end_offset = end_offset,
            .message = msg,
            .label = label,
            .annotations = owned,
        });
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
    const caret_label = d.label orelse d.message;
    try writer.print(" {s}{s}\n", .{ caret_label, reset });

    // Line 6: empty gutter (trailing separator)
    try writeSpaces(writer, gutter_width + 1);
    try writer.print("{s}|{s}\n", .{ cyan, reset });

    // Render chained annotations (notes, help, hints)
    for (d.annotations) |ann| {
        const ann_kind_str = switch (ann.kind) {
            .note => "note",
            .help => "help",
            .hint => "hint",
        };
        const ann_color = if (use_color) switch (ann.kind) {
            .note => Color.blue,
            .help => Color.cyan,
            .hint => Color.cyan,
        } else "";

        if (ann.byte_offset == 0 and ann.end_offset == 0) {
            // Text-only annotation (no source location)
            try writeSpaces(writer, gutter_width + 1);
            try writer.print("{s}={s} {s}{s}{s}: {s}\n", .{
                cyan, reset, ann_color, ann_kind_str, reset, ann.message,
            });
        } else {
            // Annotation with source location
            const ann_src = getSourceLine(source, ann.byte_offset);
            const ann_col = ann_src.col - 1;
            const ann_span = blk: {
                if (ann.end_offset > ann.byte_offset) {
                    const raw = ann.end_offset - ann.byte_offset;
                    const remaining = ann_src.text.len - @min(ann_col, ann_src.text.len);
                    break :blk @min(raw, remaining);
                }
                break :blk @as(usize, 1);
            };

            // Show annotation with source context
            try writeSpaces(writer, gutter_width + 1);
            try writer.print("{s}={s} {s}{s}{s}: {s}\n", .{
                cyan, reset, ann_color, ann_kind_str, reset, ann.message,
            });
            try writer.print(" {s}-->{s} {s}:{d}:{d}\n", .{
                cyan, reset, file_path, ann_src.line_number, ann_src.col,
            });
            try writeSpaces(writer, gutter_width + 1);
            try writer.print("{s}|{s}\n", .{ cyan, reset });
            try writer.print("{s}{d}{s} {s}|{s} {s}\n", .{
                bold, ann_src.line_number, reset, cyan, reset, ann_src.text,
            });
            try writeSpaces(writer, gutter_width + 1);
            try writer.print("{s}|{s} ", .{ cyan, reset });
            try writeSpaces(writer, ann_col);
            try writer.writeAll(ann_color);
            try writeChars(writer, '-', if (ann_span == 0) 1 else ann_span);
            try writer.print(" {s}{s}\n", .{ ann.message, reset });
            try writeSpaces(writer, gutter_width + 1);
            try writer.print("{s}|{s}\n", .{ cyan, reset });
        }
    }
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

/// Compute Levenshtein edit distance between two strings.
/// Uses a stack-allocated buffer for strings up to 64 chars; returns null for longer strings.
pub fn editDistance(a: []const u8, b: []const u8) ?u32 {
    const max_len = 64;
    if (a.len > max_len or b.len > max_len) return null;

    var prev_row: [max_len + 1]u32 = undefined;
    var curr_row: [max_len + 1]u32 = undefined;

    for (0..b.len + 1) |j| {
        prev_row[j] = @intCast(j);
    }

    for (a, 0..) |ca, i| {
        curr_row[0] = @intCast(i + 1);
        for (b, 0..) |cb, j| {
            const cost: u32 = if (ca == cb) 0 else 1;
            curr_row[j + 1] = @min(@min(
                curr_row[j] + 1, // insertion
                prev_row[j + 1] + 1, // deletion
            ), prev_row[j] + cost); // substitution
        }
        @memcpy(prev_row[0 .. b.len + 1], curr_row[0 .. b.len + 1]);
    }

    return prev_row[b.len];
}

/// Find the closest match to `needle` in `haystack` within `max_distance`.
/// Returns the best match, or null if none is close enough.
pub fn findClosestMatch(needle: []const u8, haystack: []const []const u8, max_distance: u32) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: u32 = max_distance + 1;

    for (haystack) |candidate| {
        if (editDistance(needle, candidate)) |dist| {
            if (dist < best_dist) {
                best_dist = dist;
                best = candidate;
            }
        }
    }

    return best;
}

// Tests

test "editDistance: identical strings" {
    try std.testing.expectEqual(@as(?u32, 0), editDistance("hello", "hello"));
}

test "editDistance: single substitution" {
    try std.testing.expectEqual(@as(?u32, 1), editDistance("hello", "hallo"));
}

test "editDistance: single insertion" {
    try std.testing.expectEqual(@as(?u32, 1), editDistance("hell", "hello"));
}

test "editDistance: single deletion" {
    try std.testing.expectEqual(@as(?u32, 1), editDistance("hello", "hell"));
}

test "editDistance: transposition" {
    try std.testing.expectEqual(@as(?u32, 2), editDistance("pirntln", "println"));
}

test "findClosestMatch: finds closest" {
    const haystack = [_][]const u8{ "println", "print", "printf" };
    const result = findClosestMatch("pirntln", &haystack, 2);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("println", result.?);
}

test "findClosestMatch: no match within distance" {
    const haystack = [_][]const u8{ "completely", "different" };
    const result = findClosestMatch("println", &haystack, 2);
    try std.testing.expect(result == null);
}

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

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try diags.render(source, &writer.writer);

    const expected =
        "error[1:5]: undefined variable 'x'\n" ++
        "warning[2:5]: unused variable 'y'\n";
    try std.testing.expectEqualStrings(expected, writer.writer.buffered());
}

test "DiagnosticList: render empty list" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try diags.render("", &writer.writer);
    try std.testing.expectEqual(@as(usize, 0), writer.writer.buffered().len);
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

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try diags.renderRich(source, "test.run", &writer.writer, false);

    const expected =
        "error: type mismatch\n" ++
        " --> test.run:1:13\n" ++
        "  |\n" ++
        "1 | var x i32 = \"hello\"\n" ++
        "  |             ^^^^^^^ type mismatch\n" ++
        "  |\n";
    try std.testing.expectEqualStrings(expected, writer.writer.buffered());
}

test "renderRich: warning on second line" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    const source = "var x int\nvar y int";
    try diags.addWarning(14, 15, "unused variable 'y'");

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try diags.renderRich(source, "main.run", &writer.writer, false);

    const expected =
        "warning: unused variable 'y'\n" ++
        " --> main.run:2:5\n" ++
        "  |\n" ++
        "2 | var y int\n" ++
        "  |     ^ unused variable 'y'\n" ++
        "  |\n";
    try std.testing.expectEqualStrings(expected, writer.writer.buffered());
}

test "renderRich: multiple diagnostics" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    const source = "var x int\nvar y int";
    try diags.addError(4, 5, "error here");
    try diags.addWarning(14, 15, "warning here");

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try diags.renderRich(source, "test.run", &writer.writer, false);

    // Just check that both are present
    try std.testing.expect(std.mem.indexOf(u8, writer.writer.buffered(), "error: error here") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.writer.buffered(), "warning: warning here") != null);
}

test "renderRich: error with label shows label on caret line" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    const source = "var x i32 = \"hello\"";
    try diags.addErrorWithLabel(12, 19, "type mismatch: expected 'i32', got 'string'", "expected 'i32'");

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try diags.renderRich(source, "test.run", &writer.writer, false);

    // Header should have full message
    try std.testing.expect(std.mem.indexOf(u8, writer.writer.buffered(), "error: type mismatch: expected 'i32', got 'string'") != null);
    // Caret line should have short label, not full message
    try std.testing.expect(std.mem.indexOf(u8, writer.writer.buffered(), "^^^^^^^ expected 'i32'\n") != null);
}

test "renderRich: error with text-only annotation" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    const source = "let x = pirntln()";
    const annotations = [_]Annotation{
        .{ .kind = .help, .byte_offset = 0, .end_offset = 0, .message = "did you mean 'println'?" },
    };
    try diags.addErrorAnnotated(8, 15, "undefined reference to 'pirntln'", "not found in this scope", &annotations);

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try diags.renderRich(source, "test.run", &writer.writer, false);

    try std.testing.expect(std.mem.indexOf(u8, writer.writer.buffered(), "error: undefined reference to 'pirntln'") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.writer.buffered(), "^^^^^^^ not found in this scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.writer.buffered(), "= help: did you mean 'println'?") != null);
}

test "renderRich: error with note annotation" {
    var diags = DiagnosticList.init(std.testing.allocator);
    defer diags.deinit();

    const source = "var x i32 = \"hello\"";
    const annotations = [_]Annotation{
        .{ .kind = .note, .byte_offset = 0, .end_offset = 0, .message = "string literals have type 'string'" },
    };
    try diags.addErrorAnnotated(12, 19, "type mismatch", null, &annotations);

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try diags.renderRich(source, "test.run", &writer.writer, false);

    try std.testing.expect(std.mem.indexOf(u8, writer.writer.buffered(), "= note: string literals have type 'string'") != null);
}

test "digitCount" {
    try std.testing.expectEqual(@as(usize, 1), digitCount(0));
    try std.testing.expectEqual(@as(usize, 1), digitCount(1));
    try std.testing.expectEqual(@as(usize, 1), digitCount(9));
    try std.testing.expectEqual(@as(usize, 2), digitCount(10));
    try std.testing.expectEqual(@as(usize, 3), digitCount(100));
}
