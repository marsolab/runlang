const std = @import("std");

/// GDB Machine Interface (MI) client.
///
/// Manages a GDB subprocess and provides structured access to its MI protocol.
/// GDB/MI uses line-oriented text records with a well-defined grammar:
///   - Result records:  ^done,key=value,...
///   - Async exec:      *stopped,reason="breakpoint-hit",...
///   - Console output:  ~"text"
///   - Target output:   @"text"
///   - Log output:      &"text"
pub const GdbMi = struct {
    process: std.process.Child,
    stdout_reader: std.io.AnyReader,
    stdin_writer: std.io.AnyWriter,
    allocator: std.mem.Allocator,
    next_token: u32,
    read_buf: std.ArrayList(u8),
    line_buf: [4096]u8,

    pub fn init(allocator: std.mem.Allocator, binary_path: []const u8) !GdbMi {
        var child = std.process.Child.init(
            &.{ "gdb", "--interpreter=mi3", "--quiet", binary_path },
            allocator,
        );
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        return .{
            .process = child,
            .stdout_reader = child.stdout.?.deprecatedReader().any(),
            .stdin_writer = child.stdin.?.deprecatedWriter().any(),
            .allocator = allocator,
            .next_token = 1,
            .read_buf = .empty,
            .line_buf = undefined,
        };
    }

    pub fn deinit(self: *GdbMi) void {
        self.read_buf.deinit(self.allocator);
        // Send quit command, ignore errors
        self.stdin_writer.writeAll("-gdb-exit\n") catch {};
        _ = self.process.wait() catch {};
    }

    /// Send a GDB/MI command and wait for the result record.
    /// Returns the parsed response. Async events (stopped, etc.) are collected.
    pub fn sendCommand(self: *GdbMi, command: []const u8) !MiResponse {
        const token = self.next_token;
        self.next_token += 1;

        // Send tokenized command: "TOKEN-command\n"
        var cmd_buf: [4096]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "{d}{s}\n", .{ token, command }) catch
            return error.CommandTooLong;
        try self.stdin_writer.writeAll(cmd);

        // Read responses until we get a result record with our token
        while (true) {
            const response = try self.readResponse();
            switch (response.record_type) {
                .result => {
                    // Check if this result matches our token
                    if (response.token == token or response.token == 0) {
                        return response;
                    }
                },
                .exec_async, .notify_async, .status_async => {
                    // Store for later retrieval
                    continue;
                },
                .console, .target, .log => continue,
                .prompt => continue,
            }
        }
    }

    /// Send a raw command without token prefix.
    pub fn sendRaw(self: *GdbMi, command: []const u8) !void {
        try self.stdin_writer.writeAll(command);
        try self.stdin_writer.writeAll("\n");
    }

    /// Read lines until we get a complete GDB/MI response.
    pub fn readResponse(self: *GdbMi) !MiResponse {
        while (true) {
            const line = self.stdout_reader.readUntilDelimiter(&self.line_buf, '\n') catch |err| switch (err) {
                error.EndOfStream => return error.GdbExited,
                else => return error.ReadFailed,
            };

            // Strip trailing \r
            const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;

            if (trimmed.len == 0) continue;

            return parseMiRecord(trimmed);
        }
    }

    /// Wait for an async exec record (e.g., *stopped).
    pub fn waitForStop(self: *GdbMi) !MiResponse {
        while (true) {
            const response = try self.readResponse();
            if (response.record_type == .exec_async) {
                return response;
            }
        }
    }
};

/// Types of GDB/MI output records.
pub const RecordType = enum {
    result, // ^done, ^running, ^error, ^connected, ^exit
    exec_async, // *stopped, *running
    status_async, // +download
    notify_async, // =thread-created, =breakpoint-modified
    console, // ~"text"
    target, // @"text"
    log, // &"text"
    prompt, // (gdb)
};

/// Result class from a GDB/MI result record.
pub const ResultClass = enum {
    done,
    running,
    connected,
    @"error",
    exit,
    unknown,
};

/// Parsed GDB/MI response.
pub const MiResponse = struct {
    record_type: RecordType,
    result_class: ResultClass,
    token: u32,
    /// The raw text content after the record prefix.
    /// For result records: "key=value,..." portion.
    /// For stream records: the quoted text content.
    content: []const u8,
};

/// Parse a single GDB/MI output line into an MiResponse.
fn parseMiRecord(line: []const u8) MiResponse {
    if (line.len == 0) return .{
        .record_type = .prompt,
        .result_class = .unknown,
        .token = 0,
        .content = "",
    };

    // Check for (gdb) prompt
    if (std.mem.startsWith(u8, line, "(gdb)")) {
        return .{
            .record_type = .prompt,
            .result_class = .unknown,
            .token = 0,
            .content = "",
        };
    }

    // Parse optional token prefix (digits)
    var pos: usize = 0;
    var token: u32 = 0;
    while (pos < line.len and line[pos] >= '0' and line[pos] <= '9') {
        token = token * 10 + @as(u32, line[pos] - '0');
        pos += 1;
    }

    if (pos >= line.len) return .{
        .record_type = .prompt,
        .result_class = .unknown,
        .token = 0,
        .content = line,
    };

    const prefix = line[pos];
    const rest = if (pos + 1 < line.len) line[pos + 1 ..] else "";

    return switch (prefix) {
        '^' => .{
            .record_type = .result,
            .result_class = parseResultClass(rest),
            .token = token,
            .content = rest,
        },
        '*' => .{
            .record_type = .exec_async,
            .result_class = .unknown,
            .token = token,
            .content = rest,
        },
        '+' => .{
            .record_type = .status_async,
            .result_class = .unknown,
            .token = token,
            .content = rest,
        },
        '=' => .{
            .record_type = .notify_async,
            .result_class = .unknown,
            .token = token,
            .content = rest,
        },
        '~' => .{
            .record_type = .console,
            .result_class = .unknown,
            .token = 0,
            .content = unquote(rest),
        },
        '@' => .{
            .record_type = .target,
            .result_class = .unknown,
            .token = 0,
            .content = unquote(rest),
        },
        '&' => .{
            .record_type = .log,
            .result_class = .unknown,
            .token = 0,
            .content = unquote(rest),
        },
        else => .{
            .record_type = .console,
            .result_class = .unknown,
            .token = 0,
            .content = line,
        },
    };
}

fn parseResultClass(content: []const u8) ResultClass {
    if (std.mem.startsWith(u8, content, "done")) return .done;
    if (std.mem.startsWith(u8, content, "running")) return .running;
    if (std.mem.startsWith(u8, content, "connected")) return .connected;
    if (std.mem.startsWith(u8, content, "error")) return .@"error";
    if (std.mem.startsWith(u8, content, "exit")) return .exit;
    return .unknown;
}

/// Strip surrounding quotes from a GDB/MI string value.
fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

/// Extract a named value from a GDB/MI key=value record.
/// For example, from 'reason="breakpoint-hit",frame={...}' extract "breakpoint-hit" for key "reason".
pub fn extractValue(content: []const u8, key: []const u8) ?[]const u8 {
    // Search for key="value" pattern
    var pos: usize = 0;
    while (pos + key.len + 1 < content.len) {
        if (std.mem.startsWith(u8, content[pos..], key) and
            content[pos + key.len] == '=')
        {
            const val_start = pos + key.len + 1;
            if (content[val_start] == '"') {
                // Quoted value — find closing quote (handle escaped quotes)
                var end = val_start + 1;
                while (end < content.len) {
                    if (content[end] == '\\' and end + 1 < content.len) {
                        end += 2;
                        continue;
                    }
                    if (content[end] == '"') {
                        return content[val_start + 1 .. end];
                    }
                    end += 1;
                }
                return content[val_start + 1 ..];
            } else if (content[val_start] == '{') {
                // Tuple value — find matching closing brace
                var depth: u32 = 1;
                var end = val_start + 1;
                while (end < content.len and depth > 0) {
                    if (content[end] == '{') depth += 1;
                    if (content[end] == '}') depth -= 1;
                    end += 1;
                }
                return content[val_start..end];
            } else {
                // Unquoted value — until comma or end
                var end = val_start;
                while (end < content.len and content[end] != ',') {
                    end += 1;
                }
                return content[val_start..end];
            }
        }
        pos += 1;
    }
    return null;
}

// Tests

test "parseMiRecord: result done" {
    const r = parseMiRecord("1^done");
    try std.testing.expectEqual(RecordType.result, r.record_type);
    try std.testing.expectEqual(ResultClass.done, r.result_class);
    try std.testing.expectEqual(@as(u32, 1), r.token);
}

test "parseMiRecord: result error" {
    const r = parseMiRecord("^error,msg=\"No such file\"");
    try std.testing.expectEqual(RecordType.result, r.record_type);
    try std.testing.expectEqual(ResultClass.@"error", r.result_class);
    try std.testing.expectEqual(@as(u32, 0), r.token);
}

test "parseMiRecord: exec async stopped" {
    const r = parseMiRecord("*stopped,reason=\"breakpoint-hit\",frame={addr=\"0x1234\"}");
    try std.testing.expectEqual(RecordType.exec_async, r.record_type);
    try std.testing.expect(std.mem.startsWith(u8, r.content, "stopped"));
}

test "parseMiRecord: console output" {
    const r = parseMiRecord("~\"Hello World\\n\"");
    try std.testing.expectEqual(RecordType.console, r.record_type);
    try std.testing.expectEqualStrings("Hello World\\n", r.content);
}

test "parseMiRecord: prompt" {
    const r = parseMiRecord("(gdb)");
    try std.testing.expectEqual(RecordType.prompt, r.record_type);
}

test "extractValue: simple quoted" {
    const val = extractValue("reason=\"breakpoint-hit\",thread-id=\"1\"", "reason");
    try std.testing.expectEqualStrings("breakpoint-hit", val.?);
}

test "extractValue: nested braces" {
    const val = extractValue("bkpt={number=\"1\",type=\"breakpoint\"}", "bkpt");
    try std.testing.expect(val != null);
    try std.testing.expect(std.mem.startsWith(u8, val.?, "{"));
}

test "extractValue: missing key" {
    const val = extractValue("reason=\"breakpoint-hit\"", "missing");
    try std.testing.expect(val == null);
}

test "unquote: basic" {
    try std.testing.expectEqualStrings("hello", unquote("\"hello\""));
    try std.testing.expectEqualStrings("hello", unquote("hello"));
}
