const std = @import("std");
const lsp = @import("lsp.zig");
const debug_engine = @import("debug_engine.zig");
const driver = @import("driver.zig");
const ir = @import("ir.zig");

const File = std.fs.File;

/// Debug Adapter Protocol server for the Run language.
///
/// Implements DAP over stdin/stdout using the same Content-Length framing as LSP.
/// The server wraps a DebugEngine (currently GDB/MI) and translates between
/// DAP JSON messages and the engine's structured API.
pub const DapServer = struct {
    allocator: std.mem.Allocator,
    transport: lsp.Transport,
    engine: ?debug_engine.DebugEngine,
    seq: u32,
    initialized: bool,
    source_path: ?[]const u8,
    binary_path: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) DapServer {
        const stdin = File.stdin().deprecatedReader();
        const stdout = File.stdout().deprecatedWriter();
        return .{
            .allocator = allocator,
            .transport = lsp.Transport.init(
                allocator,
                stdin.any(),
                stdout.any(),
            ),
            .engine = null,
            .seq = 1,
            .initialized = false,
            .source_path = null,
            .binary_path = null,
        };
    }

    pub fn deinit(self: *DapServer) void {
        if (self.engine) |*e| e.disconnect();
        self.transport.deinit();
    }

    /// Main loop: read DAP requests, dispatch handlers, send responses.
    pub fn run(self: *DapServer) !void {
        while (true) {
            const msg = self.transport.readMessage() catch |err| switch (err) {
                error.EndOfStream => return,
                else => continue,
            };
            defer msg.deinit();

            const obj = msg.value.object;
            const msg_type = (obj.get("type") orelse continue).string;
            if (!std.mem.eql(u8, msg_type, "request")) continue;

            const command = (obj.get("command") orelse continue).string;
            const request_seq = if (obj.get("seq")) |s| switch (s) {
                .integer => @as(u32, @intCast(s.integer)),
                else => 0,
            } else 0;

            const args = if (obj.get("arguments")) |a| a else null;

            if (std.mem.eql(u8, command, "initialize")) {
                try self.handleInitialize(request_seq);
            } else if (std.mem.eql(u8, command, "launch")) {
                try self.handleLaunch(request_seq, args);
            } else if (std.mem.eql(u8, command, "setBreakpoints")) {
                try self.handleSetBreakpoints(request_seq, args);
            } else if (std.mem.eql(u8, command, "configurationDone")) {
                try self.sendResponse(request_seq, command, true, null);
            } else if (std.mem.eql(u8, command, "threads")) {
                try self.handleThreads(request_seq);
            } else if (std.mem.eql(u8, command, "stackTrace")) {
                try self.handleStackTrace(request_seq, args);
            } else if (std.mem.eql(u8, command, "scopes")) {
                try self.handleScopes(request_seq, args);
            } else if (std.mem.eql(u8, command, "variables")) {
                try self.handleVariables(request_seq, args);
            } else if (std.mem.eql(u8, command, "continue")) {
                try self.handleContinue(request_seq);
            } else if (std.mem.eql(u8, command, "next")) {
                try self.handleNext(request_seq);
            } else if (std.mem.eql(u8, command, "stepIn")) {
                try self.handleStepIn(request_seq);
            } else if (std.mem.eql(u8, command, "stepOut")) {
                try self.handleStepOut(request_seq);
            } else if (std.mem.eql(u8, command, "evaluate")) {
                try self.handleEvaluate(request_seq, args);
            } else if (std.mem.eql(u8, command, "disconnect")) {
                try self.sendResponse(request_seq, command, true, null);
                return;
            } else {
                // Unknown command — respond with success (DAP requires response for every request)
                try self.sendResponse(request_seq, command, true, null);
            }
        }
    }

    // --- DAP Request Handlers ---

    fn handleInitialize(self: *DapServer, request_seq: u32) !void {
        self.initialized = true;

        // Build capabilities response
        var body = std.json.ObjectMap.init(self.allocator);
        try body.put("supportsConfigurationDoneRequest", .{ .bool = true });
        try body.put("supportsEvaluateForHovers", .{ .bool = true });
        try body.put("supportsSetVariable", .{ .bool = false });
        try body.put("supportsConditionalBreakpoints", .{ .bool = true });
        try body.put("supportsFunctionBreakpoints", .{ .bool = true });
        try body.put("supportsStepBack", .{ .bool = false });

        try self.sendResponse(request_seq, "initialize", true, .{ .object = body });

        // Send initialized event
        try self.sendEvent("initialized", null);
    }

    fn handleLaunch(self: *DapServer, request_seq: u32, args: ?std.json.Value) !void {
        const program = if (args) |a| blk: {
            if (a.object.get("program")) |p| break :blk p.string;
            break :blk @as(?[]const u8, null);
        } else null;

        if (program == null) {
            try self.sendErrorResponse(request_seq, "launch", "Missing 'program' argument");
            return;
        }

        self.source_path = program;

        // Compile the program with debug symbols
        driver.compile(self.allocator, .{
            .input_path = program.?,
            .command = .build,
            .debug = true,
        }) catch {
            try self.sendErrorResponse(request_seq, "launch", "Compilation failed");
            return;
        };

        // Determine binary path (strip .run extension)
        const binary = std.fs.path.stem(program.?);
        self.binary_path = binary;

        // Launch GDB with the compiled binary
        var gdb_engine = debug_engine.GdbEngine.init(self.allocator, binary, &.{}) catch {
            try self.sendErrorResponse(request_seq, "launch", "Failed to start GDB");
            return;
        };
        gdb_engine.launch() catch {
            try self.sendErrorResponse(request_seq, "launch", "GDB initialization failed");
            return;
        };

        self.engine = .{ .gdb = gdb_engine };

        try self.sendResponse(request_seq, "launch", true, null);
    }

    fn handleSetBreakpoints(self: *DapServer, request_seq: u32, args: ?std.json.Value) !void {
        var breakpoints = std.json.Array.init(self.allocator);

        if (args) |a| {
            const source_obj = a.object.get("source") orelse {
                try self.sendResponse(request_seq, "setBreakpoints", true, null);
                return;
            };
            const source_path = if (source_obj.object.get("path")) |p| p.string else "";

            if (a.object.get("breakpoints")) |bps| {
                for (bps.array.items) |bp| {
                    const line: u32 = if (bp.object.get("line")) |l| @intCast(l.integer) else 0;

                    if (self.engine) |*engine| {
                        const result = engine.setBreakpoint(source_path, line) catch {
                            var bp_obj = std.json.ObjectMap.init(self.allocator);
                            try bp_obj.put("verified", .{ .bool = false });
                            try bp_obj.put("line", .{ .integer = @intCast(line) });
                            try breakpoints.append(.{ .object = bp_obj });
                            continue;
                        };
                        var bp_obj = std.json.ObjectMap.init(self.allocator);
                        try bp_obj.put("id", .{ .integer = @intCast(result.id) });
                        try bp_obj.put("verified", .{ .bool = result.verified });
                        try bp_obj.put("line", .{ .integer = @intCast(result.line) });
                        try breakpoints.append(.{ .object = bp_obj });
                    }
                }
            }
        }

        var body = std.json.ObjectMap.init(self.allocator);
        try body.put("breakpoints", .{ .array = breakpoints });
        try self.sendResponse(request_seq, "setBreakpoints", true, .{ .object = body });
    }

    fn handleThreads(self: *DapServer, request_seq: u32) !void {
        var threads = std.json.Array.init(self.allocator);

        // Always report at least the main thread
        var thread_obj = std.json.ObjectMap.init(self.allocator);
        try thread_obj.put("id", .{ .integer = 1 });
        try thread_obj.put("name", .{ .string = "main" });
        try threads.append(.{ .object = thread_obj });

        var body = std.json.ObjectMap.init(self.allocator);
        try body.put("threads", .{ .array = threads });
        try self.sendResponse(request_seq, "threads", true, .{ .object = body });
    }

    fn handleStackTrace(self: *DapServer, request_seq: u32, args: ?std.json.Value) !void {
        _ = args;
        var frames = std.json.Array.init(self.allocator);

        if (self.engine) |*engine| {
            const trace = engine.getStackTrace(1) catch &.{};
            for (trace, 0..) |frame, i| {
                var frame_obj = std.json.ObjectMap.init(self.allocator);
                try frame_obj.put("id", .{ .integer = @intCast(i) });
                try frame_obj.put("name", .{ .string = frame.name });
                try frame_obj.put("line", .{ .integer = @intCast(frame.line) });
                try frame_obj.put("column", .{ .integer = @intCast(frame.column) });

                if (frame.source_path.len > 0) {
                    var source_obj = std.json.ObjectMap.init(self.allocator);
                    try source_obj.put("path", .{ .string = frame.source_path });
                    try frame_obj.put("source", .{ .object = source_obj });
                }

                try frames.append(.{ .object = frame_obj });
            }
        }

        var body = std.json.ObjectMap.init(self.allocator);
        try body.put("stackFrames", .{ .array = frames });
        try body.put("totalFrames", .{ .integer = @intCast(frames.items.len) });
        try self.sendResponse(request_seq, "stackTrace", true, .{ .object = body });
    }

    fn handleScopes(self: *DapServer, request_seq: u32, args: ?std.json.Value) !void {
        _ = args;
        var scopes = std.json.Array.init(self.allocator);

        // Local scope
        var local_scope = std.json.ObjectMap.init(self.allocator);
        try local_scope.put("name", .{ .string = "Locals" });
        try local_scope.put("variablesReference", .{ .integer = 1 });
        try local_scope.put("expensive", .{ .bool = false });
        try scopes.append(.{ .object = local_scope });

        var body = std.json.ObjectMap.init(self.allocator);
        try body.put("scopes", .{ .array = scopes });
        try self.sendResponse(request_seq, "scopes", true, .{ .object = body });
    }

    fn handleVariables(self: *DapServer, request_seq: u32, args: ?std.json.Value) !void {
        _ = args;
        var variables = std.json.Array.init(self.allocator);

        if (self.engine) |*engine| {
            const vars = engine.getVariables(0) catch &.{};
            for (vars) |v| {
                // Filter out SSA temporaries
                if (debug_engine.isSsaTemporary(v.name)) continue;

                var var_obj = std.json.ObjectMap.init(self.allocator);
                try var_obj.put("name", .{ .string = v.name });
                try var_obj.put("value", .{ .string = v.value });
                try var_obj.put("type", .{ .string = debug_engine.runTypeName(v.type_name) });
                try var_obj.put("variablesReference", .{ .integer = 0 });
                try variables.append(.{ .object = var_obj });
            }
        }

        var body = std.json.ObjectMap.init(self.allocator);
        try body.put("variables", .{ .array = variables });
        try self.sendResponse(request_seq, "variables", true, .{ .object = body });
    }

    fn handleContinue(self: *DapServer, request_seq: u32) !void {
        try self.sendResponse(request_seq, "continue", true, null);
        if (self.engine) |*engine| {
            const stop = engine.continue_() catch return;
            try self.sendStoppedEvent(stop);
        }
    }

    fn handleNext(self: *DapServer, request_seq: u32) !void {
        try self.sendResponse(request_seq, "next", true, null);
        if (self.engine) |*engine| {
            const stop = engine.next() catch return;
            try self.sendStoppedEvent(stop);
        }
    }

    fn handleStepIn(self: *DapServer, request_seq: u32) !void {
        try self.sendResponse(request_seq, "stepIn", true, null);
        if (self.engine) |*engine| {
            const stop = engine.stepIn() catch return;
            try self.sendStoppedEvent(stop);
        }
    }

    fn handleStepOut(self: *DapServer, request_seq: u32) !void {
        try self.sendResponse(request_seq, "stepOut", true, null);
        if (self.engine) |*engine| {
            const stop = engine.stepOut() catch return;
            try self.sendStoppedEvent(stop);
        }
    }

    fn handleEvaluate(self: *DapServer, request_seq: u32, args: ?std.json.Value) !void {
        const expr = if (args) |a| blk: {
            if (a.object.get("expression")) |e| break :blk e.string;
            break :blk @as(?[]const u8, null);
        } else null;

        if (expr == null) {
            try self.sendErrorResponse(request_seq, "evaluate", "Missing expression");
            return;
        }

        if (self.engine) |*engine| {
            const result = engine.evaluate(expr.?) catch {
                try self.sendErrorResponse(request_seq, "evaluate", "Evaluation failed");
                return;
            };
            var body = std.json.ObjectMap.init(self.allocator);
            try body.put("result", .{ .string = result.value });
            try body.put("type", .{ .string = debug_engine.runTypeName(result.type_name) });
            try body.put("variablesReference", .{ .integer = 0 });
            try self.sendResponse(request_seq, "evaluate", true, .{ .object = body });
        } else {
            try self.sendErrorResponse(request_seq, "evaluate", "No active debug session");
        }
    }

    // --- DAP Message Helpers ---

    fn sendStoppedEvent(self: *DapServer, stop: debug_engine.StopEvent) !void {
        var body = std.json.ObjectMap.init(self.allocator);
        const reason_str: []const u8 = switch (stop.reason) {
            .breakpoint_hit => "breakpoint",
            .step => "step",
            .pause => "pause",
            .exception => "exception",
            .entry => "entry",
            .exited => "exited",
            .unknown => "unknown",
        };
        try body.put("reason", .{ .string = reason_str });
        try body.put("threadId", .{ .integer = @intCast(stop.thread_id) });
        try body.put("allThreadsStopped", .{ .bool = true });

        try self.sendEvent("stopped", .{ .object = body });
    }

    fn sendResponse(self: *DapServer, request_seq: u32, command: []const u8, success: bool, body: ?std.json.Value) !void {
        var msg = std.json.ObjectMap.init(self.allocator);
        try msg.put("seq", .{ .integer = @intCast(self.seq) });
        self.seq += 1;
        try msg.put("type", .{ .string = "response" });
        try msg.put("request_seq", .{ .integer = @intCast(request_seq) });
        try msg.put("success", .{ .bool = success });
        try msg.put("command", .{ .string = command });
        if (body) |b| {
            try msg.put("body", b);
        }

        try self.writeJson(.{ .object = msg });
    }

    fn sendErrorResponse(self: *DapServer, request_seq: u32, command: []const u8, message: []const u8) !void {
        var body = std.json.ObjectMap.init(self.allocator);
        var error_obj = std.json.ObjectMap.init(self.allocator);
        try error_obj.put("id", .{ .integer = 1 });
        try error_obj.put("format", .{ .string = message });
        try body.put("error", .{ .object = error_obj });

        var msg = std.json.ObjectMap.init(self.allocator);
        try msg.put("seq", .{ .integer = @intCast(self.seq) });
        self.seq += 1;
        try msg.put("type", .{ .string = "response" });
        try msg.put("request_seq", .{ .integer = @intCast(request_seq) });
        try msg.put("success", .{ .bool = false });
        try msg.put("command", .{ .string = command });
        try msg.put("message", .{ .string = message });
        try msg.put("body", .{ .object = body });

        try self.writeJson(.{ .object = msg });
    }

    fn sendEvent(self: *DapServer, event: []const u8, body: ?std.json.Value) !void {
        var msg = std.json.ObjectMap.init(self.allocator);
        try msg.put("seq", .{ .integer = @intCast(self.seq) });
        self.seq += 1;
        try msg.put("type", .{ .string = "event" });
        try msg.put("event", .{ .string = event });
        if (body) |b| {
            try msg.put("body", b);
        }

        try self.writeJson(.{ .object = msg });
    }

    fn writeJson(self: *DapServer, value: std.json.Value) !void {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        try std.json.stringify(value, .{}, buf.writer(self.allocator));
        try self.transport.writeMessage(buf.items);
    }
};

/// Entry point: start the DAP server on stdin/stdout.
pub fn serve(allocator: std.mem.Allocator) !void {
    var server = DapServer.init(allocator);
    defer server.deinit();
    try server.run();
}
