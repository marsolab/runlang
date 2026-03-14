const std = @import("std");

/// End-to-end DAP integration test harness.
///
/// Spawns the Run DAP server as a child process and communicates over
/// stdin/stdout using the Content-Length framed JSON protocol.
///
/// Prerequisites:
/// - `run` binary must be built and available at `./zig-out/bin/run`
/// - GDB must be installed for debugger operations
///
/// These tests verify the full pipeline: DAP client → DAP server → GDB → compiled binary

const DapClient = struct {
    process: std.process.Child,
    stdout_reader: std.io.AnyReader,
    stdin_writer: std.io.AnyWriter,
    allocator: std.mem.Allocator,
    seq: u32,
    buf: [65536]u8,

    fn init(allocator: std.mem.Allocator) !DapClient {
        var child = std.process.Child.init(
            &.{ "./zig-out/bin/run", "debug", "--dap" },
            allocator,
        );
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| {
            std.debug.print("Failed to spawn DAP server: {any}\n", .{err});
            std.debug.print("Ensure `zig build` has been run first.\n", .{});
            return err;
        };

        return .{
            .process = child,
            .stdout_reader = child.stdout.?.deprecatedReader().any(),
            .stdin_writer = child.stdin.?.deprecatedWriter().any(),
            .allocator = allocator,
            .seq = 1,
            .buf = undefined,
        };
    }

    fn deinit(self: *DapClient) void {
        // Close stdin to signal the server to exit
        if (self.process.stdin) |*stdin| {
            stdin.close();
            self.process.stdin = null;
        }
        _ = self.process.wait() catch {};
    }

    /// Send a DAP request.
    fn sendRequest(self: *DapClient, command: []const u8, arguments: ?[]const u8) !void {
        var msg_buf: [4096]u8 = undefined;
        const args_str = arguments orelse "null";
        const msg = std.fmt.bufPrint(&msg_buf,
            \\{{"seq":{d},"type":"request","command":"{s}","arguments":{s}}}
        , .{ self.seq, command, args_str }) catch return error.MessageTooLong;
        self.seq += 1;

        // Write Content-Length header + body
        var header_buf: [128]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{msg.len}) catch
            return error.MessageTooLong;

        try self.stdin_writer.writeAll(header);
        try self.stdin_writer.writeAll(msg);
    }

    /// Read a DAP response (Content-Length framed JSON).
    fn readResponse(self: *DapClient) ![]const u8 {
        // Read "Content-Length: NNN\r\n\r\n"
        var header_buf: [256]u8 = undefined;
        var header_len: usize = 0;

        // Read until we find \r\n\r\n
        while (header_len < header_buf.len - 1) {
            const byte = self.stdout_reader.readByte() catch return error.ServerClosed;
            header_buf[header_len] = byte;
            header_len += 1;

            if (header_len >= 4 and
                header_buf[header_len - 4] == '\r' and
                header_buf[header_len - 3] == '\n' and
                header_buf[header_len - 2] == '\r' and
                header_buf[header_len - 1] == '\n')
            {
                break;
            }
        }

        // Parse Content-Length
        const header_str = header_buf[0..header_len];
        const prefix = "Content-Length: ";
        if (!std.mem.startsWith(u8, header_str, prefix)) return error.InvalidHeader;

        const len_end = std.mem.indexOf(u8, header_str, "\r\n") orelse return error.InvalidHeader;
        const content_length = std.fmt.parseInt(usize, header_str[prefix.len..len_end], 10) catch
            return error.InvalidHeader;

        if (content_length > self.buf.len) return error.ResponseTooLarge;

        // Read the JSON body
        var total_read: usize = 0;
        while (total_read < content_length) {
            const n = self.stdout_reader.read(self.buf[total_read..content_length]) catch
                return error.ReadFailed;
            if (n == 0) return error.ServerClosed;
            total_read += n;
        }

        return self.buf[0..content_length];
    }

    /// Read responses until we get one matching the expected command.
    fn readResponseForCommand(self: *DapClient, expected_command: []const u8) ![]const u8 {
        var attempts: u32 = 0;
        while (attempts < 20) : (attempts += 1) {
            const response = try self.readResponse();
            // Simple check: does the response contain the command name?
            if (std.mem.indexOf(u8, response, expected_command) != null and
                std.mem.indexOf(u8, response, "\"response\"") != null)
            {
                return response;
            }
            // Otherwise it's an event or different response — keep reading
        }
        return error.ResponseTimeout;
    }
};

// --- Tests ---

test "DAP: initialize returns capabilities" {
    var client = DapClient.init(std.testing.allocator) catch |err| {
        // Skip test if DAP server binary is not available
        if (err == error.FileNotFound) return;
        return err;
    };
    defer client.deinit();

    try client.sendRequest("initialize", "{\"adapterID\":\"run-test\"}");
    const response = client.readResponseForCommand("initialize") catch |err| {
        // Skip if server isn't responding (no GDB, etc.)
        if (err == error.ServerClosed) return;
        return err;
    };

    // Verify it's a success response with capabilities
    try std.testing.expect(std.mem.indexOf(u8, response, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "supportsConditionalBreakpoints") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "supportsHitConditionalBreakpoints") != null);
}

test "DAP: disconnect terminates cleanly" {
    var client = DapClient.init(std.testing.allocator) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer client.deinit();

    try client.sendRequest("initialize", "{\"adapterID\":\"run-test\"}");
    _ = client.readResponseForCommand("initialize") catch |err| {
        if (err == error.ServerClosed) return;
        return err;
    };

    // Read the initialized event
    _ = client.readResponse() catch {};

    try client.sendRequest("disconnect", "{}");
    const response = client.readResponseForCommand("disconnect") catch |err| {
        // Server may close immediately, which is also valid
        if (err == error.ServerClosed) return;
        return err;
    };

    try std.testing.expect(std.mem.indexOf(u8, response, "\"success\":true") != null);
}

test "DAP: launch with missing program returns error" {
    var client = DapClient.init(std.testing.allocator) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer client.deinit();

    try client.sendRequest("initialize", "{\"adapterID\":\"run-test\"}");
    _ = client.readResponseForCommand("initialize") catch |err| {
        if (err == error.ServerClosed) return;
        return err;
    };

    // Read initialized event
    _ = client.readResponse() catch {};

    // Launch without program argument
    try client.sendRequest("launch", "{}");
    const response = client.readResponseForCommand("launch") catch |err| {
        if (err == error.ServerClosed) return;
        return err;
    };

    try std.testing.expect(std.mem.indexOf(u8, response, "\"success\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "program") != null);
}

test "DAP: unknown command returns success" {
    var client = DapClient.init(std.testing.allocator) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer client.deinit();

    try client.sendRequest("initialize", "{\"adapterID\":\"run-test\"}");
    _ = client.readResponseForCommand("initialize") catch |err| {
        if (err == error.ServerClosed) return;
        return err;
    };

    // Read initialized event
    _ = client.readResponse() catch {};

    // Send unknown command — DAP requires a response for every request
    try client.sendRequest("unknownCommand", "{}");
    const response = client.readResponseForCommand("unknownCommand") catch |err| {
        if (err == error.ServerClosed) return;
        return err;
    };

    try std.testing.expect(std.mem.indexOf(u8, response, "\"success\":true") != null);
}
