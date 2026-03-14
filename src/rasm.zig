/// Run Assembly (.rasm) file support.
///
/// .rasm files contain function declarations with assembly bodies.
/// Platform suffixes select architecture-specific implementations:
///   - `file.rasm`       — portable (abstract registers only)
///   - `file_amd64.rasm` — x86-64 specific
///   - `file_arm64.rasm` — ARM64 specific
///
/// The build system selects the correct file: platform-specific takes priority
/// over portable versions. .rasm files are compiled to .S (GAS) files and
/// assembled alongside the generated C code.

const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("token.zig").Token;
const Tag = Token.Tag;

/// Represents a parsed .rasm function declaration.
pub const RasmFunction = struct {
    name: []const u8,
    is_pub: bool,
    params: std.ArrayList(Param),
    return_type: []const u8,
    body: []const u8,

    pub const Param = struct {
        name: []const u8,
        type_name: []const u8,
    };

    pub fn deinit(self: *RasmFunction, allocator: std.mem.Allocator) void {
        self.params.deinit(allocator);
    }
};

/// Result of parsing a .rasm file.
pub const RasmFile = struct {
    functions: std.ArrayList(RasmFunction),

    pub fn deinit(self: *RasmFile, allocator: std.mem.Allocator) void {
        for (self.functions.items) |*f| {
            f.deinit(allocator);
        }
        self.functions.deinit(allocator);
    }
};

/// Parse a .rasm file into function declarations.
pub fn parseRasmFile(allocator: std.mem.Allocator, source: []const u8) !RasmFile {
    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(allocator);
    defer tokens.deinit(allocator);

    var functions: std.ArrayList(RasmFunction) = .empty;
    var pos: u32 = 0;

    while (pos < tokens.items.len) {
        // Skip newlines
        while (pos < tokens.items.len and tokens.items[pos].tag == .newline) {
            pos += 1;
        }
        if (pos >= tokens.items.len or tokens.items[pos].tag == .eof) break;

        // Parse optional `pub`
        var is_pub = false;
        if (tokens.items[pos].tag == .kw_pub) {
            is_pub = true;
            pos += 1;
        }

        // Skip newlines after pub
        while (pos < tokens.items.len and tokens.items[pos].tag == .newline) {
            pos += 1;
        }

        // Expect `fn` or `fun`
        if (pos >= tokens.items.len or tokens.items[pos].tag != .kw_fun) {
            pos += 1;
            continue;
        }
        pos += 1;

        // Function name
        if (pos >= tokens.items.len or tokens.items[pos].tag != .identifier) {
            pos += 1;
            continue;
        }
        const name = tokens.items[pos].slice(source);
        pos += 1;

        // Parameter list
        var params: std.ArrayList(RasmFunction.Param) = .empty;
        if (pos < tokens.items.len and tokens.items[pos].tag == .l_paren) {
            pos += 1;
            while (pos < tokens.items.len and tokens.items[pos].tag != .r_paren) {
                if (tokens.items[pos].tag == .comma or tokens.items[pos].tag == .newline) {
                    pos += 1;
                    continue;
                }
                // param_name type
                if (tokens.items[pos].tag == .identifier) {
                    const param_name = tokens.items[pos].slice(source);
                    pos += 1;
                    var type_name: []const u8 = "int64_t";
                    if (pos < tokens.items.len and tokens.items[pos].tag == .identifier) {
                        type_name = mapRunTypeToCType(tokens.items[pos].slice(source));
                        pos += 1;
                    }
                    try params.append(allocator, .{ .name = param_name, .type_name = type_name });
                } else {
                    pos += 1;
                }
            }
            if (pos < tokens.items.len and tokens.items[pos].tag == .r_paren) {
                pos += 1;
            }
        }

        // Return type (optional, before opening brace)
        var return_type: []const u8 = "void";
        while (pos < tokens.items.len and tokens.items[pos].tag == .newline) {
            pos += 1;
        }
        if (pos < tokens.items.len and tokens.items[pos].tag == .identifier) {
            return_type = mapRunTypeToCType(tokens.items[pos].slice(source));
            pos += 1;
        }

        // Skip to body (opening brace)
        while (pos < tokens.items.len and tokens.items[pos].tag == .newline) {
            pos += 1;
        }

        // Body: everything between { and matching }
        var body: []const u8 = "";
        if (pos < tokens.items.len and tokens.items[pos].tag == .l_brace) {
            const brace_tok = tokens.items[pos];
            pos += 1;
            const body_start = if (pos < tokens.items.len) tokens.items[pos].loc.start else brace_tok.loc.end;
            var depth: u32 = 1;
            while (pos < tokens.items.len and depth > 0) {
                if (tokens.items[pos].tag == .l_brace) depth += 1;
                if (tokens.items[pos].tag == .r_brace) depth -= 1;
                if (depth > 0) pos += 1;
            }
            const body_end = if (pos < tokens.items.len) tokens.items[pos].loc.start else body_start;
            if (pos < tokens.items.len) pos += 1; // skip }
            body = source[body_start..body_end];
        }

        try functions.append(allocator, .{
            .name = name,
            .is_pub = is_pub,
            .params = params,
            .return_type = return_type,
            .body = body,
        });
    }

    return .{ .functions = functions };
}

/// Map Run type names to C type names.
fn mapRunTypeToCType(run_type: []const u8) []const u8 {
    if (std.mem.eql(u8, run_type, "u64") or std.mem.eql(u8, run_type, "i64") or std.mem.eql(u8, run_type, "int")) return "int64_t";
    if (std.mem.eql(u8, run_type, "u32") or std.mem.eql(u8, run_type, "i32")) return "int32_t";
    if (std.mem.eql(u8, run_type, "u16") or std.mem.eql(u8, run_type, "i16")) return "int16_t";
    if (std.mem.eql(u8, run_type, "u8") or std.mem.eql(u8, run_type, "i8")) return "int8_t";
    if (std.mem.eql(u8, run_type, "f32")) return "float";
    if (std.mem.eql(u8, run_type, "f64") or std.mem.eql(u8, run_type, "float")) return "double";
    if (std.mem.eql(u8, run_type, "bool")) return "bool";
    return "int64_t";
}

/// Target architecture for platform selection.
pub const Arch = enum {
    x86_64,
    arm64,
    other,

    pub fn fromBuiltin() Arch {
        return switch (@import("builtin").cpu.arch) {
            .x86_64 => .x86_64,
            .aarch64 => .arm64,
            else => .other,
        };
    }

    pub fn suffix(self: Arch) []const u8 {
        return switch (self) {
            .x86_64 => "_amd64",
            .arm64 => "_arm64",
            .other => "",
        };
    }
};

/// Given a base path (e.g., "math/fast_math"), find the best .rasm file.
/// Platform-specific takes priority over portable.
pub fn selectRasmFile(allocator: std.mem.Allocator, base_path: []const u8, arch: Arch) !?[]const u8 {
    // Try platform-specific first
    const arch_suffix = arch.suffix();
    if (arch_suffix.len > 0) {
        const specific = try std.fmt.allocPrint(allocator, "{s}{s}.rasm", .{ base_path, arch_suffix });
        if (fileExists(specific)) {
            return specific;
        }
        allocator.free(specific);
    }

    // Fall back to portable
    const portable = try std.fmt.allocPrint(allocator, "{s}.rasm", .{base_path});
    if (fileExists(portable)) {
        return portable;
    }
    allocator.free(portable);

    return null;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Generate a GAS-compatible .S assembly file from parsed .rasm functions.
/// The output includes proper function prologues, bodies, and epilogues.
pub fn generateGasFile(allocator: std.mem.Allocator, rasm: *const RasmFile, arch: Arch) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const w = output.writer(allocator);

    // File header
    try w.print("// Generated from .rasm file\n", .{});
    try w.print(".text\n\n", .{});

    for (rasm.functions.items) |func| {
        // Mangle name to match Run calling convention
        try w.print(".globl run_main__{s}\n", .{func.name});
        try w.print("run_main__{s}:\n", .{func.name});

        // Platform-specific prologue
        switch (arch) {
            .x86_64 => {
                try w.print("    pushq %rbp\n", .{});
                try w.print("    movq %rsp, %rbp\n", .{});
            },
            .arm64 => {
                try w.print("    stp x29, x30, [sp, #-16]!\n", .{});
                try w.print("    mov x29, sp\n", .{});
            },
            .other => {},
        }

        // Body — emit raw assembly instructions, trimming whitespace
        const trimmed = std.mem.trim(u8, func.body, " \t\n\r");
        if (trimmed.len > 0) {
            var lines = std.mem.splitScalar(u8, trimmed, '\n');
            while (lines.next()) |line| {
                const tline = std.mem.trim(u8, line, " \t\r");
                if (tline.len > 0) {
                    try w.print("    {s}\n", .{tline});
                }
            }
        }

        // Platform-specific epilogue
        switch (arch) {
            .x86_64 => {
                try w.print("    popq %rbp\n", .{});
                try w.print("    retq\n", .{});
            },
            .arm64 => {
                try w.print("    ldp x29, x30, [sp], #16\n", .{});
                try w.print("    ret\n", .{});
            },
            .other => {
                try w.print("    ret\n", .{});
            },
        }
        try w.print("\n", .{});
    }

    return try allocator.dupe(u8, output.items);
}

/// Discover .rasm files alongside a .run source file.
/// Returns a list of resolved .rasm file paths (platform-specific takes priority).
pub fn discoverRasmFiles(allocator: std.mem.Allocator, source_dir: []const u8, arch: Arch) !std.ArrayList([]const u8) {
    var result: std.ArrayList([]const u8) = .empty;

    var dir = std.fs.cwd().openDir(source_dir, .{ .iterate = true }) catch {
        return result;
    };
    defer dir.close();

    // Collect all .rasm files, then filter by platform priority
    var rasm_bases: std.ArrayList([]const u8) = .empty;
    defer rasm_bases.deinit(allocator);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".rasm")) continue;

        // Extract base name (strip suffix + .rasm)
        const stem = name[0 .. name.len - 5]; // strip .rasm
        const base = stripArchSuffix(stem);
        // Check if this base is already tracked
        var found = false;
        for (rasm_bases.items) |existing| {
            if (std.mem.eql(u8, existing, base)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try rasm_bases.append(allocator, base);
        }
    }

    // For each base, select the best file
    for (rasm_bases.items) |base| {
        const base_path = try std.fs.path.join(allocator, &.{ source_dir, base });
        defer allocator.free(base_path);
        if (try selectRasmFile(allocator, base_path, arch)) |path| {
            try result.append(allocator, path);
        }
    }

    return result;
}

fn stripArchSuffix(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, "_amd64")) return name[0 .. name.len - 6];
    if (std.mem.endsWith(u8, name, "_arm64")) return name[0 .. name.len - 6];
    return name;
}

// Tests

test "parseRasmFile: simple function" {
    const source =
        \\pub fn fast_add(a u64, b u64) u64 {
        \\    add r0, r0, r1
        \\}
    ;
    var result = try parseRasmFile(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.functions.items.len);
    const func = result.functions.items[0];
    try std.testing.expectEqualStrings("fast_add", func.name);
    try std.testing.expect(func.is_pub);
    try std.testing.expectEqual(@as(usize, 2), func.params.items.len);
    try std.testing.expectEqualStrings("a", func.params.items[0].name);
    try std.testing.expectEqualStrings("int64_t", func.params.items[0].type_name);
    try std.testing.expectEqualStrings("int64_t", func.return_type);
}

test "parseRasmFile: no params no return" {
    const source =
        \\fn nop_func() {
        \\    nop
        \\}
    ;
    var result = try parseRasmFile(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.functions.items.len);
    try std.testing.expectEqualStrings("nop_func", result.functions.items[0].name);
    try std.testing.expect(!result.functions.items[0].is_pub);
    try std.testing.expectEqualStrings("void", result.functions.items[0].return_type);
}

test "generateGasFile: x86_64" {
    const source =
        \\pub fn fast_add(a u64, b u64) u64 {
        \\    add r0, r0, r1
        \\}
    ;
    var rasm = try parseRasmFile(std.testing.allocator, source);
    defer rasm.deinit(std.testing.allocator);

    const gas = try generateGasFile(std.testing.allocator, &rasm, .x86_64);
    defer std.testing.allocator.free(gas);

    try std.testing.expect(std.mem.indexOf(u8, gas, "run_main__fast_add:") != null);
    try std.testing.expect(std.mem.indexOf(u8, gas, "pushq %rbp") != null);
    try std.testing.expect(std.mem.indexOf(u8, gas, "retq") != null);
}

test "mapRunTypeToCType" {
    try std.testing.expectEqualStrings("int64_t", mapRunTypeToCType("u64"));
    try std.testing.expectEqualStrings("int64_t", mapRunTypeToCType("int"));
    try std.testing.expectEqualStrings("double", mapRunTypeToCType("f64"));
    try std.testing.expectEqualStrings("float", mapRunTypeToCType("f32"));
    try std.testing.expectEqualStrings("bool", mapRunTypeToCType("bool"));
}

test "Arch: suffix" {
    try std.testing.expectEqualStrings("_amd64", Arch.x86_64.suffix());
    try std.testing.expectEqualStrings("_arm64", Arch.arm64.suffix());
}

test "stripArchSuffix" {
    try std.testing.expectEqualStrings("fast_math", stripArchSuffix("fast_math_amd64"));
    try std.testing.expectEqualStrings("fast_math", stripArchSuffix("fast_math_arm64"));
    try std.testing.expectEqualStrings("fast_math", stripArchSuffix("fast_math"));
}
