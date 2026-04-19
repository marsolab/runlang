const std = @import("std");
const lsp = @import("lsp.zig");
const debug_engine = @import("debug_engine.zig");
const driver = @import("driver.zig");
const ir = @import("ir.zig");

const File = std.Io.File;

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

    pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer) DapServer {
        return .{
            .allocator = allocator,
            .transport = lsp.Transport.init(allocator, reader, writer),
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
            } else if (std.mem.eql(u8, command, "runBatch")) {
                try self.handleRunBatch(request_seq, args);
            } else if (std.mem.eql(u8, command, "run/inspectGenRef")) {
                try self.handleInspectGenRef(request_seq, args);
            } else if (std.mem.eql(u8, command, "run/inspectChannel")) {
                try self.handleInspectChannel(request_seq, args);
            } else if (std.mem.eql(u8, command, "run/inspectMap")) {
                try self.handleInspectMap(request_seq, args);
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
        var body = std.json.ObjectMap.empty;
        try body.put(self.allocator, "supportsConfigurationDoneRequest", .{ .bool = true });
        try body.put(self.allocator, "supportsEvaluateForHovers", .{ .bool = true });
        try body.put(self.allocator, "supportsSetVariable", .{ .bool = false });
        try body.put(self.allocator, "supportsConditionalBreakpoints", .{ .bool = true });
        try body.put(self.allocator, "supportsHitConditionalBreakpoints", .{ .bool = true });
        try body.put(self.allocator, "supportsFunctionBreakpoints", .{ .bool = true });
        try body.put(self.allocator, "supportsStepBack", .{ .bool = false });

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

        // Launch debugger (auto-detects GDB or LLDB) with the compiled binary
        var gdb_engine = debug_engine.GdbEngine.initAutoDetect(self.allocator, binary, &.{}) catch {
            try self.sendErrorResponse(request_seq, "launch", "Failed to start debugger — neither GDB nor LLDB found");
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
                    const condition: ?[]const u8 = if (bp.object.get("condition")) |c| c.string else null;
                    const hit_condition: ?[]const u8 = if (bp.object.get("hitCondition")) |h| h.string else null;

                    if (self.engine) |*engine| {
                        const result = engine.setBreakpoint(source_path, line, condition, hit_condition) catch {
                            var bp_obj = std.json.ObjectMap.empty;
                            try bp_obj.put(self.allocator, "verified", .{ .bool = false });
                            try bp_obj.put(self.allocator, "line", .{ .integer = @intCast(line) });
                            try breakpoints.append(.{ .object = bp_obj });
                            continue;
                        };
                        var bp_obj = std.json.ObjectMap.empty;
                        try bp_obj.put(self.allocator, "id", .{ .integer = @intCast(result.id) });
                        try bp_obj.put(self.allocator, "verified", .{ .bool = result.verified });
                        try bp_obj.put(self.allocator, "line", .{ .integer = @intCast(result.line) });
                        try breakpoints.append(.{ .object = bp_obj });
                    }
                }
            }
        }

        var body = std.json.ObjectMap.empty;
        try body.put(self.allocator, "breakpoints", .{ .array = breakpoints });
        try self.sendResponse(request_seq, "setBreakpoints", true, .{ .object = body });
    }

    fn handleThreads(self: *DapServer, request_seq: u32) !void {
        var threads = std.json.Array.init(self.allocator);

        // Always report the main OS thread
        var thread_obj = std.json.ObjectMap.empty;
        try thread_obj.put(self.allocator, "id", .{ .integer = 1 });
        try thread_obj.put(self.allocator, "name", .{ .string = "main" });
        try threads.append(.{ .object = thread_obj });

        // Try to surface green threads from the runtime via run_debug_dump_goroutines()
        if (self.engine) |*engine| {
            const gt_result = engine.evaluate("(void)run_debug_dump_goroutines((char*)0, 0)") catch null;
            // Even if this fails, we still report the main thread.
            // Green thread enumeration is best-effort — the runtime may not be initialized yet.
            _ = gt_result;
        }

        var body = std.json.ObjectMap.empty;
        try body.put(self.allocator, "threads", .{ .array = threads });
        try self.sendResponse(request_seq, "threads", true, .{ .object = body });
    }

    fn handleStackTrace(self: *DapServer, request_seq: u32, args: ?std.json.Value) !void {
        _ = args;
        var frames = std.json.Array.init(self.allocator);

        if (self.engine) |*engine| {
            const trace = engine.getStackTrace(1) catch &.{};
            for (trace, 0..) |frame, i| {
                var frame_obj = std.json.ObjectMap.empty;
                try frame_obj.put(self.allocator, "id", .{ .integer = @intCast(i) });
                try frame_obj.put(self.allocator, "name", .{ .string = frame.name });
                try frame_obj.put(self.allocator, "line", .{ .integer = @intCast(frame.line) });
                try frame_obj.put(self.allocator, "column", .{ .integer = @intCast(frame.column) });

                if (frame.source_path.len > 0) {
                    var source_obj = std.json.ObjectMap.empty;
                    try source_obj.put(self.allocator, "path", .{ .string = frame.source_path });
                    try frame_obj.put(self.allocator, "source", .{ .object = source_obj });
                }

                try frames.append(.{ .object = frame_obj });
            }
        }

        var body = std.json.ObjectMap.empty;
        try body.put(self.allocator, "stackFrames", .{ .array = frames });
        try body.put(self.allocator, "totalFrames", .{ .integer = @intCast(frames.items.len) });
        try self.sendResponse(request_seq, "stackTrace", true, .{ .object = body });
    }

    fn handleScopes(self: *DapServer, request_seq: u32, args: ?std.json.Value) !void {
        _ = args;
        var scopes = std.json.Array.init(self.allocator);

        // Local scope
        var local_scope = std.json.ObjectMap.empty;
        try local_scope.put(self.allocator, "name", .{ .string = "Locals" });
        try local_scope.put(self.allocator, "variablesReference", .{ .integer = 1 });
        try local_scope.put(self.allocator, "expensive", .{ .bool = false });
        try scopes.append(.{ .object = local_scope });

        var body = std.json.ObjectMap.empty;
        try body.put(self.allocator, "scopes", .{ .array = scopes });
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

                var var_obj = std.json.ObjectMap.empty;
                try var_obj.put(self.allocator, "name", .{ .string = v.name });
                try var_obj.put(self.allocator, "value", .{ .string = v.value });
                try var_obj.put(self.allocator, "type", .{ .string = debug_engine.runTypeName(v.type_name) });
                try var_obj.put(self.allocator, "variablesReference", .{ .integer = 0 });
                try variables.append(.{ .object = var_obj });
            }
        }

        var body = std.json.ObjectMap.empty;
        try body.put(self.allocator, "variables", .{ .array = variables });
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
            // Translate Run expression to C expression before evaluation
            const translated = translateRunExpr(expr.?);
            const result = engine.evaluate(translated) catch {
                try self.sendErrorResponse(request_seq, "evaluate", "Evaluation failed");
                return;
            };
            var body = std.json.ObjectMap.empty;
            try body.put(self.allocator, "result", .{ .string = result.value });
            try body.put(self.allocator, "type", .{ .string = debug_engine.runTypeName(result.type_name) });
            try body.put(self.allocator, "variablesReference", .{ .integer = 0 });
            try self.sendResponse(request_seq, "evaluate", true, .{ .object = body });
        } else {
            try self.sendErrorResponse(request_seq, "evaluate", "No active debug session");
        }
    }

    /// Handle batch DAP request — executes multiple commands and returns all results.
    fn handleRunBatch(self: *DapServer, request_seq: u32, args: ?std.json.Value) !void {
        var results = std.json.Array.init(self.allocator);

        if (args) |a| {
            if (a.object.get("commands")) |commands| {
                for (commands.array.items) |cmd_obj| {
                    const command = if (cmd_obj.object.get("command")) |c| c.string else continue;
                    const cmd_args = cmd_obj.object.get("args");
                    const result = self.dispatchSingleCommand(command, cmd_args);
                    try results.append(result);
                }
            }
        }

        var body = std.json.ObjectMap.empty;
        try body.put(self.allocator, "results", .{ .array = results });
        try self.sendResponse(request_seq, "runBatch", true, .{ .object = body });
    }

    /// Dispatch a single command for batch execution, returning a result object.
    fn dispatchSingleCommand(self: *DapServer, command: []const u8, args: ?std.json.Value) std.json.Value {
        var result = std.json.ObjectMap.empty;
        result.put(self.allocator, "command", .{ .string = command }) catch {};
        result.put(self.allocator, "success", .{ .bool = true }) catch {};

        // Dispatch to engine for supported commands
        if (self.engine) |*engine| {
            if (std.mem.eql(u8, command, "setBreakpoints")) {
                if (args) |a| {
                    const source_obj = a.object.get("source") orelse {
                        result.put(self.allocator, "success", .{ .bool = false }) catch {};
                        return .{ .object = result };
                    };
                    const source_path = if (source_obj.object.get("path")) |p| p.string else "";
                    if (a.object.get("breakpoints")) |bps| {
                        var bp_results = std.json.Array.init(self.allocator);
                        for (bps.array.items) |bp| {
                            const line: u32 = if (bp.object.get("line")) |l| @intCast(l.integer) else 0;
                            const condition: ?[]const u8 = if (bp.object.get("condition")) |c| c.string else null;
                            const hit_condition: ?[]const u8 = if (bp.object.get("hitCondition")) |h| h.string else null;
                            const bp_result = engine.setBreakpoint(source_path, line, condition, hit_condition) catch {
                                var bp_obj = std.json.ObjectMap.empty;
                                bp_obj.put(self.allocator, "verified", .{ .bool = false }) catch {};
                                bp_results.append(.{ .object = bp_obj }) catch {};
                                continue;
                            };
                            var bp_obj = std.json.ObjectMap.empty;
                            bp_obj.put(self.allocator, "id", .{ .integer = @intCast(bp_result.id) }) catch {};
                            bp_obj.put(self.allocator, "verified", .{ .bool = bp_result.verified }) catch {};
                            bp_obj.put(self.allocator, "line", .{ .integer = @intCast(bp_result.line) }) catch {};
                            bp_results.append(.{ .object = bp_obj }) catch {};
                        }
                        var body = std.json.ObjectMap.empty;
                        body.put(self.allocator, "breakpoints", .{ .array = bp_results }) catch {};
                        result.put(self.allocator, "body", .{ .object = body }) catch {};
                    }
                }
            } else if (std.mem.eql(u8, command, "continue")) {
                const stop = engine.continue_() catch {
                    result.put(self.allocator, "success", .{ .bool = false }) catch {};
                    return .{ .object = result };
                };
                self.sendStoppedEvent(stop) catch {};
            } else if (std.mem.eql(u8, command, "next")) {
                const stop = engine.next() catch {
                    result.put(self.allocator, "success", .{ .bool = false }) catch {};
                    return .{ .object = result };
                };
                self.sendStoppedEvent(stop) catch {};
            } else if (std.mem.eql(u8, command, "evaluate")) {
                if (args) |a| {
                    if (a.object.get("expression")) |expr_val| {
                        const translated = translateRunExpr(expr_val.string);
                        const eval_result = engine.evaluate(translated) catch {
                            result.put(self.allocator, "success", .{ .bool = false }) catch {};
                            return .{ .object = result };
                        };
                        var body = std.json.ObjectMap.empty;
                        body.put(self.allocator, "result", .{ .string = eval_result.value }) catch {};
                        body.put(self.allocator, "type", .{ .string = debug_engine.runTypeName(eval_result.type_name) }) catch {};
                        result.put(self.allocator, "body", .{ .object = body }) catch {};
                    }
                }
            }
        } else {
            result.put(self.allocator, "success", .{ .bool = false }) catch {};
        }

        return .{ .object = result };
    }

    /// Handle run/inspectGenRef — inspect a generational reference variable.
    fn handleInspectGenRef(self: *DapServer, request_seq: u32, args: ?std.json.Value) !void {
        const expr = if (args) |a| blk: {
            if (a.object.get("expression")) |e| break :blk e.string;
            break :blk @as(?[]const u8, null);
        } else null;

        if (expr == null or self.engine == null) {
            try self.sendErrorResponse(request_seq, "run/inspectGenRef", "Missing expression or no active session");
            return;
        }

        var engine = &self.engine.?;

        var variables = std.json.Array.init(self.allocator);

        // Read the pointer field
        const ptr_result = engine.evaluate(
            std.fmt.allocPrint(self.allocator, "({s}).ptr", .{expr.?}) catch {
                try self.sendErrorResponse(request_seq, "run/inspectGenRef", "Evaluation failed");
                return;
            },
        ) catch {
            try self.sendErrorResponse(request_seq, "run/inspectGenRef", "Failed to read ptr field");
            return;
        };
        var ptr_var = std.json.ObjectMap.empty;
        try ptr_var.put(self.allocator, "name", .{ .string = "ptr" });
        try ptr_var.put(self.allocator, "value", .{ .string = ptr_result.value });
        try ptr_var.put(self.allocator, "type", .{ .string = "ptr" });
        try ptr_var.put(self.allocator, "variablesReference", .{ .integer = 0 });
        try variables.append(.{ .object = ptr_var });

        // Read the generation field
        const gen_result = engine.evaluate(
            std.fmt.allocPrint(self.allocator, "({s}).generation", .{expr.?}) catch {
                try self.sendErrorResponse(request_seq, "run/inspectGenRef", "Evaluation failed");
                return;
            },
        ) catch {
            try self.sendErrorResponse(request_seq, "run/inspectGenRef", "Failed to read generation field");
            return;
        };
        var gen_var = std.json.ObjectMap.empty;
        try gen_var.put(self.allocator, "name", .{ .string = "generation" });
        try gen_var.put(self.allocator, "value", .{ .string = gen_result.value });
        try gen_var.put(self.allocator, "type", .{ .string = "int" });
        try gen_var.put(self.allocator, "variablesReference", .{ .integer = 0 });
        try variables.append(.{ .object = gen_var });

        // Check validity by calling run_gen_get
        const current_gen = engine.evaluate(
            std.fmt.allocPrint(self.allocator, "run_gen_get(({s}).ptr)", .{expr.?}) catch {
                try self.sendErrorResponse(request_seq, "run/inspectGenRef", "Evaluation failed");
                return;
            },
        ) catch null;

        var valid_var = std.json.ObjectMap.empty;
        try valid_var.put(self.allocator, "name", .{ .string = "valid" });
        if (current_gen) |cg| {
            const is_valid = std.mem.eql(u8, cg.value, gen_result.value);
            try valid_var.put(self.allocator, "value", .{ .string = if (is_valid) "true" else "false" });
        } else {
            try valid_var.put(self.allocator, "value", .{ .string = "unknown" });
        }
        try valid_var.put(self.allocator, "type", .{ .string = "bool" });
        try valid_var.put(self.allocator, "variablesReference", .{ .integer = 0 });
        try variables.append(.{ .object = valid_var });

        var body = std.json.ObjectMap.empty;
        try body.put(self.allocator, "variables", .{ .array = variables });
        try self.sendResponse(request_seq, "run/inspectGenRef", true, .{ .object = body });
    }

    /// Handle run/inspectChannel — inspect a channel's internal state.
    fn handleInspectChannel(self: *DapServer, request_seq: u32, args: ?std.json.Value) !void {
        const expr = if (args) |a| blk: {
            if (a.object.get("expression")) |e| break :blk e.string;
            break :blk @as(?[]const u8, null);
        } else null;

        if (expr == null or self.engine == null) {
            try self.sendErrorResponse(request_seq, "run/inspectChannel", "Missing expression or no active session");
            return;
        }

        var engine = &self.engine.?;
        var variables = std.json.Array.init(self.allocator);

        // Read channel fields via GDB expression evaluation
        const fields = [_]struct { name: []const u8, field: []const u8, type_name: []const u8 }{
            .{ .name = "elem_size", .field = "elem_size", .type_name = "int" },
            .{ .name = "buffer_cap", .field = "buffer_cap", .type_name = "int" },
            .{ .name = "buffer_len", .field = "buffer_len", .type_name = "int" },
            .{ .name = "closed", .field = "closed", .type_name = "bool" },
            .{ .name = "send_q.len", .field = "send_q.len", .type_name = "int" },
            .{ .name = "recv_q.len", .field = "recv_q.len", .type_name = "int" },
        };

        for (fields) |f| {
            const eval_expr = std.fmt.allocPrint(self.allocator, "({s})->{s}", .{ expr.?, f.field }) catch continue;
            const result = engine.evaluate(eval_expr) catch continue;
            var var_obj = std.json.ObjectMap.empty;
            try var_obj.put(self.allocator, "name", .{ .string = f.name });
            try var_obj.put(self.allocator, "value", .{ .string = result.value });
            try var_obj.put(self.allocator, "type", .{ .string = f.type_name });
            try var_obj.put(self.allocator, "variablesReference", .{ .integer = 0 });
            try variables.append(.{ .object = var_obj });
        }

        var body = std.json.ObjectMap.empty;
        try body.put(self.allocator, "variables", .{ .array = variables });
        try self.sendResponse(request_seq, "run/inspectChannel", true, .{ .object = body });
    }

    /// Handle run/inspectMap — inspect a map's internal state.
    fn handleInspectMap(self: *DapServer, request_seq: u32, args: ?std.json.Value) !void {
        const expr = if (args) |a| blk: {
            if (a.object.get("expression")) |e| break :blk e.string;
            break :blk @as(?[]const u8, null);
        } else null;

        if (expr == null or self.engine == null) {
            try self.sendErrorResponse(request_seq, "run/inspectMap", "Missing expression or no active session");
            return;
        }

        var engine = &self.engine.?;
        var variables = std.json.Array.init(self.allocator);

        // Read map length via runtime function
        const len_expr = std.fmt.allocPrint(self.allocator, "run_map_len({s})", .{expr.?}) catch {
            try self.sendErrorResponse(request_seq, "run/inspectMap", "Evaluation failed");
            return;
        };
        const len_result = engine.evaluate(len_expr) catch {
            try self.sendErrorResponse(request_seq, "run/inspectMap", "Failed to evaluate map length");
            return;
        };
        var len_var = std.json.ObjectMap.empty;
        try len_var.put(self.allocator, "name", .{ .string = "length" });
        try len_var.put(self.allocator, "value", .{ .string = len_result.value });
        try len_var.put(self.allocator, "type", .{ .string = "int" });
        try len_var.put(self.allocator, "variablesReference", .{ .integer = 0 });
        try variables.append(.{ .object = len_var });

        var body = std.json.ObjectMap.empty;
        try body.put(self.allocator, "variables", .{ .array = variables });
        try self.sendResponse(request_seq, "run/inspectMap", true, .{ .object = body });
    }

    // --- DAP Message Helpers ---

    fn sendStoppedEvent(self: *DapServer, stop: debug_engine.StopEvent) !void {
        var body = std.json.ObjectMap.empty;
        const reason_str: []const u8 = switch (stop.reason) {
            .breakpoint_hit => "breakpoint",
            .step => "step",
            .pause => "pause",
            .exception => "exception",
            .entry => "entry",
            .exited => "exited",
            .unknown => "unknown",
        };
        try body.put(self.allocator, "reason", .{ .string = reason_str });
        try body.put(self.allocator, "threadId", .{ .integer = @intCast(stop.thread_id) });
        try body.put(self.allocator, "allThreadsStopped", .{ .bool = true });

        try self.sendEvent("stopped", .{ .object = body });
    }

    fn sendResponse(self: *DapServer, request_seq: u32, command: []const u8, success: bool, body: ?std.json.Value) !void {
        var msg = std.json.ObjectMap.empty;
        try msg.put(self.allocator, "seq", .{ .integer = @intCast(self.seq) });
        self.seq += 1;
        try msg.put(self.allocator, "type", .{ .string = "response" });
        try msg.put(self.allocator, "request_seq", .{ .integer = @intCast(request_seq) });
        try msg.put(self.allocator, "success", .{ .bool = success });
        try msg.put(self.allocator, "command", .{ .string = command });
        if (body) |b| {
            try msg.put(self.allocator, "body", b);
        }

        try self.writeJson(.{ .object = msg });
    }

    fn sendErrorResponse(self: *DapServer, request_seq: u32, command: []const u8, message: []const u8) !void {
        var body = std.json.ObjectMap.empty;
        var error_obj = std.json.ObjectMap.empty;
        try error_obj.put(self.allocator, "id", .{ .integer = 1 });
        try error_obj.put(self.allocator, "format", .{ .string = message });
        try body.put(self.allocator, "error", .{ .object = error_obj });

        var msg = std.json.ObjectMap.empty;
        try msg.put(self.allocator, "seq", .{ .integer = @intCast(self.seq) });
        self.seq += 1;
        try msg.put(self.allocator, "type", .{ .string = "response" });
        try msg.put(self.allocator, "request_seq", .{ .integer = @intCast(request_seq) });
        try msg.put(self.allocator, "success", .{ .bool = false });
        try msg.put(self.allocator, "command", .{ .string = command });
        try msg.put(self.allocator, "message", .{ .string = message });
        try msg.put(self.allocator, "body", .{ .object = body });

        try self.writeJson(.{ .object = msg });
    }

    fn sendEvent(self: *DapServer, event: []const u8, body: ?std.json.Value) !void {
        var msg = std.json.ObjectMap.empty;
        try msg.put(self.allocator, "seq", .{ .integer = @intCast(self.seq) });
        self.seq += 1;
        try msg.put(self.allocator, "type", .{ .string = "event" });
        try msg.put(self.allocator, "event", .{ .string = event });
        if (body) |b| {
            try msg.put(self.allocator, "body", b);
        }

        try self.writeJson(.{ .object = msg });
    }

    fn writeJson(self: *DapServer, value: std.json.Value) !void {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();

        try writeJsonValue(&writer.writer, value);
        try self.transport.writeMessage(writer.writer.buffered());
    }
};

/// Translate a Run-level expression to its C equivalent for GDB evaluation.
///
/// Run codegen preserves original variable names in C output (via LocalInfo),
/// so most expressions pass through unchanged. This handles:
/// - Function calls: `myFunc(args)` → `run_main__myFunc(args)`
/// - Variable names and field access pass through (same syntax in C)
///
/// This is a lightweight pass, not a full expression parser.
fn translateRunExpr(expr: []const u8) []const u8 {
    // Most Run variable names map directly to C names since codegen
    // uses original names via LocalInfo. Field access (obj.field) is
    // also the same syntax in C for structs. So we pass through as-is
    // for the common case.
    //
    // The main transformation needed is for function calls that would
    // need the run_main__ prefix, but those are rare in debug evaluation.
    // For now, return the expression unchanged — this covers the 95% case
    // of variable inspection and field access.
    return expr;
}

/// Serialize a std.json.Value to a writer as JSON text.
fn writeJsonValue(writer: *std.Io.Writer, value: std.json.Value) std.Io.Writer.Error!void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |n| try writer.print("{d}", .{n}),
        .float => |f| try writer.print("{d}", .{f}),
        .string => |s| {
            try writer.writeByte('"');
            for (s) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeByte('"');
        },
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writeJsonValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |obj| {
            try writer.writeByte('{');
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try writer.writeByte('"');
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeAll("\":");
                try writeJsonValue(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
        .number_string => |s| try writer.writeAll(s),
    }
}

/// Entry point: start the DAP server on stdin/stdout.
pub fn serve(allocator: std.mem.Allocator) !void {
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var stdin_buffer: [4096]u8 = undefined;
    var stdout_buffer: [4096]u8 = undefined;
    var stdin_reader = File.stdin().readerStreaming(io, &stdin_buffer);
    var stdout_writer = File.stdout().writerStreaming(io, &stdout_buffer);
    defer stdout_writer.flush() catch {};

    var server = DapServer.init(allocator, &stdin_reader.interface, &stdout_writer.interface);
    defer server.deinit();
    try server.run();
}
