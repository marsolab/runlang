const std = @import("std");

pub const Severity = enum {
    @"error",
    warning,
    note,
};

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
};

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
