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
const builtin = @import("builtin");

const File = std.Io.File;

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

/// How to locate the C runtime for compilation.
pub const RuntimeConfig = union(enum) {
    /// Pre-built runtime library found at install prefix.
    installed: struct {
        lib_dir: []const u8,
        include_dir: []const u8,
    },
    /// Source directory for development builds (compile .c files directly).
    source: []const u8,
};

/// Try to locate a pre-built librunrt.a relative to the running binary.
/// Expected layout: <prefix>/bin/run, <prefix>/lib/librunrt.a, <prefix>/include/run/*.h
fn findInstalledRuntime(io: std.Io, allocator: std.mem.Allocator) ?struct { lib_dir: []const u8, include_dir: []const u8 } {
    const bin_dir = std.process.executableDirPathAlloc(io, allocator) catch return null;
    defer allocator.free(bin_dir);
    const prefix = std.fs.path.dirname(bin_dir) orelse return null;

    const lib_dir = std.fs.path.join(allocator, &.{ prefix, "lib" }) catch return null;
    const lib_file = std.fs.path.join(allocator, &.{ lib_dir, "librunrt.a" }) catch {
        allocator.free(lib_dir);
        return null;
    };
    defer allocator.free(lib_file);

    // Verify librunrt.a exists at the expected location
    const f = std.Io.Dir.cwd().openFile(io, lib_file, .{}) catch {
        allocator.free(lib_dir);
        return null;
    };
    f.close(io);

    const include_dir = std.fs.path.join(allocator, &.{ prefix, "include", "run" }) catch {
        allocator.free(lib_dir);
        return null;
    };

    return .{ .lib_dir = lib_dir, .include_dir = include_dir };
}

/// Run the full compilation pipeline for the given source file.
pub fn compile(allocator: std.mem.Allocator, options: CompileOptions) CompileError!void {
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_writer = File.stdout().writerStreaming(io, &stdout_buffer);
    var stderr_writer = File.stderr().writerStreaming(io, &stderr_buffer);
    defer stdout_writer.flush() catch {};
    defer stderr_writer.flush() catch {};
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    // 1. Read source file
    const source = readFile(io, allocator, options.input_path) catch {
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

    if (parser.tree.errors.items.len > 0) {
        const use_color = !options.no_color;
        for (parser.tree.errors.items) |err| {
            const found_name = if (err.found) |f| f.displayName() else "unknown";
            const message: []const u8 = switch (err.tag) {
                .expected_token => if (err.expected) |exp|
                    std.fmt.allocPrint(allocator, "expected {s}, found {s}", .{ exp.displayName(), found_name }) catch "expected token"
                else
                    "expected token",
                .expected_expression => blk: {
                    // Check if the found token is invalid due to unterminated literal
                    if (err.found != null and err.found.? == .invalid and err.loc.start < source.len) {
                        if (source[err.loc.start] == '"')
                            break :blk @as([]const u8, "unterminated string literal");
                        if (source[err.loc.start] == '\'')
                            break :blk @as([]const u8, "unterminated character literal");
                    }
                    break :blk std.fmt.allocPrint(allocator, "expected expression, found {s}", .{found_name}) catch "expected expression";
                },
                .expected_type => std.fmt.allocPrint(allocator, "expected type annotation, found {s}", .{found_name}) catch "expected type",
                .expected_identifier => std.fmt.allocPrint(allocator, "expected identifier, found {s}", .{found_name}) catch "expected identifier",
                .expected_package_decl => "expected package declaration",
                .expected_main_entrypoint => "expected main entrypoint",
                .expected_block => std.fmt.allocPrint(allocator, "expected block '{{', found {s}", .{found_name}) catch "expected block",
                .expected_string_literal => std.fmt.allocPrint(allocator, "expected string literal, found {s}", .{found_name}) catch "expected string literal",
                .invalid_token => blk: {
                    // Detect specific invalid token cases from source
                    if (err.loc.start < source.len) {
                        if (source[err.loc.start] == '"')
                            break :blk "unterminated string literal";
                        if (source[err.loc.start] == '\'')
                            break :blk "unterminated character literal";
                    }
                    break :blk "invalid token";
                },
                .invalid_alloc_type => "invalid alloc type: alloc() requires a slice type like '[]T'",
                .expected_asm_register => "expected register name in assembly input binding",
                .expected_arrow_right => "expected '->' in assembly input binding",
                .unexpected_eof => "unexpected end of file",
                .keyword_suggestion => {
                    // Get what the user wrote from the source
                    const wrong_kw = source[err.loc.start..@min(err.loc.end, @as(u32, @intCast(source.len)))];
                    const right_kw = if (err.expected) |exp| exp.displayName() else "'fun'";
                    const msg = std.fmt.allocPrint(allocator, "unknown keyword '{s}'", .{wrong_kw}) catch "unknown keyword";
                    const context = if (err.expected) |exp| switch (exp) {
                        .kw_let => "immutable variables",
                        .kw_var => "mutable variables",
                        else => "functions",
                    } else "functions";
                    const help = std.fmt.allocPrint(allocator, "Run uses {s} to declare {s}", .{ right_kw, context }) catch "Run uses 'fun' to declare functions";
                    const help_ann = [_]diag_mod.Annotation{
                        .{ .kind = .help, .byte_offset = 0, .end_offset = 0, .message = help },
                    };
                    const d = diag_mod.Diagnostic{
                        .severity = .@"error",
                        .byte_offset = err.loc.start,
                        .end_offset = err.loc.end,
                        .message = msg,
                        .annotations = &help_ann,
                    };
                    diag_mod.renderOneDiagnostic(d, source, options.input_path, stderr, use_color) catch {};
                    continue;
                },
                .unnecessary_semicolon => {
                    // Render as error (not warning) since it indicates language confusion
                    const help_ann = [_]diag_mod.Annotation{
                        .{ .kind = .help, .byte_offset = 0, .end_offset = 0, .message = "Run uses newlines as statement separators, not semicolons; remove the ';'" },
                    };
                    const d = diag_mod.Diagnostic{
                        .severity = .@"error",
                        .byte_offset = err.loc.start,
                        .end_offset = err.loc.end,
                        .message = "unnecessary semicolon",
                        .annotations = &help_ann,
                    };
                    diag_mod.renderOneDiagnostic(d, source, options.input_path, stderr, use_color) catch {};
                    continue;
                },
            };
            const d = diag_mod.Diagnostic{
                .severity = .@"error",
                .byte_offset = err.loc.start,
                .end_offset = err.loc.end,
                .message = message,
            };
            diag_mod.renderOneDiagnostic(d, source, options.input_path, stderr, use_color) catch {};
        }
        writeErrorSummary(stderr, parser.tree.errors.items.len, use_color);
        return CompileError.ParseFailed;
    }

    if (!try validateFileConventions(allocator, &parser.tree, tokens.items, source, stderr, options.input_path, !options.no_color)) {
        return CompileError.ConventionFailed;
    }

    // 4. Naming conventions check
    var naming_violations = naming.checkNaming(allocator, options.input_path, &parser.tree, tokens.items) catch {
        return CompileError.OutOfMemory;
    };
    defer naming_violations.deinit(allocator);

    if (naming_violations.items.len > 0) {
        const use_color = !options.no_color;
        for (naming_violations.items) |violation| {
            const rule = switch (violation.tag) {
                .type_must_be_upper_camel => "type names must start with an uppercase letter and use CamelCase",
                .variable_must_be_lower_camel => "variable names must start with a lowercase letter and use camelCase",
                .file_must_be_lower_snake => "file names must start with a lowercase letter and use snake_case",
            };
            const message = std.fmt.allocPrint(allocator, "naming violation: {s}: '{s}'", .{ rule, violation.name }) catch {
                stderr.print("error: naming violation: {s}: '{s}'\n", .{ rule, violation.name }) catch {};
                continue;
            };
            defer allocator.free(message);

            if (violation.loc.start == 0 and violation.loc.end == 0) {
                // File-level violation (no source location)
                stderr.print("error: naming violation: {s}: '{s}' ({s})\n", .{
                    rule,
                    violation.name,
                    options.input_path,
                }) catch {};
            } else {
                // Build help annotation if we can suggest a fix
                const suggestion = naming.suggestFix(allocator, violation.name, violation.tag);
                defer if (suggestion) |s| allocator.free(s);

                var help_annotation: [1]diag_mod.Annotation = undefined;
                var annotation_slice: []const diag_mod.Annotation = &.{};

                if (suggestion) |suggested_name| {
                    const convention = switch (violation.tag) {
                        .type_must_be_upper_camel => "UpperCamelCase",
                        .variable_must_be_lower_camel => "lowerCamelCase",
                        .file_must_be_lower_snake => "lower_snake_case",
                    };
                    if (std.fmt.allocPrint(allocator, "rename to '{s}' ({s})", .{ suggested_name, convention })) |help_msg| {
                        help_annotation[0] = .{ .kind = .help, .byte_offset = 0, .end_offset = 0, .message = help_msg };
                        annotation_slice = &help_annotation;
                    } else |_| {}
                }
                defer if (annotation_slice.len > 0) allocator.free(annotation_slice[0].message);

                const short_label = switch (violation.tag) {
                    .type_must_be_upper_camel => "not UpperCamelCase",
                    .variable_must_be_lower_camel => "not lowerCamelCase",
                    .file_must_be_lower_snake => "not lower_snake_case",
                };
                const d = diag_mod.Diagnostic{
                    .severity = .@"error",
                    .byte_offset = violation.loc.start,
                    .end_offset = violation.loc.end,
                    .message = message,
                    .label = short_label,
                    .annotations = annotation_slice,
                };
                diag_mod.renderOneDiagnostic(d, source, options.input_path, stderr, use_color) catch {};
            }
        }
        return CompileError.NamingFailed;
    }

    // 5. Name resolution
    var resolve_result = resolve.resolveNames(allocator, &parser.tree, tokens.items) catch {
        return CompileError.OutOfMemory;
    };
    defer resolve_result.deinit(allocator);

    if (resolve_result.diagnostics.hasErrors()) {
        resolve_result.diagnostics.renderRich(source, options.input_path, stderr, !options.no_color) catch {};
        writeErrorSummary(stderr, countErrors(&resolve_result.diagnostics), !options.no_color);
        return CompileError.ParseFailed;
    }

    // 6. Type checking
    var tc_result = typecheck.typeCheck(allocator, &parser.tree, tokens.items, &resolve_result) catch {
        return CompileError.OutOfMemory;
    };
    defer tc_result.deinit(allocator);

    if (tc_result.diagnostics.hasErrors()) {
        tc_result.diagnostics.renderRich(source, options.input_path, stderr, !options.no_color) catch {};
        writeErrorSummary(stderr, countErrors(&tc_result.diagnostics), !options.no_color);
        return CompileError.ParseFailed;
    }

    // 6b. Ownership analysis
    var own_result = ownership.analyzeOwnership(allocator, &parser.tree, tokens.items, &resolve_result) catch {
        return CompileError.OutOfMemory;
    };
    defer own_result.deinit();

    if (own_result.diagnostics.hasErrors()) {
        own_result.diagnostics.renderRich(source, options.input_path, stderr, !options.no_color) catch {};
        writeErrorSummary(stderr, countErrors(&own_result.diagnostics), !options.no_color);
        return CompileError.ParseFailed;
    }

    // For "check" command, stop after semantic analysis succeeds.
    if (options.command == .check) {
        stdout.print("check: {s} OK ({d} nodes)\n", .{
            options.input_path,
            parser.tree.nodes.items.len,
        }) catch {};
        return;
    }

    // 7. Lower AST to IR (with source path for debug info)
    var module = if (options.debug)
        lower_mod.lowerWithSource(allocator, &parser.tree, tokens.items, &tc_result, options.input_path) catch {
            return CompileError.OutOfMemory;
        }
    else
        lower_mod.lower(allocator, &parser.tree, tokens.items, &tc_result) catch {
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
        writeErrorSummary(stderr, countErrors(&fold_result.diagnostics), !options.no_color);
        return CompileError.ParseFailed;
    }

    // 7c. Dead code elimination
    if (options.enable_dce) {
        var dce_result = dce.eliminate(allocator, &module) catch {
            return CompileError.OutOfMemory;
        };
        defer dce_result.deinit(allocator);

        const use_color_dce = !options.no_color;
        const warn_color = if (use_color_dce) diag_mod.Color.yellow else "";
        const bold_dce = if (use_color_dce) diag_mod.Color.bold else "";
        const reset_dce = if (use_color_dce) diag_mod.Color.reset else "";
        for (dce_result.warnings.items) |w| {
            switch (w.kind) {
                .unused_function => stderr.print("{s}warning{s}: {s}unused function '{s}'{s}\n", .{ warn_color, reset_dce, bold_dce, w.name, reset_dce }) catch {},
                .unused_variable => if (w.context.len > 0)
                    stderr.print("{s}warning{s}: {s}unused variable '{s}' in function '{s}'{s}\n", .{ warn_color, reset_dce, bold_dce, w.name, w.context, reset_dce }) catch {}
                else
                    stderr.print("{s}warning{s}: {s}unused variable '{s}'{s}\n", .{ warn_color, reset_dce, bold_dce, w.name, reset_dce }) catch {},
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

    // 9. Write C to a unique temp file and compile with zig cc
    const tmp_c = createUniqueTempFile(io, allocator, "run_generated", ".c") catch {
        stderr.writeAll("error: failed to create temp file\n") catch {};
        return CompileError.CCompileFailed;
    };
    const tmp_path = tmp_c.path;
    defer {
        if (!options.debug) std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
        allocator.free(tmp_path);
    }
    {
        defer tmp_c.file.close(io);
        tmp_c.file.writeStreamingAll(io, c_source) catch {
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

    // Find runtime: prefer pre-built library at install prefix, fall back to source compilation.
    const runtime_config: RuntimeConfig = if (findInstalledRuntime(io, allocator)) |installed|
        .{ .installed = .{ .lib_dir = installed.lib_dir, .include_dir = installed.include_dir } }
    else
        .{ .source = "src/runtime" };
    defer switch (runtime_config) {
        .installed => |info| {
            allocator.free(info.lib_dir);
            allocator.free(info.include_dir);
        },
        .source => {},
    };

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
        const rasm_source = readFile(io, allocator, rasm_path) catch continue;
        defer allocator.free(rasm_source);

        var parsed = rasm.parseRasmFile(allocator, rasm_source) catch continue;
        defer parsed.deinit(allocator);

        const gas_source = rasm.generateGasFile(allocator, &parsed, arch) catch continue;
        defer allocator.free(gas_source);

        // Write each generated .S file to its own unique path to avoid races.
        const asm_temp = createUniqueTempFile(io, allocator, std.fs.path.stem(rasm_path), ".S") catch continue;
        const asm_path = asm_temp.path;
        asm_temp.file.writeStreamingAll(io, gas_source) catch {
            asm_temp.file.close(io);
            std.Io.Dir.deleteFileAbsolute(io, asm_path) catch {};
            allocator.free(asm_path);
            continue;
        };
        asm_temp.file.close(io);

        rasm_asm_files.append(allocator, asm_path) catch continue;
    }

    invokeZigCC(io, allocator, tmp_path, out_path, runtime_config, rasm_asm_files.items, options.debug) catch {
        stderr.writeAll("error: C compilation failed\n") catch {};
        return CompileError.CCompileFailed;
    };

    // Clean up temp assembly files (keep in debug mode for source-level debugging)
    if (!options.debug) {
        for (rasm_asm_files.items) |asm_path| {
            std.Io.Dir.deleteFileAbsolute(io, asm_path) catch {};
        }
    }

    if (options.command == .run) {
        // Ensure binary path has ./ prefix for execution
        const exec_path = if (!std.mem.startsWith(u8, out_path, "/") and !std.mem.startsWith(u8, out_path, "./"))
            try std.fmt.allocPrint(allocator, "./{s}", .{out_path})
        else
            out_path;
        const exit_code = executeAndCleanup(io, allocator, exec_path) catch {
            stderr.writeAll("error: failed to execute compiled binary\n") catch {};
            return CompileError.RunFailed;
        };
        if (exit_code != 0) {
            std.process.exit(exit_code);
        }
    } else {
        stdout.print("compiled: {s}\n", .{out_path}) catch {};
    }
}

fn validateFileConventions(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    tokens: []const Token,
    source: []const u8,
    stderr: anytype,
    file_path: []const u8,
    use_color: bool,
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
            .inline_decl => {
                const inline_inner_idx = decl.data.lhs;
                if (inline_inner_idx == 0) continue;
                const inline_inner = tree.nodes.items[inline_inner_idx];
                if (inline_inner.tag == .pub_decl) {
                    const fn_idx = inline_inner.data.lhs;
                    if (fn_idx == 0) continue;
                    const fn_node = tree.nodes.items[fn_idx];
                    if (fn_node.tag == .fn_decl) {
                        const fn_tok = fn_node.main_token;
                        if (fn_tok + 1 < tokens.len and tokens[fn_tok + 1].tag == .identifier) {
                            const fn_name = tokens[fn_tok + 1].slice(source);
                            if (std.mem.eql(u8, fn_name, "main")) {
                                const tok = tokens[fn_tok + 1];
                                const d = diag_mod.Diagnostic{
                                    .severity = .@"error",
                                    .byte_offset = tok.loc.start,
                                    .end_offset = tok.loc.end,
                                    .message = "fun main cannot be inline",
                                    .label = "declared inline here",
                                };
                                diag_mod.renderOneDiagnostic(d, source, file_path, stderr, use_color) catch {};
                                return false;
                            }
                        }
                    }
                }
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
                            const params_start = inner.data.lhs;
                            const extra = tree.extra_data.items;
                            const param_count = findParamCount(params_start, extra);
                            const main_tok = tokens[fn_tok + 1];

                            if (param_count != 0) {
                                const d = diag_mod.Diagnostic{
                                    .severity = .@"error",
                                    .byte_offset = main_tok.loc.start,
                                    .end_offset = main_tok.loc.end,
                                    .message = "fun main must take no parameters",
                                };
                                diag_mod.renderOneDiagnostic(d, source, file_path, stderr, use_color) catch {};
                                return false;
                            }

                            const receiver = extra[params_start + param_count + 1];
                            if (receiver != 0) {
                                const d = diag_mod.Diagnostic{
                                    .severity = .@"error",
                                    .byte_offset = main_tok.loc.start,
                                    .end_offset = main_tok.loc.end,
                                    .message = "fun main must not have a receiver",
                                };
                                diag_mod.renderOneDiagnostic(d, source, file_path, stderr, use_color) catch {};
                                return false;
                            }

                            const ret_type = extra[params_start + param_count + 2];
                            if (ret_type != 0) {
                                const d = diag_mod.Diagnostic{
                                    .severity = .@"error",
                                    .byte_offset = main_tok.loc.start,
                                    .end_offset = main_tok.loc.end,
                                    .message = "fun main must not have a return type",
                                };
                                diag_mod.renderOneDiagnostic(d, source, file_path, stderr, use_color) catch {};
                                return false;
                            }

                            has_pub_main = true;
                        }
                    }
                }
            },
            else => {},
        }
    }

    if (package_name == null) {
        const help_ann = [_]diag_mod.Annotation{
            .{ .kind = .help, .byte_offset = 0, .end_offset = 0, .message = "add 'package <name>' as the first line of the file" },
        };
        const d = diag_mod.Diagnostic{
            .severity = .@"error",
            .byte_offset = 0,
            .end_offset = 0,
            .message = "missing package declaration",
            .annotations = &help_ann,
        };
        diag_mod.renderOneDiagnostic(d, source, file_path, stderr, use_color) catch {};
        return false;
    }

    if (std.mem.eql(u8, package_name.?, "main") and !has_pub_main) {
        const help_ann = [_]diag_mod.Annotation{
            .{ .kind = .help, .byte_offset = 0, .end_offset = 0, .message = "add 'pub fun main() { }' to the file" },
        };
        const d = diag_mod.Diagnostic{
            .severity = .@"error",
            .byte_offset = 0,
            .end_offset = 0,
            .message = "package main must contain `pub fun main`",
            .annotations = &help_ann,
        };
        diag_mod.renderOneDiagnostic(d, source, file_path, stderr, use_color) catch {};
        return false;
    }

    return true;
}

fn countErrors(diags: *const diag_mod.DiagnosticList) usize {
    var count: usize = 0;
    for (diags.diagnostics.items) |d| {
        if (d.severity == .@"error") count += 1;
    }
    return count;
}

fn writeErrorSummary(stderr: anytype, count: usize, use_color: bool) void {
    const red = if (use_color) diag_mod.Color.red else "";
    const bold = if (use_color) diag_mod.Color.bold else "";
    const reset = if (use_color) diag_mod.Color.reset else "";
    if (count == 1) {
        stderr.print("{s}error{s}: {s}aborting due to 1 previous error{s}\n", .{ red, reset, bold, reset }) catch {};
    } else {
        stderr.print("{s}error{s}: {s}aborting due to {d} previous errors{s}\n", .{ red, reset, bold, count, reset }) catch {};
    }
}

fn findParamCount(start: u32, extra: []const u32) u32 {
    var n: u32 = 0;
    while (start + n < extra.len) {
        if (extra[start + n] == n) return n;
        n += 1;
    }
    return 0;
}

/// Invoke zig cc to compile generated C source with the runtime library.
/// `c_source_path` is the path to the generated .c file.
/// `output_path` is the desired binary output path.
/// `runtime` controls how the runtime is linked: pre-built library or source compilation.
pub fn invokeZigCC(
    io: std.Io,
    allocator: std.mem.Allocator,
    c_source_path: []const u8,
    output_path: []const u8,
    runtime: RuntimeConfig,
    extra_asm_files: []const []const u8,
    debug: bool,
) !void {
    // Build argument list
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var env_map = try createProcessEnvMap(allocator);
    defer env_map.deinit();

    const zig_exe = try resolveZigExecutable(io, allocator, &env_map);
    defer allocator.free(zig_exe);

    try args.append(allocator, zig_exe);
    try args.append(allocator, "cc");
    try args.append(allocator, "-o");
    try args.append(allocator, output_path);
    try args.append(allocator, c_source_path);

    switch (runtime) {
        .installed => |info| {
            // Link against pre-built static runtime library
            const lib_path = try std.fs.path.join(allocator, &.{ info.lib_dir, "librunrt.a" });
            try args.append(allocator, lib_path);

            // Link the libxev bridge (provides run_xev_* symbols)
            const xev_lib_path = try std.fs.path.join(allocator, &.{ info.lib_dir, "librunxev.a" });
            // Only link if the file exists (not present with legacy-poller builds)
            if (std.Io.Dir.accessAbsolute(io, xev_lib_path, .{})) |_| {
                try args.append(allocator, xev_lib_path);
            } else |_| {}

            // Include path for installed runtime headers
            const include_flag = try std.fmt.allocPrint(allocator, "-I{s}", .{info.include_dir});
            try args.append(allocator, include_flag);
        },
        .source => |runtime_dir| {
            // Compile individual runtime source files in development mode.
            // This path is exercised by unit/e2e test binaries running from
            // .zig-cache, so keep it self-contained and avoid requiring the
            // separately built libxev Zig bridge.
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
                "run_simd.c",
                "run_numa.c",
                "run_exec.c",
                "run_signal.c",
                "run_runtime_api.c",
                "run_debug_api.c",
                "run_poller_legacy.c",
            };

            for (&runtime_sources) |name| {
                const full_path = try std.fs.path.join(allocator, &.{ runtime_dir, name });
                try args.append(allocator, full_path);
            }

            // Platform-specific assembly for context switching
            const asm_source: ?[]const u8 = switch (@import("builtin").cpu.arch) {
                .x86_64 => "run_context_amd64.S",
                .aarch64 => "run_context_arm64.S",
                else => null,
            };
            if (asm_source) |asm_name| {
                const asm_path = try std.fs.path.join(allocator, &.{ runtime_dir, asm_name });
                try args.append(allocator, asm_path);
            }

            const preempt_asm_source: ?[]const u8 = switch (@import("builtin").cpu.arch) {
                .x86_64 => "run_async_preempt_amd64.S",
                .aarch64 => "run_async_preempt_arm64.S",
                else => null,
            };
            if (preempt_asm_source) |asm_name| {
                const asm_path = try std.fs.path.join(allocator, &.{ runtime_dir, asm_name });
                try args.append(allocator, asm_path);
            }

            // Include path for runtime headers
            const include_flag = try std.fmt.allocPrint(allocator, "-I{s}", .{runtime_dir});
            try args.append(allocator, include_flag);
        },
    }

    // Add extra .rasm-generated assembly files
    for (extra_asm_files) |extra_asm| {
        try args.append(allocator, extra_asm);
    }

    // Disable stack protector — green thread context switching is
    // incompatible with stack canaries.
    try args.append(allocator, "-fno-stack-protector");

    // Enable GNU extensions (sched_getcpu, CPU_ZERO, pthread_setaffinity_np, etc.)
    try args.append(allocator, "-D_GNU_SOURCE");

    // Debug mode: emit DWARF debug info and disable optimizations
    if (debug) {
        try args.append(allocator, "-g");
        try args.append(allocator, "-O0");
        try args.append(allocator, "-fno-inline");
    }

    // Link pthread for scheduler
    try args.append(allocator, "-lpthread");

    var child = try std.process.spawn(io, .{
        .argv = args.items,
        .environ_map = &env_map,
        .expand_arg0 = .expand,
        .stderr = .inherit,
        .stdout = .inherit,
    });
    const term = try child.wait(io);
    if (!childExitedSuccessfully(term)) {
        return error.CCompileFailed;
    }
}

fn createProcessEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    if (builtin.os.tag == .windows) {
        return try std.process.Environ.createMap(.{ .block = .global }, allocator);
    }

    var env_map = std.process.Environ.Map.init(allocator);
    errdefer env_map.deinit();
    if (builtin.link_libc) {
        var env_len: usize = 0;
        while (std.c.environ[env_len] != null) : (env_len += 1) {}
        const env_entries = try allocator.alloc([*:0]const u8, env_len);
        defer allocator.free(env_entries);
        for (env_entries, 0..) |*entry, i| {
            entry.* = std.c.environ[i].?;
        }
        try env_map.putPosixBlock(.{ .slice = env_entries });
    }
    return env_map;
}

fn resolveZigExecutable(
    io: std.Io,
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
) ![]u8 {
    if (env_map.get("PATH")) |path| {
        var it = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
        const exe_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";

        while (it.next()) |dir| {
            const candidate = try std.fs.path.join(allocator, &.{ dir, exe_name });
            errdefer allocator.free(candidate);

            if (std.fs.path.isAbsolute(candidate)) {
                if (std.Io.Dir.accessAbsolute(io, candidate, .{})) |_| return candidate else |_| {}
            } else {
                if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| return candidate else |_| {}
            }

            allocator.free(candidate);
        }
    }

    const fallbacks: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{
            "C:\\Program Files\\zig\\zig.exe",
            "C:\\zig\\zig.exe",
        },
        else => &.{
            "/opt/homebrew/bin/zig",
            "/usr/local/bin/zig",
            "/usr/bin/zig",
        },
    };
    for (fallbacks) |candidate| {
        if (std.Io.Dir.accessAbsolute(io, candidate, .{})) |_| {
            return try allocator.dupe(u8, candidate);
        } else |_| {}
    }

    return error.FileNotFound;
}

/// Execute a compiled binary and return its exit code.
pub fn executeAndCleanup(
    io: std.Io,
    allocator: std.mem.Allocator,
    binary_path: []const u8,
) !u8 {
    _ = allocator;

    var child = try std.process.spawn(io, .{
        .argv = &.{binary_path},
        .stderr = .inherit,
        .stdout = .inherit,
    });
    const result = try child.wait(io);

    // Clean up binary after execution for "run" command
    std.Io.Dir.cwd().deleteFile(io, binary_path) catch {};

    return childExitCode(result);
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024));
}

const TempFile = struct {
    file: std.Io.File,
    path: []u8,
};

fn createUniqueTempFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    suffix: []const u8,
) !TempFile {
    var tmp_dir = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    defer tmp_dir.close(io);

    while (true) {
        var random_bytes: [@sizeOf(u64)]u8 = undefined;
        io.random(&random_bytes);
        const random_id = std.mem.readInt(u64, &random_bytes, .little);
        const basename = try std.fmt.allocPrint(allocator, "run_{s}_{x}{s}", .{ prefix, random_id, suffix });
        errdefer allocator.free(basename);

        const file = tmp_dir.createFile(io, basename, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(basename);
                continue;
            },
            else => return err,
        };

        const path = try std.fs.path.join(allocator, &.{ "/tmp", basename });
        allocator.free(basename);
        return .{ .file = file, .path = path };
    }
}

fn childExitedSuccessfully(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn childExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| if (@intFromEnum(sig) + 128 <= std.math.maxInt(u8)) @as(u8, @intCast(@intFromEnum(sig) + 128)) else std.math.maxInt(u8),
        .stopped, .unknown => 1,
    };
}

test "check performs semantic analysis before succeeding" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "bad_check.run",
        .data =
        \\package main
        \\
        \\pub fun main() {
        \\    missing()
        \\}
        ,
    });

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "bad_check.run", allocator);
    defer allocator.free(path);

    try std.testing.expectError(CompileError.ParseFailed, compile(allocator, .{
        .input_path = path,
        .command = .check,
        .no_color = true,
    }));
}
