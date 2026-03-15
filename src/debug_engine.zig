const std = @import("std");
const ir = @import("ir.zig");
const gdb_mi = @import("gdb_mi.zig");

/// Breakpoint information returned to the DAP layer.
pub const Breakpoint = struct {
    id: u32,
    verified: bool,
    line: u32,
    source_path: []const u8,
};

/// Reason execution stopped.
pub const StopReason = enum {
    breakpoint_hit,
    step,
    pause,
    exception,
    entry,
    exited,
    unknown,
};

/// Event describing why execution stopped.
pub const StopEvent = struct {
    reason: StopReason,
    thread_id: u32,
    file: []const u8,
    line: u32,
    function_name: []const u8,
};

/// A single stack frame.
pub const Frame = struct {
    id: u32,
    name: []const u8,
    source_path: []const u8,
    line: u32,
    column: u32,
};

/// A debug thread (maps to OS thread or green thread).
pub const Thread = struct {
    id: u32,
    name: []const u8,
};

/// An inspected variable.
pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    type_name: []const u8,
};

/// Abstract debug engine interface.
/// The GDB backend implements this; a future ptrace-based engine would too.
pub const DebugEngine = union(enum) {
    gdb: GdbEngine,

    pub fn launch(self: *DebugEngine) !void {
        switch (self.*) {
            .gdb => |*e| try e.launch(),
        }
    }

    pub fn setBreakpoint(self: *DebugEngine, file: []const u8, line: u32, condition: ?[]const u8, hit_condition: ?[]const u8) !Breakpoint {
        switch (self.*) {
            .gdb => |*e| return e.setBreakpoint(file, line, condition, hit_condition),
        }
    }

    pub fn removeBreakpoint(self: *DebugEngine, id: u32) !void {
        switch (self.*) {
            .gdb => |*e| try e.removeBreakpoint(id),
        }
    }

    pub fn continue_(self: *DebugEngine) !StopEvent {
        switch (self.*) {
            .gdb => |*e| return e.continue_(),
        }
    }

    pub fn next(self: *DebugEngine) !StopEvent {
        switch (self.*) {
            .gdb => |*e| return e.next(),
        }
    }

    pub fn stepIn(self: *DebugEngine) !StopEvent {
        switch (self.*) {
            .gdb => |*e| return e.stepIn(),
        }
    }

    pub fn stepOut(self: *DebugEngine) !StopEvent {
        switch (self.*) {
            .gdb => |*e| return e.stepOut(),
        }
    }

    pub fn getThreads(self: *DebugEngine) ![]Thread {
        switch (self.*) {
            .gdb => |*e| return e.getThreads(),
        }
    }

    pub fn getStackTrace(self: *DebugEngine, thread_id: u32) ![]Frame {
        switch (self.*) {
            .gdb => |*e| return e.getStackTrace(thread_id),
        }
    }

    pub fn getVariables(self: *DebugEngine, frame_id: u32) ![]Variable {
        switch (self.*) {
            .gdb => |*e| return e.getVariables(frame_id),
        }
    }

    pub fn evaluate(self: *DebugEngine, expr: []const u8) !Variable {
        switch (self.*) {
            .gdb => |*e| return e.evaluate(expr),
        }
    }

    pub fn disconnect(self: *DebugEngine) void {
        switch (self.*) {
            .gdb => |*e| e.disconnect(),
        }
    }
};

/// GDB/LLDB-backed debug engine implementation.
/// Supports both GDB and LLDB via the shared MI protocol.
pub const GdbEngine = struct {
    gdb: gdb_mi.GdbMi,
    allocator: std.mem.Allocator,
    next_bp_id: u32,
    /// Debug info for function name demangling.
    func_debug_infos: []const ir.FunctionDebugInfo,

    pub fn init(allocator: std.mem.Allocator, binary_path: []const u8, func_debug_infos: []const ir.FunctionDebugInfo) !GdbEngine {
        return .{
            .gdb = try gdb_mi.GdbMi.init(allocator, binary_path),
            .allocator = allocator,
            .next_bp_id = 1,
            .func_debug_infos = func_debug_infos,
        };
    }

    /// Initialize with auto-detection of the best available debugger.
    /// Tries GDB first, falls back to LLDB MI.
    pub fn initAutoDetect(allocator: std.mem.Allocator, binary_path: []const u8, func_debug_infos: []const ir.FunctionDebugInfo) !GdbEngine {
        const backend = gdb_mi.GdbMi.detectBackend(allocator) catch
            return error.NoDebuggerFound;
        return .{
            .gdb = try gdb_mi.GdbMi.initWithBackend(allocator, binary_path, backend),
            .allocator = allocator,
            .next_bp_id = 1,
            .func_debug_infos = func_debug_infos,
        };
    }

    pub fn launch(self: *GdbEngine) !void {
        // Wait for GDB to be ready
        _ = try self.gdb.sendCommand("-gdb-set mi-async on");
        // Don't confirm on quit
        _ = try self.gdb.sendCommand("-gdb-set confirm off");
    }

    pub fn setBreakpoint(self: *GdbEngine, file: []const u8, line: u32, condition: ?[]const u8, hit_condition: ?[]const u8) !Breakpoint {
        var cmd_buf: [512]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "-break-insert {s}:{d}", .{ file, line }) catch
            return error.CommandTooLong;
        const response = try self.gdb.sendCommand(cmd);

        const bp_id = self.next_bp_id;
        self.next_bp_id += 1;

        const verified = response.result_class == .done;

        // Extract GDB breakpoint number from response for condition/hit-count commands
        const gdb_bp_num = gdb_mi.extractValue(response.content, "number") orelse "1";

        // Apply conditional expression if provided
        if (condition) |cond| {
            var cond_buf: [512]u8 = undefined;
            const cond_cmd = std.fmt.bufPrint(&cond_buf, "-break-condition {s} {s}", .{ gdb_bp_num, cond }) catch
                return error.CommandTooLong;
            _ = try self.gdb.sendCommand(cond_cmd);
        }

        // Apply hit count if provided
        if (hit_condition) |hit_cond| {
            const count = std.fmt.parseInt(u32, hit_cond, 10) catch 1;
            var hit_buf: [256]u8 = undefined;
            const hit_cmd = std.fmt.bufPrint(&hit_buf, "-break-after {s} {d}", .{ gdb_bp_num, count }) catch
                return error.CommandTooLong;
            _ = try self.gdb.sendCommand(hit_cmd);
        }

        return .{
            .id = bp_id,
            .verified = verified,
            .line = line,
            .source_path = file,
        };
    }

    pub fn removeBreakpoint(self: *GdbEngine, id: u32) !void {
        var cmd_buf: [128]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "-break-delete {d}", .{id}) catch
            return error.CommandTooLong;
        _ = try self.gdb.sendCommand(cmd);
    }

    pub fn continue_(self: *GdbEngine) !StopEvent {
        _ = try self.gdb.sendCommand("-exec-continue");
        const stop = try self.gdb.waitForStop();
        return self.parseStopEvent(stop);
    }

    pub fn next(self: *GdbEngine) !StopEvent {
        _ = try self.gdb.sendCommand("-exec-next");
        const stop = try self.gdb.waitForStop();
        return self.parseStopEvent(stop);
    }

    pub fn stepIn(self: *GdbEngine) !StopEvent {
        _ = try self.gdb.sendCommand("-exec-step");
        const stop = try self.gdb.waitForStop();
        return self.parseStopEvent(stop);
    }

    pub fn stepOut(self: *GdbEngine) !StopEvent {
        _ = try self.gdb.sendCommand("-exec-finish");
        const stop = try self.gdb.waitForStop();
        return self.parseStopEvent(stop);
    }

    pub fn getThreads(self: *GdbEngine) ![]Thread {
        const response = try self.gdb.sendCommand("-thread-info");
        _ = response;

        // Return at least the current thread
        var threads = try self.allocator.alloc(Thread, 1);
        threads[0] = .{ .id = 1, .name = "main" };
        return threads;
    }

    pub fn getStackTrace(self: *GdbEngine, thread_id: u32) ![]Frame {
        var cmd_buf: [128]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "-stack-list-frames --thread {d}", .{thread_id}) catch
            return error.CommandTooLong;
        const response = try self.gdb.sendCommand(cmd);

        // Parse the stack frame list from the response
        // For now return a minimal frame from the content
        _ = response;
        var frames = try self.allocator.alloc(Frame, 1);
        frames[0] = .{
            .id = 0,
            .name = "unknown",
            .source_path = "",
            .line = 0,
            .column = 0,
        };
        return frames;
    }

    pub fn getVariables(self: *GdbEngine, frame_id: u32) ![]Variable {
        var cmd_buf: [128]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "-stack-list-variables --thread 1 --frame {d} --all-values", .{frame_id}) catch
            return error.CommandTooLong;
        const response = try self.gdb.sendCommand(cmd);
        _ = response;

        // Return empty for now — full variable parsing is complex
        return try self.allocator.alloc(Variable, 0);
    }

    pub fn evaluate(self: *GdbEngine, expr: []const u8) !Variable {
        var cmd_buf: [512]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "-data-evaluate-expression \"{s}\"", .{expr}) catch
            return error.CommandTooLong;
        const response = try self.gdb.sendCommand(cmd);

        const value = gdb_mi.extractValue(response.content, "value") orelse "???";
        return .{
            .name = expr,
            .value = value,
            .type_name = "",
        };
    }

    pub fn disconnect(self: *GdbEngine) void {
        self.gdb.deinit();
    }

    /// Demangle a C function name back to the original Run name.
    fn demangleFunctionName(self: *const GdbEngine, mangled: []const u8) []const u8 {
        for (self.func_debug_infos) |fdi| {
            if (std.mem.eql(u8, fdi.mangled_name, mangled)) {
                return fdi.original_name;
            }
        }
        // Strip run_main__ prefix as fallback
        const prefix = "run_main__";
        if (std.mem.startsWith(u8, mangled, prefix)) {
            return mangled[prefix.len..];
        }
        return mangled;
    }

    fn parseStopEvent(self: *const GdbEngine, response: gdb_mi.MiResponse) StopEvent {
        const reason_str = gdb_mi.extractValue(response.content, "reason") orelse "unknown";
        const reason: StopReason = if (std.mem.eql(u8, reason_str, "breakpoint-hit"))
            .breakpoint_hit
        else if (std.mem.eql(u8, reason_str, "end-stepping-range"))
            .step
        else if (std.mem.eql(u8, reason_str, "exited-normally") or std.mem.eql(u8, reason_str, "exited"))
            .exited
        else if (std.mem.eql(u8, reason_str, "signal-received"))
            .exception
        else
            .unknown;

        const file = gdb_mi.extractValue(response.content, "file") orelse "";
        const line_str = gdb_mi.extractValue(response.content, "line") orelse "0";
        const line = std.fmt.parseInt(u32, line_str, 10) catch 0;
        const raw_func = gdb_mi.extractValue(response.content, "func") orelse "";
        const func_name = self.demangleFunctionName(raw_func);

        return .{
            .reason = reason,
            .thread_id = 1,
            .file = file,
            .line = line,
            .function_name = func_name,
        };
    }
};

/// Map C type names to Run type display names.
pub fn runTypeName(c_type: []const u8) []const u8 {
    if (std.mem.eql(u8, c_type, "int64_t")) return "int";
    if (std.mem.eql(u8, c_type, "double")) return "float";
    if (std.mem.eql(u8, c_type, "bool")) return "bool";
    if (std.mem.eql(u8, c_type, "run_string_t")) return "string";
    if (std.mem.eql(u8, c_type, "run_gen_ref_t")) return "&ref";
    if (std.mem.eql(u8, c_type, "run_chan_t*")) return "chan";
    if (std.mem.eql(u8, c_type, "run_map_t*")) return "map";
    if (std.mem.eql(u8, c_type, "void*")) return "ptr";
    if (std.mem.eql(u8, c_type, "void")) return "void";
    return c_type;
}

/// Check if a variable name is an SSA temporary (should be hidden from users).
pub fn isSsaTemporary(name: []const u8) bool {
    if (name.len < 3) return false;
    if (name[0] != '_' or name[1] != 't') return false;
    // Check remaining chars are digits
    for (name[2..]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

// Tests

test "runTypeName: basic mappings" {
    try std.testing.expectEqualStrings("int", runTypeName("int64_t"));
    try std.testing.expectEqualStrings("float", runTypeName("double"));
    try std.testing.expectEqualStrings("string", runTypeName("run_string_t"));
    try std.testing.expectEqualStrings("bool", runTypeName("bool"));
    try std.testing.expectEqualStrings("&ref", runTypeName("run_gen_ref_t"));
    try std.testing.expectEqualStrings("chan", runTypeName("run_chan_t*"));
    try std.testing.expectEqualStrings("map", runTypeName("run_map_t*"));
}

test "runTypeName: unknown passthrough" {
    try std.testing.expectEqualStrings("MyStruct", runTypeName("MyStruct"));
}

test "isSsaTemporary: basic" {
    try std.testing.expect(isSsaTemporary("_t1"));
    try std.testing.expect(isSsaTemporary("_t42"));
    try std.testing.expect(isSsaTemporary("_t123"));
    try std.testing.expect(!isSsaTemporary("x"));
    try std.testing.expect(!isSsaTemporary("myVar"));
    try std.testing.expect(!isSsaTemporary("_tx"));
    try std.testing.expect(!isSsaTemporary("_t")); // too short, no digits
}
