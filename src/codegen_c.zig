const std = @import("std");
const ir = @import("ir.zig");

pub const CCodegen = struct {
    output: std.ArrayList(u8),
    module: *const ir.Module,
    allocator: std.mem.Allocator,
    indent_level: u32,

    pub fn init(allocator: std.mem.Allocator, module: *const ir.Module) CCodegen {
        return .{
            .output = .empty,
            .module = module,
            .allocator = allocator,
            .indent_level = 0,
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
        // Function signature
        try self.emitIndent();
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
                        try self.writer().print("{s} {s};\n", .{ info.c_type, info.name });
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
            .alloc_local, .field_ptr, .index_ptr, .gen_alloc, .gen_ref_deref => "void*",
            .gen_get_gen => "uint64_t",
            .gen_ref_create => "run_gen_ref_t",
            .load => "int64_t", // conservative default
            .call => "int64_t", // caller should set proper type
            .chan_recv => "int64_t",
            .chan_new => "run_chan_t*",
            .map_new => "run_map_t*",
            .map_get, .map_delete => "bool",
            .map_len => "size_t",
            .try_unwrap => "int64_t",
            .closure_create => "void*",
            .cast => "int64_t",
            .phi => "int64_t",
            else => "int64_t",
        };
    }

    fn emitInst(self: *CCodegen, inst: ir.Inst) !void {
        switch (inst.op) {
            .const_int => {
                try self.emitIndent();
                try self.writer().print("_t{d} = (int64_t){d};\n", .{ inst.result, @as(i64, @bitCast(@as(u64, inst.arg1))) });
            },
            .const_float => {
                try self.emitIndent();
                // arg1 holds raw bits of float encoded as u32
                try self.writer().print("_t{d} = (double){d};\n", .{ inst.result, inst.arg1 });
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
                try self.emitIndent();
                // arg1 is the index into module.call_infos
                const call_idx = inst.arg1;
                if (call_idx < self.module.call_infos.items.len) {
                    const info = self.module.call_infos.items[call_idx];
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
                try self.writer().print("run_spawn((run_task_fn)_t{d}, (void*)_t{d});\n", .{ inst.arg1, inst.arg2 });
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
                        try self.writer().print("{s} = 0;\n", .{info.name});
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
            .nop => {},
        }
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

    fn writer(self: *CCodegen) std.ArrayList(u8).Writer {
        return self.output.writer(self.allocator);
    }
};

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
