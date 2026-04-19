const std = @import("std");
const ir = @import("ir.zig");
const diagnostics = @import("diagnostics.zig");

pub const CCodegen = struct {
    const OutputWriter = struct {
        codegen: *CCodegen,

        pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
            try self.codegen.output.print(self.codegen.allocator, fmt, args);
        }
    };

    output: std.ArrayList(u8),
    module: *const ir.Module,
    allocator: std.mem.Allocator,
    indent_level: u32,
    current_func: ?*const ir.Function,
    vargs_counter: u32 = 0,
    /// Original .run source text for debug line computation (null = no debug).
    debug_source: ?[]const u8 = null,
    /// Original .run source file path for #line directives.
    debug_source_path: ?[]const u8 = null,
    /// Last emitted #line number to avoid duplicate directives.
    last_emitted_line: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, module: *const ir.Module) CCodegen {
        return .{
            .output = .empty,
            .module = module,
            .allocator = allocator,
            .indent_level = 0,
            .current_func = null,
        };
    }

    /// Initialize with debug info for emitting #line directives.
    pub fn initDebug(allocator: std.mem.Allocator, module: *const ir.Module, source: []const u8, source_path: []const u8) CCodegen {
        return .{
            .output = .empty,
            .module = module,
            .allocator = allocator,
            .indent_level = 0,
            .current_func = null,
            .debug_source = source,
            .debug_source_path = source_path,
        };
    }

    pub fn deinit(self: *CCodegen) void {
        self.output.deinit(self.allocator);
    }

    pub fn generate(self: *CCodegen) ![]const u8 {
        try self.emitPreamble();
        try self.emitStringConstants();

        // Emit all function prototypes first
        for (self.module.functions.items) |*func| {
            try self.emitFunctionPrototype(func);
        }
        try self.emitLine("");

        // Emit function bodies
        for (self.module.functions.items) |*func| {
            try self.emitFunction(func);
        }

        return self.output.items;
    }

    fn emitPreamble(self: *CCodegen) !void {
        try self.emitLine("#include \"run_runtime.h\"");
        try self.emitLine("#include \"run_simd.h\"");
        try self.emitLine("");
    }

    fn emitStringConstants(self: *CCodegen) !void {
        if (self.module.string_constants.items.len == 0) return;
        for (self.module.string_constants.items) |sc| {
            try self.emitIndent();
            try self.writer().print("static const char _str_{d}[] = ", .{sc.index});
            try self.emitCString(sc.value);
            try self.writer().print(";\n", .{});
        }
        try self.emitLine("");
    }

    fn emitFunctionPrototype(self: *CCodegen, func: *const ir.Function) !void {
        try self.emitIndent();
        if (func.is_inline) try self.writer().print("static inline ", .{});
        try self.writer().print("{s} {s}(", .{ func.return_type_name, func.name });
        if (func.params.items.len == 0) {
            try self.writer().print("void", .{});
        } else {
            for (func.params.items, 0..) |p, i| {
                if (i > 0) try self.writer().print(", ", .{});
                try self.writer().print("{s} {s}", .{ p.type_name, p.name });
            }
        }
        try self.writer().print(");\n", .{});
    }

    fn emitFunction(self: *CCodegen, func: *const ir.Function) !void {
        self.current_func = func;
        defer self.current_func = null;
        self.last_emitted_line = 0;

        // Emit #line for the function definition if debug info is available
        if (self.debug_source != null) {
            for (self.module.func_debug_infos.items) |fdi| {
                if (std.mem.eql(u8, fdi.mangled_name, func.name)) {
                    try self.emitLineDirective(.{ .byte_offset = fdi.source_byte_offset });
                    break;
                }
            }
        }

        // Function signature
        try self.emitIndent();
        if (func.is_inline) try self.writer().print("static inline ", .{});
        try self.writer().print("{s} {s}(", .{ func.return_type_name, func.name });
        if (func.params.items.len == 0) {
            try self.writer().print("void", .{});
        } else {
            for (func.params.items, 0..) |p, i| {
                if (i > 0) try self.writer().print(", ", .{});
                try self.writer().print("{s} {s}", .{ p.type_name, p.name });
            }
        }
        try self.writer().print(") {{\n", .{});
        self.indent_level += 1;

        // Declare all temporaries used in the function
        try self.emitTempDeclarations(func);

        // Emit basic blocks
        for (func.blocks.items, 0..) |*block, i| {
            if (i > 0) {
                // Emit label for non-entry blocks
                try self.writer().print("block_{d}:\n", .{block.label});
            }
            for (block.insts.items) |inst| {
                try self.emitInst(inst);
            }
        }

        self.indent_level -= 1;
        try self.emitLine("}");
        try self.emitLine("");
    }

    fn emitTempDeclarations(self: *CCodegen, func: *const ir.Function) !void {
        // 1. Emit named local variable declarations (deduplicated)
        var declared_locals: [64]bool = .{false} ** 64;
        for (func.blocks.items) |*block| {
            for (block.insts.items) |inst| {
                if (inst.op == .local_set or inst.op == .local_get) {
                    const local_idx = inst.arg1;
                    if (local_idx < self.module.local_infos.items.len and local_idx < 64 and !declared_locals[local_idx]) {
                        declared_locals[local_idx] = true;
                        const info = self.module.local_infos.items[local_idx];
                        try self.emitIndent();
                        if (info.alignment > 0) {
                            try self.writer().print("{s} {s} __attribute__((aligned({d})));\n", .{ info.c_type, info.name, info.alignment });
                        } else {
                            try self.writer().print("{s} {s};\n", .{ info.c_type, info.name });
                        }
                    }
                }
            }
        }

        // 2. Emit SSA temporary declarations (deduplicated by ref)
        var declared_refs: [256]bool = .{false} ** 256;
        for (func.blocks.items) |*block| {
            for (block.insts.items) |inst| {
                if (inst.result == ir.null_ref) continue;
                if (inst.result >= 256) continue;
                if (declared_refs[inst.result]) continue;
                declared_refs[inst.result] = true;

                var is_param = false;
                for (func.params.items) |p| {
                    if (p.ref == inst.result) {
                        is_param = true;
                        break;
                    }
                }
                if (is_param) continue;

                try self.emitIndent();
                const type_name = self.inferCType(inst);
                try self.writer().print("{s} _t{d};\n", .{ type_name, inst.result });
            }
        }
    }

    fn inferCType(self: *const CCodegen, inst: ir.Inst) []const u8 {
        if (inst.op == .local_get) {
            if (inst.arg1 < self.module.local_infos.items.len) {
                return self.module.local_infos.items[inst.arg1].c_type;
            }
        }
        return switch (inst.op) {
            .const_int, .add, .sub, .mul, .div, .mod, .neg => "int64_t",
            .const_float => "double",
            .const_string => "run_string_t",
            .const_bool, .eq, .ne, .lt, .le, .gt, .ge, .log_and, .log_or, .log_not => "bool",
            .const_null => "void*",
            .alloc_local, .local_addr, .field_ptr, .index_ptr, .gen_alloc, .gen_ref_deref => "void*",
            .gen_get_gen => "uint64_t",
            .gen_ref_create => "run_gen_ref_t",
            .load => "int64_t", // conservative default
            .call => blk: {
                const ci = inst.arg1;
                if (ci < self.module.call_infos.items.len) {
                    break :blk self.module.call_infos.items[ci].return_type_name;
                }
                break :blk "int64_t";
            },
            .chan_recv => "int64_t",
            .chan_new => "run_chan_t*",
            .map_new => "run_map_t*",
            .map_get, .map_delete => "bool",
            .map_len => "size_t",
            .try_unwrap => "int64_t",
            .closure_create => "void*",
            .cast => "int64_t",
            .inline_asm => blk: {
                const ai = inst.arg1;
                if (ai < self.module.asm_infos.items.len) {
                    break :blk self.module.asm_infos.items[ai].return_type;
                }
                break :blk "int64_t";
            },
            .phi => "int64_t",
            else => "int64_t",
        };
    }

    /// Emit a #line directive if debug mode is active and the source line changed.
    fn emitLineDirective(self: *CCodegen, src_loc: ir.SrcLoc) !void {
        if (self.debug_source == null or self.debug_source_path == null) return;
        if (src_loc.byte_offset == 0) return;

        const info = diagnostics.getSourceLine(self.debug_source.?, src_loc.byte_offset);
        if (info.line_number != self.last_emitted_line) {
            self.last_emitted_line = info.line_number;
            try self.writer().print("#line {d} \"{s}\"\n", .{ info.line_number, self.debug_source_path.? });
        }
    }

    fn emitInst(self: *CCodegen, inst: ir.Inst) !void {
        try self.emitLineDirective(inst.src_loc);
        switch (inst.op) {
            .const_int => {
                try self.emitIndent();
                try self.writer().print("_t{d} = (int64_t){d};\n", .{ inst.result, ir.decodeConstInt(inst) });
            },
            .const_float => {
                try self.emitIndent();
                // arg1 is a string constant index containing the float text
                if (inst.arg1 < self.module.string_constants.items.len) {
                    try self.writer().print("_t{d} = {s};\n", .{ inst.result, self.module.string_constants.items[inst.arg1].value });
                } else {
                    try self.writer().print("_t{d} = 0.0;\n", .{inst.result});
                }
            },
            .const_string => {
                try self.emitIndent();
                const str_idx = inst.arg1;
                if (str_idx < self.module.string_constants.items.len) {
                    try self.writer().print("_t{d} = run_string_from_cstr(", .{inst.result});
                    try self.emitCString(self.module.string_constants.items[str_idx].value);
                    try self.writer().print(");\n", .{});
                } else {
                    try self.writer().print("_t{d} = run_string_from_cstr(\"\");\n", .{inst.result});
                }
            },
            .const_bool => {
                try self.emitIndent();
                const val: []const u8 = if (inst.arg1 != 0) "true" else "false";
                try self.writer().print("_t{d} = {s};\n", .{ inst.result, val });
            },
            .const_null => {
                try self.emitIndent();
                try self.writer().print("_t{d} = NULL;\n", .{inst.result});
            },
            .add, .sub, .mul, .div, .mod => {
                try self.emitIndent();
                const op_char: []const u8 = switch (inst.op) {
                    .add => "+",
                    .sub => "-",
                    .mul => "*",
                    .div => "/",
                    .mod => "%",
                    else => unreachable,
                };
                try self.writer().print("_t{d} = _t{d} {s} _t{d};\n", .{ inst.result, inst.arg1, op_char, inst.arg2 });
            },
            .neg => {
                try self.emitIndent();
                try self.writer().print("_t{d} = -_t{d};\n", .{ inst.result, inst.arg1 });
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                try self.emitIndent();
                const op_str: []const u8 = switch (inst.op) {
                    .eq => "==",
                    .ne => "!=",
                    .lt => "<",
                    .le => "<=",
                    .gt => ">",
                    .ge => ">=",
                    else => unreachable,
                };
                try self.writer().print("_t{d} = _t{d} {s} _t{d};\n", .{ inst.result, inst.arg1, op_str, inst.arg2 });
            },
            .log_and => {
                try self.emitIndent();
                try self.writer().print("_t{d} = _t{d} && _t{d};\n", .{ inst.result, inst.arg1, inst.arg2 });
            },
            .log_or => {
                try self.emitIndent();
                try self.writer().print("_t{d} = _t{d} || _t{d};\n", .{ inst.result, inst.arg1, inst.arg2 });
            },
            .log_not => {
                try self.emitIndent();
                try self.writer().print("_t{d} = !_t{d};\n", .{ inst.result, inst.arg1 });
            },
            .alloc_local => {
                try self.emitIndent();
                try self.writer().print("_t{d} = NULL; /* alloc_local */\n", .{inst.result});
            },
            .local_addr => {
                try self.emitIndent();
                const local_name = if (inst.arg1 < self.module.local_infos.items.len)
                    self.module.local_infos.items[inst.arg1].name
                else
                    "_invalid_local";
                try self.writer().print("_t{d} = &{s};\n", .{ inst.result, local_name });
            },
            .load => {
                try self.emitIndent();
                try self.writer().print("_t{d} = *((int64_t*)_t{d});\n", .{ inst.result, inst.arg1 });
            },
            .store => {
                try self.emitIndent();
                try self.writer().print("*((int64_t*)_t{d}) = _t{d};\n", .{ inst.arg1, inst.arg2 });
            },
            .field_ptr => {
                try self.emitIndent();
                try self.writer().print("_t{d} = ((char*)_t{d}) + {d}; /* field_ptr */\n", .{ inst.result, inst.arg1, inst.arg2 });
            },
            .index_ptr => {
                try self.emitIndent();
                try self.writer().print("_t{d} = ((char*)_t{d}) + _t{d}; /* index_ptr */\n", .{ inst.result, inst.arg1, inst.arg2 });
            },
            .gen_alloc => {
                try self.emitIndent();
                try self.writer().print("_t{d} = run_gen_alloc((size_t)_t{d});\n", .{ inst.result, inst.arg1 });
            },
            .gen_free => {
                try self.emitIndent();
                try self.writer().print("run_gen_free(_t{d});\n", .{inst.arg1});
            },
            .gen_check => {
                try self.emitIndent();
                try self.writer().print("run_gen_check(_t{d}, _t{d});\n", .{ inst.arg1, inst.arg2 });
            },
            .gen_get_gen => {
                try self.emitIndent();
                try self.writer().print("_t{d} = run_gen_get(_t{d});\n", .{ inst.result, inst.arg1 });
            },
            .gen_ref_create => {
                try self.emitIndent();
                try self.writer().print("_t{d} = run_gen_ref_create(_t{d});\n", .{ inst.result, inst.arg1 });
            },
            .gen_ref_deref => {
                try self.emitIndent();
                try self.writer().print("_t{d} = run_gen_ref_deref(_t{d});\n", .{ inst.result, inst.arg1 });
            },
            .call => {
                // arg1 is the index into module.call_infos
                const call_idx = inst.arg1;
                if (call_idx < self.module.call_infos.items.len) {
                    const info = self.module.call_infos.items[call_idx];

                    if (info.is_variadic) {
                        try self.emitVariadicFmtCall(inst, info);
                        return;
                    }

                    try self.emitIndent();
                    if (inst.result != ir.null_ref) {
                        try self.writer().print("_t{d} = {s}(", .{ inst.result, info.target_name });
                    } else {
                        try self.writer().print("{s}(", .{info.target_name});
                    }
                    for (info.args.items, 0..) |arg_ref, i| {
                        if (i > 0) try self.writer().print(", ", .{});
                        try self.writer().print("_t{d}", .{arg_ref});
                    }
                    try self.writer().print(");\n", .{});
                } else {
                    try self.emitIndent();
                    // Fallback for calls without call info
                    try self.writer().print("/* unknown call */\n", .{});
                }
            },
            .ret => {
                try self.emitIndent();
                try self.writer().print("return _t{d};\n", .{inst.arg1});
            },
            .ret_void => {
                try self.emitIndent();
                try self.writer().print("return;\n", .{});
            },
            .br => {
                try self.emitIndent();
                try self.writer().print("goto block_{d};\n", .{inst.arg1});
            },
            .br_cond => {
                try self.emitIndent();
                try self.writer().print("if (_t{d}) goto block_{d};\n", .{ inst.arg1, inst.arg2 });
            },
            .spawn => {
                try self.emitIndent();
                const info_idx = inst.arg1;
                if (info_idx < self.module.call_infos.items.len) {
                    const info = self.module.call_infos.items[info_idx];
                    try self.writer().print("run_spawn((run_task_fn){s}, ", .{info.target_name});
                    if (info.args.items.len > 0) {
                        try self.writer().print("(void*)(intptr_t)_t{d}", .{info.args.items[0]});
                    } else {
                        try self.writer().print("NULL", .{});
                    }
                    try self.writer().print(");\n", .{});
                }
            },
            .spawn_on_node => {
                try self.emitIndent();
                const info_idx = inst.arg1;
                if (info_idx < self.module.call_infos.items.len) {
                    const info = self.module.call_infos.items[info_idx];
                    try self.writer().print("run_spawn_on_node((run_task_fn){s}, ", .{info.target_name});
                    if (info.args.items.len > 0) {
                        try self.writer().print("(void*)(intptr_t)_t{d}, ", .{info.args.items[0]});
                    } else {
                        try self.writer().print("NULL, ", .{});
                    }
                    try self.writer().print("(int32_t)_t{d});\n", .{inst.arg2});
                }
            },
            .chan_send => {
                try self.emitIndent();
                try self.writer().print("run_chan_send(_t{d}, &_t{d});\n", .{ inst.arg1, inst.arg2 });
            },
            .chan_recv => {
                try self.emitIndent();
                try self.writer().print("run_chan_recv(_t{d}, &_t{d});\n", .{ inst.arg1, inst.result });
            },
            .chan_new => {
                try self.emitIndent();
                try self.writer().print("_t{d} = run_chan_new((size_t)_t{d}, (size_t)_t{d});\n", .{ inst.result, inst.arg1, inst.arg2 });
            },
            .chan_close => {
                try self.emitIndent();
                try self.writer().print("run_chan_close(_t{d});\n", .{inst.arg1});
            },
            .map_new => {
                try self.emitIndent();
                try self.writer().print("_t{d} = run_map_new((size_t)_t{d}, (size_t)_t{d}, NULL, NULL);\n", .{ inst.result, inst.arg1, inst.arg2 });
            },
            .map_set => {
                try self.emitIndent();
                try self.writer().print("run_map_set(_t{d}, &_t{d}, &_t{d});\n", .{ inst.arg1, inst.arg2, inst.result });
            },
            .map_get => {
                try self.emitIndent();
                try self.writer().print("_t{d} = run_map_get(_t{d}, &_t{d}, &_t{d});\n", .{ inst.result, inst.arg1, inst.arg2, inst.result });
            },
            .map_delete => {
                try self.emitIndent();
                try self.writer().print("_t{d} = run_map_delete(_t{d}, &_t{d});\n", .{ inst.result, inst.arg1, inst.arg2 });
            },
            .map_len => {
                try self.emitIndent();
                try self.writer().print("_t{d} = (int64_t)run_map_len(_t{d});\n", .{ inst.result, inst.arg1 });
            },
            .try_unwrap => {
                try self.emitIndent();
                try self.writer().print("_t{d} = _t{d}; /* try_unwrap */\n", .{ inst.result, inst.arg1 });
            },
            .error_wrap => {
                try self.emitIndent();
                try self.writer().print("_t{d} = _t{d}; /* error_wrap */\n", .{ inst.result, inst.arg1 });
            },
            .closure_create => {
                try self.emitIndent();
                try self.writer().print("_t{d} = NULL; /* closure_create */\n", .{inst.result});
            },
            .cast => {
                try self.emitIndent();
                try self.writer().print("_t{d} = (int64_t)_t{d};\n", .{ inst.result, inst.arg1 });
            },
            .local_set => {
                try self.emitIndent();
                const local_idx = inst.arg1;
                if (local_idx < self.module.local_infos.items.len) {
                    const info = self.module.local_infos.items[local_idx];
                    if (inst.arg2 != ir.null_ref) {
                        try self.writer().print("{s} = _t{d};\n", .{ info.name, inst.arg2 });
                    } else {
                        if (std.mem.eql(u8, info.c_type, "run_gen_ref_t") or
                            std.mem.eql(u8, info.c_type, "run_string_t") or
                            std.mem.eql(u8, info.c_type, "run_any_t") or
                            std.mem.startsWith(u8, info.c_type, "run_simd_"))
                        {
                            try self.writer().print("{s} = ({s}){{0}};\n", .{ info.name, info.c_type });
                        } else {
                            try self.writer().print("{s} = 0;\n", .{info.name});
                        }
                    }
                }
            },
            .local_get => {
                try self.emitIndent();
                const local_idx = inst.arg1;
                if (local_idx < self.module.local_infos.items.len) {
                    const info = self.module.local_infos.items[local_idx];
                    try self.writer().print("_t{d} = {s};\n", .{ inst.result, info.name });
                }
            },
            .phi => {
                try self.emitIndent();
                try self.writer().print("/* phi _t{d} */\n", .{inst.result});
            },
            .inline_asm => {
                try self.emitInlineAsm(inst);
            },
            .nop => {},
        }
    }

    /// Emit a GCC-style inline assembly statement from AsmInfo.
    fn emitInlineAsm(self: *CCodegen, inst: ir.Inst) !void {
        const asm_idx = inst.arg1;
        if (asm_idx >= self.module.asm_infos.items.len) {
            try self.emitIndent();
            try self.writer().print("/* invalid asm_info index */\n", .{});
            return;
        }
        const info = self.module.asm_infos.items[asm_idx];

        try self.emitIndent();

        // Determine if we have an output (result != 0 and return type isn't void)
        const has_output = inst.result != 0 and !std.mem.eql(u8, info.return_type, "void");

        // Start the __asm__ block
        try self.writer().print("__asm__ __volatile__(\n", .{});

        // Emit template — handle platform sections
        try self.emitIndent();
        try self.writer().print("    \"", .{});
        if (info.platform_sections.items.len > 0) {
            // Use platform-specific template based on target
            const target_arch = @import("builtin").cpu.arch;
            var found = false;
            for (info.platform_sections.items) |section| {
                const matches = (target_arch == .x86_64 and std.mem.eql(u8, section.platform, "x86_64")) or
                    (target_arch == .aarch64 and std.mem.eql(u8, section.platform, "arm64"));
                if (matches) {
                    try self.emitAsmTemplate(section.template);
                    found = true;
                    break;
                }
            }
            if (!found and info.template.len > 0) {
                try self.emitAsmTemplate(info.template);
            }
        } else {
            try self.emitAsmTemplate(info.template);
        }
        try self.writer().print("\"\n", .{});

        // Output operands
        try self.emitIndent();
        if (has_output) {
            try self.writer().print("    : \"=r\"(_t{d})\n", .{inst.result});
        } else {
            try self.writer().print("    : /* no outputs */\n", .{});
        }

        // Input operands
        try self.emitIndent();
        try self.writer().print("    : ", .{});
        for (info.inputs.items, 0..) |input, i| {
            if (i > 0) try self.writer().print(", ", .{});
            const constraint = mapRegisterConstraint(input.register);
            try self.writer().print("\"{s}\"(_t{d})", .{ constraint, input.ref });
        }
        try self.writer().print("\n", .{});

        // Clobbers
        try self.emitIndent();
        try self.writer().print("    : ", .{});
        for (info.clobbers.items, 0..) |clobber, i| {
            if (i > 0) try self.writer().print(", ", .{});
            try self.writer().print("\"{s}\"", .{clobber});
        }
        try self.writer().print("\n", .{});

        try self.emitIndent();
        try self.writer().print(");\n", .{});
    }

    /// Emit assembly template text, converting newlines to \\n for GCC inline asm.
    fn emitAsmTemplate(self: *CCodegen, template: []const u8) !void {
        const trimmed = std.mem.trim(u8, template, " \t\n\r");
        var iter = std.mem.splitScalar(u8, trimmed, '\n');
        var first = true;
        while (iter.next()) |line| {
            const tline = std.mem.trim(u8, line, " \t\r");
            if (tline.len == 0) continue;
            if (!first) {
                try self.writer().print("\\n", .{});
            }
            try self.writer().print("{s}", .{tline});
            first = false;
        }
    }

    /// Emit a variadic fmt call: builds a run_any_t array on the stack
    /// and calls the target function with (format, array, count) or (array, count).
    fn emitVariadicFmtCall(self: *CCodegen, inst: ir.Inst, info: ir.CallInfo) !void {
        const target = info.target_name;
        const args = info.args.items;

        // Determine if the target takes a format string as its first arg.
        // printf_args and sprintf_args take (format, args, nargs).
        // println_args, print_args, sprint_args, sprintln_args take (args, nargs).
        const has_format = std.mem.indexOf(u8, target, "printf") != null or
            std.mem.indexOf(u8, target, "sprintf") != null;

        const fmt_arg_count: usize = if (has_format) 1 else 0;
        const variadic_args = args[fmt_arg_count..];

        // Generate a unique array name using a monotonic counter
        const array_id = self.vargs_counter;
        self.vargs_counter += 1;

        if (variadic_args.len > 0) {
            // Emit: run_any_t _vargs_N[] = { run_any_TYPE(_tX), ... };
            try self.emitIndent();
            try self.writer().print("run_any_t _vargs_{d}[] = {{\n", .{array_id});
            self.indent_level += 1;
            for (variadic_args) |arg_ref| {
                try self.emitIndent();
                const arg_type = self.typeNameForRef(arg_ref);
                if (std.mem.eql(u8, arg_type, "run_string_t")) {
                    try self.writer().print("run_any_string(_t{d}),\n", .{arg_ref});
                } else if (std.mem.eql(u8, arg_type, "double")) {
                    try self.writer().print("run_any_float(_t{d}),\n", .{arg_ref});
                } else if (std.mem.eql(u8, arg_type, "bool")) {
                    try self.writer().print("run_any_bool(_t{d}),\n", .{arg_ref});
                } else {
                    // Default to int for int64_t and other numeric types
                    try self.writer().print("run_any_int(_t{d}),\n", .{arg_ref});
                }
            }
            self.indent_level -= 1;
            try self.emitIndent();
            try self.writer().print("}};\n", .{});
        }

        // Emit the actual function call
        try self.emitIndent();
        if (inst.result != ir.null_ref) {
            try self.writer().print("_t{d} = ", .{inst.result});
        }
        try self.writer().print("{s}(", .{target});

        if (has_format and args.len > 0) {
            // First arg is the format string
            try self.writer().print("_t{d}, ", .{args[0]});
        }

        if (variadic_args.len > 0) {
            try self.writer().print("_vargs_{d}, {d}", .{ array_id, variadic_args.len });
        } else {
            try self.writer().print("NULL, 0", .{});
        }

        try self.writer().print(");\n", .{});
    }

    fn emitCString(self: *CCodegen, s: []const u8) !void {
        try self.writer().print("\"", .{});
        for (s) |c| {
            switch (c) {
                '\\' => try self.writer().print("\\\\", .{}),
                '"' => try self.writer().print("\\\"", .{}),
                '\n' => try self.writer().print("\\n", .{}),
                '\r' => try self.writer().print("\\r", .{}),
                '\t' => try self.writer().print("\\t", .{}),
                else => {
                    if (c >= 0x20 and c < 0x7f) {
                        try self.writer().print("{c}", .{c});
                    } else {
                        try self.writer().print("\\x{x:0>2}", .{c});
                    }
                },
            }
        }
        try self.writer().print("\"", .{});
    }

    fn typeNameForRef(self: *const CCodegen, ref: ir.Ref) []const u8 {
        const func = self.current_func orelse return "void*";

        for (func.params.items) |p| {
            if (p.ref == ref) return p.type_name;
        }

        for (func.blocks.items) |*block| {
            for (block.insts.items) |inst| {
                if (inst.result == ref) return self.inferCType(inst);
            }
        }

        return "void*";
    }

    fn emitIndent(self: *CCodegen) !void {
        var i: u32 = 0;
        while (i < self.indent_level) : (i += 1) {
            try self.writer().print("    ", .{});
        }
    }

    fn emitLine(self: *CCodegen, line: []const u8) !void {
        try self.emitIndent();
        try self.output.appendSlice(self.allocator, line);
        try self.output.append(self.allocator, '\n');
    }

    fn print(self: *CCodegen, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        try self.output.print(self.allocator, fmt, args);
    }

    fn writer(self: *CCodegen) OutputWriter {
        return .{ .codegen = self };
    }
};

/// Map abstract register names to GCC/Clang register constraints.
/// Uses target-appropriate constraints for the current compilation platform.
fn mapRegisterConstraint(register: []const u8) []const u8 {
    const arch = @import("builtin").cpu.arch;
    if (arch == .x86_64) {
        // x86-64 System V ABI register mapping
        if (std.mem.eql(u8, register, "r0")) return "a"; // rax
        if (std.mem.eql(u8, register, "r1")) return "b"; // rbx
        if (std.mem.eql(u8, register, "r2")) return "c"; // rcx
        if (std.mem.eql(u8, register, "r3")) return "d"; // rdx
        if (std.mem.eql(u8, register, "r4")) return "S"; // rsi
        if (std.mem.eql(u8, register, "r5")) return "D"; // rdi
        if (std.mem.eql(u8, register, "sp")) return "{rsp}";
        if (std.mem.eql(u8, register, "fp")) return "{rbp}";
    } else if (arch == .aarch64) {
        // ARM64 AAPCS register mapping — all are general purpose "r" constraint
        if (std.mem.eql(u8, register, "sp")) return "{sp}";
        if (std.mem.eql(u8, register, "fp")) return "{x29}";
    }
    // Default: use general-purpose register constraint
    return "r";
}

// Tests

test "CCodegen: empty module" {
    var module = ir.Module.init();
    defer module.deinit(std.testing.allocator);

    var cg = CCodegen.init(std.testing.allocator, &module);
    defer cg.deinit();

    const result = try cg.generate();
    try std.testing.expect(std.mem.indexOf(u8, result, "#include \"run_runtime.h\"") != null);
}

test "CCodegen: hello world" {
    var module = ir.Module.init();
    defer module.deinit(std.testing.allocator);

    // Build: void run_main__main(void) { run_fmt_println("Hello, World!"); }
    const fid = try module.addFunction(std.testing.allocator, "run_main__main");
    var func = module.getFunction(fid);
    func.return_type_name = "void";

    const b0 = try func.addBlock(std.testing.allocator);
    var block = func.getBlock(b0);

    const str_idx = try module.addStringConstant(std.testing.allocator, "Hello, World!");
    const t1 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.const_string, t1, str_idx, 0));

    try block.addInst(std.testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var cg = CCodegen.init(std.testing.allocator, &module);
    defer cg.deinit();

    const result = try cg.generate();

    // Should contain the runtime include
    try std.testing.expect(std.mem.indexOf(u8, result, "#include \"run_runtime.h\"") != null);
    // Should contain the function
    try std.testing.expect(std.mem.indexOf(u8, result, "void run_main__main(void)") != null);
    // Should contain the string constant creation
    try std.testing.expect(std.mem.indexOf(u8, result, "run_string_from_cstr(\"Hello, World!\")") != null);
    // Should contain return
    try std.testing.expect(std.mem.indexOf(u8, result, "return;") != null);
}

test "CCodegen: arithmetic instructions" {
    var module = ir.Module.init();
    defer module.deinit(std.testing.allocator);

    const fid = try module.addFunction(std.testing.allocator, "run_main__add");
    var func = module.getFunction(fid);
    func.return_type_name = "int64_t";

    const b0 = try func.addBlock(std.testing.allocator);
    var block = func.getBlock(b0);

    const t1 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.const_int, t1, 10, 0));

    const t2 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.const_int, t2, 20, 0));

    const t3 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.add, t3, t1, t2));

    try block.addInst(std.testing.allocator, ir.makeInst(.ret, 0, t3, 0));

    var cg = CCodegen.init(std.testing.allocator, &module);
    defer cg.deinit();

    const result = try cg.generate();

    try std.testing.expect(std.mem.indexOf(u8, result, "_t3 = _t1 + _t2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "return _t3;") != null);
}

test "CCodegen: fmt.println emits variadic any array" {
    var module = ir.Module.init();
    defer module.deinit(std.testing.allocator);

    const fid = try module.addFunction(std.testing.allocator, "run_main__main");
    var func = module.getFunction(fid);
    func.return_type_name = "void";

    const b0 = try func.addBlock(std.testing.allocator);
    var block = func.getBlock(b0);

    const str_idx = try module.addStringConstant(std.testing.allocator, "value=");
    const t1 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.const_string, t1, str_idx, 0));

    const t2 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.const_int, t2, 42, 0));

    const t3 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.const_bool, t3, 1, 0));

    const call_idx = try module.addVariadicCallInfo(std.testing.allocator, "run_fmt_println_args", &[_]ir.Ref{ t1, t2, t3 });
    try block.addInst(std.testing.allocator, ir.makeInst(.call, ir.null_ref, call_idx, 0));
    try block.addInst(std.testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var cg = CCodegen.init(std.testing.allocator, &module);
    defer cg.deinit();

    const result = try cg.generate();
    // Should emit run_any_t array with wrapped args
    try std.testing.expect(std.mem.indexOf(u8, result, "run_any_string(_t1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "run_any_int(_t2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "run_any_bool(_t3)") != null);
    // Should call println_args with the array
    try std.testing.expect(std.mem.indexOf(u8, result, "run_fmt_println_args(") != null);
}

test "CCodegen: control flow" {
    var module = ir.Module.init();
    defer module.deinit(std.testing.allocator);

    const fid = try module.addFunction(std.testing.allocator, "run_main__test_br");
    var func = module.getFunction(fid);
    func.return_type_name = "void";

    const b0 = try func.addBlock(std.testing.allocator);
    const b1 = try func.addBlock(std.testing.allocator);

    var block0 = func.getBlock(b0);
    const t1 = func.allocRef();
    try block0.addInst(std.testing.allocator, ir.makeInst(.const_bool, t1, 1, 0));
    try block0.addInst(std.testing.allocator, ir.makeInst(.br_cond, 0, t1, b1));

    var block1 = func.getBlock(b1);
    try block1.addInst(std.testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var cg = CCodegen.init(std.testing.allocator, &module);
    defer cg.deinit();

    const result = try cg.generate();

    try std.testing.expect(std.mem.indexOf(u8, result, "if (_t1) goto block_1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "block_1:") != null);
}

test "CCodegen: string escaping" {
    var module = ir.Module.init();
    defer module.deinit(std.testing.allocator);

    const fid = try module.addFunction(std.testing.allocator, "run_main__escaped");
    var func = module.getFunction(fid);
    func.return_type_name = "void";

    const b0 = try func.addBlock(std.testing.allocator);
    var block = func.getBlock(b0);

    const str_idx = try module.addStringConstant(std.testing.allocator, "hello\n\"world\"");
    const t1 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.const_string, t1, str_idx, 0));
    try block.addInst(std.testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var cg = CCodegen.init(std.testing.allocator, &module);
    defer cg.deinit();

    const result = try cg.generate();

    // Check that the string constant is escaped
    try std.testing.expect(std.mem.indexOf(u8, result, "hello\\n\\\"world\\\"") != null);
}

test "CCodegen: function with parameters" {
    var module = ir.Module.init();
    defer module.deinit(std.testing.allocator);

    const fid = try module.addFunction(std.testing.allocator, "run_main__add_nums");
    var func = module.getFunction(fid);
    func.return_type_name = "int64_t";

    _ = try func.addParam(std.testing.allocator, "a", "int64_t");
    _ = try func.addParam(std.testing.allocator, "b", "int64_t");

    const b0 = try func.addBlock(std.testing.allocator);
    var block = func.getBlock(b0);
    try block.addInst(std.testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var cg = CCodegen.init(std.testing.allocator, &module);
    defer cg.deinit();

    const result = try cg.generate();

    try std.testing.expect(std.mem.indexOf(u8, result, "int64_t run_main__add_nums(int64_t a, int64_t b)") != null);
}

test "CCodegen: generational reference instructions" {
    var module = ir.Module.init();
    defer module.deinit(std.testing.allocator);

    const fid = try module.addFunction(std.testing.allocator, "run_main__gen_test");
    var func = module.getFunction(fid);
    func.return_type_name = "void";

    const b0 = try func.addBlock(std.testing.allocator);
    var block = func.getBlock(b0);

    const t1 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.const_int, t1, 64, 0));

    const t2 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.gen_alloc, t2, t1, 0));

    const t3 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.const_int, t3, 1, 0));
    try block.addInst(std.testing.allocator, ir.makeInst(.gen_check, 0, t2, t3));

    try block.addInst(std.testing.allocator, ir.makeInst(.gen_free, 0, t2, 0));
    try block.addInst(std.testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var cg = CCodegen.init(std.testing.allocator, &module);
    defer cg.deinit();

    const result = try cg.generate();

    try std.testing.expect(std.mem.indexOf(u8, result, "run_gen_alloc") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "run_gen_check") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "run_gen_free") != null);
}

test "CCodegen: generational ref lifecycle (create, deref, get_gen)" {
    var module = ir.Module.init();
    defer module.deinit(std.testing.allocator);

    const fid = try module.addFunction(std.testing.allocator, "run_main__gen_lifecycle");
    var func = module.getFunction(fid);
    func.return_type_name = "void";

    const b0 = try func.addBlock(std.testing.allocator);
    var block = func.getBlock(b0);

    // gen_alloc
    const t1 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.const_int, t1, 64, 0));
    const t2 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.gen_alloc, t2, t1, 0));

    // gen_ref_create
    const t3 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.gen_ref_create, t3, t2, 0));

    // gen_ref_deref
    const t4 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.gen_ref_deref, t4, t3, 0));

    // gen_get_gen
    const t5 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.gen_get_gen, t5, t2, 0));

    // gen_free
    try block.addInst(std.testing.allocator, ir.makeInst(.gen_free, 0, t2, 0));
    try block.addInst(std.testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var cg = CCodegen.init(std.testing.allocator, &module);
    defer cg.deinit();

    const result = try cg.generate();

    try std.testing.expect(std.mem.indexOf(u8, result, "run_gen_alloc((size_t)_t1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "run_gen_ref_create(_t2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "run_gen_ref_deref(_t3)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "run_gen_get(_t2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "run_gen_free(_t2)") != null);

    // Check that the correct types are inferred
    try std.testing.expect(std.mem.indexOf(u8, result, "run_gen_ref_t _t3;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "void* _t4;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "uint64_t _t5;") != null);
}

test "CCodegen: comparison and logical ops" {
    var module = ir.Module.init();
    defer module.deinit(std.testing.allocator);

    const fid = try module.addFunction(std.testing.allocator, "run_main__cmp");
    var func = module.getFunction(fid);
    func.return_type_name = "bool";

    const b0 = try func.addBlock(std.testing.allocator);
    var block = func.getBlock(b0);

    const t1 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.const_int, t1, 5, 0));
    const t2 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.const_int, t2, 10, 0));
    const t3 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.lt, t3, t1, t2));
    const t4 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.log_not, t4, t3, 0));
    try block.addInst(std.testing.allocator, ir.makeInst(.ret, 0, t4, 0));

    var cg = CCodegen.init(std.testing.allocator, &module);
    defer cg.deinit();

    const result = try cg.generate();

    try std.testing.expect(std.mem.indexOf(u8, result, "_t3 = _t1 < _t2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "_t4 = !_t3;") != null);
}

test "CCodegen: SIMD locals are aligned and typed calls preserve return type" {
    var module = ir.Module.init();
    defer module.deinit(std.testing.allocator);

    const fid = try module.addFunction(std.testing.allocator, "run_main__simd");
    var func = module.getFunction(fid);
    func.return_type_name = "void";

    const local_idx = try module.addLocalInfoAligned(std.testing.allocator, "v", "run_simd_v4f32_t", 16);
    const call_idx = try module.addTypedCallInfo(std.testing.allocator, "run_simd_v4f32_add", &.{}, "run_simd_v4f32_t");

    const b0 = try func.addBlock(std.testing.allocator);
    var block = func.getBlock(b0);

    const t1 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.call, t1, call_idx, 0));
    try block.addInst(std.testing.allocator, ir.makeInst(.local_set, 0, local_idx, t1));
    try block.addInst(std.testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var cg = CCodegen.init(std.testing.allocator, &module);
    defer cg.deinit();

    const result = try cg.generate();
    try std.testing.expect(std.mem.indexOf(u8, result, "#include \"run_simd.h\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "run_simd_v4f32_t v __attribute__((aligned(16)));") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "run_simd_v4f32_t _t1;") != null);
}

test "CCodegen: struct-like locals zero initialize with compound literal" {
    var module = ir.Module.init();
    defer module.deinit(std.testing.allocator);

    const fid = try module.addFunction(std.testing.allocator, "run_main__zero");
    var func = module.getFunction(fid);
    func.return_type_name = "void";

    const local_idx = try module.addLocalInfo(std.testing.allocator, "refValue", "run_gen_ref_t");

    const b0 = try func.addBlock(std.testing.allocator);
    var block = func.getBlock(b0);
    try block.addInst(std.testing.allocator, ir.makeInst(.local_set, 0, local_idx, ir.null_ref));
    try block.addInst(std.testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var cg = CCodegen.init(std.testing.allocator, &module);
    defer cg.deinit();

    const result = try cg.generate();
    try std.testing.expect(std.mem.indexOf(u8, result, "refValue = (run_gen_ref_t){0};") != null);
}

test "CCodegen: local_addr takes the address of the declared local" {
    var module = ir.Module.init();
    defer module.deinit(std.testing.allocator);

    const local_idx = try module.addLocalInfo(std.testing.allocator, "vec", "run_simd_v4f32_t");

    const fid = try module.addFunction(std.testing.allocator, "run_main__main");
    var func = module.getFunction(fid);
    func.return_type_name = "void";

    const b0 = try func.addBlock(std.testing.allocator);
    var block = func.getBlock(b0);

    const t1 = func.allocRef();
    try block.addInst(std.testing.allocator, ir.makeInst(.local_addr, t1, local_idx, 0));
    try block.addInst(std.testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var cg = CCodegen.init(std.testing.allocator, &module);
    defer cg.deinit();

    const result = try cg.generate();
    try std.testing.expect(std.mem.indexOf(u8, result, "_t1 = &vec;") != null);
}
