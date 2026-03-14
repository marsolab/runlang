const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Token = @import("token.zig").Token;
const naming = @import("naming.zig");
const Ast = @import("ast.zig").Ast;
const resolve = @import("resolve.zig");
const typecheck = @import("typecheck.zig");
const lower_mod = @import("lower.zig");
const ownership = @import("ownership.zig");
const ir = @import("ir.zig");
const dce = @import("dce.zig");
const const_fold = @import("const_fold.zig");
const codegen_c = @import("codegen_c.zig");
const rasm = @import("rasm.zig");
const diag_mod = @import("diagnostics.zig");

const File = std.fs.File;

pub const Command = enum {
    build,
    run,
    check,
};

pub const CompileOptions = struct {
    input_path: []const u8,
    output_path: ?[]const u8 = null,
    command: Command,
    enable_dce: bool = true,
    no_color: bool = false,
    /// Compile with debug symbols and #line directives for debugger support.
    debug: bool = false,
};

pub const CompileError = error{
    ParseFailed,
    ConventionFailed,
    NamingFailed,
    CodegenNotImplemented,
    CCompileFailed,
    RunFailed,
    OutOfMemory,
    ReadFailed,
};

/// Run the full compilation pipeline for the given source file.
pub fn compile(allocator: std.mem.Allocator, options: CompileOptions) CompileError!void {
    // 1. Read source file
    const source = readFile(allocator, options.input_path) catch {
        return CompileError.ReadFailed;
    };
    defer allocator.free(source);

    // 2. Lex
    var lexer = Lexer.init(source);
    var tokens = lexer.tokenize(allocator) catch {
        return CompileError.OutOfMemory;
    };
    defer tokens.deinit(allocator);

    // 3. Parse
    var parser = Parser.init(allocator, tokens.items, source);
    defer parser.deinit();

    _ = parser.parseFile() catch {
        return CompileError.OutOfMemory;
    };

    const stderr = File.stderr().deprecatedWriter();

    if (parser.tree.errors.items.len > 0) {
        const use_color = !options.no_color;
        for (parser.tree.errors.items) |err| {
            const message = switch (err.tag) {
                .expected_token => "expected token",
                .expected_expression => "expected expression",
                .expected_type => "expected type",
                .expected_identifier => "expected identifier",
                .expected_package_decl => "expected package declaration",
                .expected_main_entrypoint => "expected main entrypoint",
                .expected_block => "expected block",
                .expected_string_literal => "expected string literal",
                .invalid_token => "invalid token",
                .invalid_alloc_type => "invalid alloc type",
                .expected_asm_register => "expected register name in assembly input binding",
                .expected_arrow_right => "expected '->' in assembly input binding",
                .unexpected_eof => "unexpected end of file",
            };
            const d = diag_mod.Diagnostic{
                .severity = .@"error",
                .byte_offset = err.loc.start,
                .end_offset = err.loc.end,
                .message = message,
            };
            diag_mod.renderOneDiagnostic(d, source, options.input_path, stderr, use_color) catch {};
        }
        return CompileError.ParseFailed;
    }

    if (!try validateFileConventions(allocator, &parser.tree, tokens.items, source, stderr)) {
        return CompileError.ConventionFailed;
    }

    // 4. Naming conventions check
    var naming_violations = naming.checkNaming(allocator, options.input_path, &parser.tree, tokens.items) catch {
        return CompileError.OutOfMemory;
    };
    defer naming_violations.deinit(allocator);

    if (naming_violations.items.len > 0) {
        for (naming_violations.items) |violation| {
            const rule = switch (violation.tag) {
                .type_must_be_upper_camel => "type names must start with an uppercase letter and use CamelCase",
                .variable_must_be_lower_camel => "variable names must start with a lowercase letter and use camelCase",
                .file_must_be_lower_snake => "file names must start with a lowercase letter and use snake_case",
            };
            if (violation.loc.start == 0 and violation.loc.end == 0) {
                stderr.print("error: naming violation: {s}: '{s}' ({s})\n", .{
                    rule,
                    violation.name,
                    options.input_path,
                }) catch {};
            } else {
                stderr.print("error: naming violation at offset {d}: {s}: '{s}'\n", .{
                    violation.loc.start,
                    rule,
                    violation.name,
                }) catch {};
            }
        }
        return CompileError.NamingFailed;
    }

    // For "check" command, we stop after validation.
    if (options.command == .check) {
        const stdout = File.stdout().deprecatedWriter();
        stdout.print("check: {s} OK ({d} nodes)\n", .{
            options.input_path,
            parser.tree.nodes.items.len,
        }) catch {};
        return;
    }

    // 5. Name resolution
    var resolve_result = resolve.resolveNames(allocator, &parser.tree, tokens.items) catch {
        return CompileError.OutOfMemory;
    };
    defer resolve_result.deinit(allocator);

    if (resolve_result.diagnostics.hasErrors()) {
        resolve_result.diagnostics.renderRich(source, options.input_path, stderr, !options.no_color) catch {};
        return CompileError.ParseFailed;
    }

    // 6. Type checking
    var tc_result = typecheck.typeCheck(allocator, &parser.tree, tokens.items, &resolve_result) catch {
        return CompileError.OutOfMemory;
    };
    defer tc_result.deinit(allocator);

    if (tc_result.diagnostics.hasErrors()) {
        tc_result.diagnostics.renderRich(source, options.input_path, stderr, !options.no_color) catch {};
        return CompileError.ParseFailed;
    }

    // 6b. Ownership analysis
    var own_result = ownership.analyzeOwnership(allocator, &parser.tree, tokens.items, &resolve_result) catch {
        return CompileError.OutOfMemory;
    };
    defer own_result.deinit();

    if (own_result.diagnostics.hasErrors()) {
        own_result.diagnostics.renderRich(source, options.input_path, stderr, !options.no_color) catch {};
        return CompileError.ParseFailed;
    }

    // 7. Lower AST to IR (with source path for debug info)
    var module = if (options.debug)
        lower_mod.lowerWithSource(allocator, &parser.tree, tokens.items, options.input_path) catch {
            return CompileError.OutOfMemory;
        }
    else
        lower_mod.lower(allocator, &parser.tree, tokens.items) catch {
            return CompileError.OutOfMemory;
        };
    defer module.deinit(allocator);

    // 7b. Constant folding
    var fold_result = const_fold.fold(allocator, &module) catch {
        return CompileError.OutOfMemory;
    };
    defer fold_result.deinit();

    if (fold_result.diagnostics.hasErrors()) {
        fold_result.diagnostics.renderRich(source, options.input_path, stderr, !options.no_color) catch {};
        return CompileError.ParseFailed;
    }

    // 7c. Dead code elimination
    if (options.enable_dce) {
        var dce_result = dce.eliminate(allocator, &module) catch {
            return CompileError.OutOfMemory;
        };
        defer dce_result.deinit(allocator);

        for (dce_result.warnings.items) |w| {
            switch (w.kind) {
                .unused_function => stderr.print("warning: unused function '{s}'\n", .{w.name}) catch {},
                .unused_variable => if (w.context.len > 0)
                    stderr.print("warning: unused variable '{s}' in function '{s}'\n", .{ w.name, w.context }) catch {}
                else
                    stderr.print("warning: unused variable '{s}'\n", .{w.name}) catch {},
            }
        }
    }

    // 8. Generate C code (with #line directives in debug mode)
    var cg = if (options.debug)
        codegen_c.CCodegen.initDebug(allocator, &module, source, options.input_path)
    else
        codegen_c.CCodegen.init(allocator, &module);
    defer cg.deinit();
    const c_source = cg.generate() catch {
        return CompileError.OutOfMemory;
    };

    // 9. Write C to temp file and compile with zig cc
    const tmp_path = "/tmp/run_generated.c";
    {
        const tmp_file = std.fs.cwd().createFile(tmp_path, .{}) catch {
            stderr.writeAll("error: failed to create temp file\n") catch {};
            return CompileError.CCompileFailed;
        };
        defer tmp_file.close();
        tmp_file.writeAll(c_source) catch {
            stderr.writeAll("error: failed to write temp file\n") catch {};
            return CompileError.CCompileFailed;
        };
    }

    // Determine output path
    const out_path = options.output_path orelse blk: {
        // Strip .run extension, default to basename
        const basename = std.fs.path.stem(options.input_path);
        break :blk basename;
    };

    // Find runtime directory (relative to current working dir)
    const runtime_dir = "src/runtime";

    // 9b. Discover and compile .rasm files alongside the source
    const source_dir = std.fs.path.dirname(options.input_path) orelse ".";
    const arch = rasm.Arch.fromBuiltin();
    var rasm_asm_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (rasm_asm_files.items) |path| {
            allocator.free(path);
        }
        rasm_asm_files.deinit(allocator);
    }

    var rasm_files: std.ArrayList([]const u8) = rasm.discoverRasmFiles(allocator, source_dir, arch) catch .empty;
    defer {
        for (rasm_files.items) |path| {
            allocator.free(path);
        }
        rasm_files.deinit(allocator);
    }

    for (rasm_files.items) |rasm_path| {
        const rasm_source = readFile(allocator, rasm_path) catch continue;
        defer allocator.free(rasm_source);

        var parsed = rasm.parseRasmFile(allocator, rasm_source) catch continue;
        defer parsed.deinit(allocator);

        const gas_source = rasm.generateGasFile(allocator, &parsed, arch) catch continue;
        defer allocator.free(gas_source);

        // Write .S file
        const asm_path = std.fmt.allocPrint(allocator, "/tmp/run_rasm_{s}.S", .{
            std.fs.path.stem(rasm_path),
        }) catch continue;

        const asm_file = std.fs.cwd().createFile(asm_path, .{}) catch continue;
        defer asm_file.close();
        asm_file.writeAll(gas_source) catch continue;

        rasm_asm_files.append(allocator, asm_path) catch continue;
    }

    invokeZigCC(allocator, tmp_path, out_path, runtime_dir, rasm_asm_files.items, options.debug) catch {
        stderr.writeAll("error: C compilation failed\n") catch {};
        return CompileError.CCompileFailed;
    };

    // Clean up temp files (keep in debug mode for source-level debugging)
    if (!options.debug) {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        for (rasm_asm_files.items) |asm_path| {
            std.fs.cwd().deleteFile(asm_path) catch {};
        }
    }

    if (options.command == .run) {
        // Ensure binary path has ./ prefix for execution
        const exec_path = if (!std.mem.startsWith(u8, out_path, "/") and !std.mem.startsWith(u8, out_path, "./"))
            try std.fmt.allocPrint(allocator, "./{s}", .{out_path})
        else
            out_path;
        const exit_code = executeAndCleanup(allocator, exec_path) catch {
            stderr.writeAll("error: failed to execute compiled binary\n") catch {};
            return CompileError.RunFailed;
        };
        if (exit_code != 0) {
            std.process.exit(exit_code);
        }
    } else {
        const stdout = File.stdout().deprecatedWriter();
        stdout.print("compiled: {s}\n", .{out_path}) catch {};
    }
}

fn validateFileConventions(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    tokens: []const Token,
    source: []const u8,
    stderr: anytype,
) !bool {
    _ = allocator;

    const root = tree.nodes.items[0];
    const start = root.data.lhs;
    const count = root.data.rhs;
    const decl_indices = tree.extra_data.items[start .. start + count];

    var package_name: ?[]const u8 = null;
    var has_pub_main = false;

    for (decl_indices) |decl_idx| {
        const decl = tree.nodes.items[decl_idx];
        switch (decl.tag) {
            .package_decl => {
                package_name = tokens[decl.main_token].slice(source);
            },
            .pub_decl => {
                const inner_idx = decl.data.lhs;
                if (inner_idx == 0) continue;
                const inner = tree.nodes.items[inner_idx];
                if (inner.tag == .fn_decl) {
                    const fn_tok = inner.main_token;
                    if (fn_tok + 1 < tokens.len and tokens[fn_tok + 1].tag == .identifier) {
                        const fn_name = tokens[fn_tok + 1].slice(source);
                        if (std.mem.eql(u8, fn_name, "main")) {
                            has_pub_main = true;
                        }
                    }
                }
            },
            else => {},
        }
    }

    if (package_name == null) {
        stderr.writeAll("error: missing package declaration; every .run file must begin with `package <name>`\n") catch {};
        return false;
    }

    if (std.mem.eql(u8, package_name.?, "main") and !has_pub_main) {
        stderr.writeAll("error: package main must contain `pub fun main`\n") catch {};
        return false;
    }

    return true;
}

/// Invoke zig cc to compile generated C source with the runtime library.
/// `c_source_path` is the path to the generated .c file.
/// `output_path` is the desired binary output path.
/// `runtime_dir` is the path to the runtime/ directory containing headers and .c files.
pub fn invokeZigCC(
    allocator: std.mem.Allocator,
    c_source_path: []const u8,
    output_path: []const u8,
    runtime_dir: []const u8,
    extra_asm_files: []const []const u8,
    debug: bool,
) !void {
    const runtime_sources = [_][]const u8{
        "run_main.c",
        "run_alloc.c",
        "run_string.c",
        "run_slice.c",
        "run_fmt.c",
        "run_scheduler.c",
        "run_chan.c",
        "run_vmem.c",
        "run_map.c",
    };

    // Platform-specific assembly for context switching
    const asm_source: ?[]const u8 = switch (@import("builtin").cpu.arch) {
        .x86_64 => "run_context_amd64.S",
        .aarch64 => "run_context_arm64.S",
        else => null,
    };

    // Build argument list
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.append(allocator, "zig");
    try args.append(allocator, "cc");
    try args.append(allocator, "-o");
    try args.append(allocator, output_path);
    try args.append(allocator, c_source_path);

    // Add runtime .c files with full paths
    for (&runtime_sources) |name| {
        const full_path = try std.fs.path.join(allocator, &.{ runtime_dir, name });
        try args.append(allocator, full_path);
    }

    // Add assembly file
    if (asm_source) |asm_name| {
        const asm_path = try std.fs.path.join(allocator, &.{ runtime_dir, asm_name });
        try args.append(allocator, asm_path);
    }

    // Add extra .rasm-generated assembly files
    for (extra_asm_files) |extra_asm| {
        try args.append(allocator, extra_asm);
    }

    // Include path for runtime headers
    const include_flag = try std.fmt.allocPrint(allocator, "-I{s}", .{runtime_dir});
    try args.append(allocator, include_flag);

    // Disable stack protector — green thread context switching is
    // incompatible with stack canaries.
    try args.append(allocator, "-fno-stack-protector");

    // Debug mode: emit DWARF debug info and disable optimizations
    if (debug) {
        try args.append(allocator, "-g");
        try args.append(allocator, "-O0");
        try args.append(allocator, "-fno-inline");
    }

    // Link pthread for scheduler
    try args.append(allocator, "-lpthread");

    var child = std.process.Child.init(args.items, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;

    _ = try child.spawnAndWait();
}

/// Execute a compiled binary and return its exit code.
pub fn executeAndCleanup(
    allocator: std.mem.Allocator,
    binary_path: []const u8,
) !u8 {
    var child = std.process.Child.init(&.{binary_path}, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;

    const result = try child.spawnAndWait();

    // Clean up binary after execution for "run" command
    std.fs.cwd().deleteFile(binary_path) catch {};

    return result.Exited;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}
