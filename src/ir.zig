const std = @import("std");

pub const Ref = u32;
pub const null_ref: Ref = 0;
pub const BlockId = u32;
pub const FuncId = u32;

/// Source location for debug info, mapping IR instructions back to .run source.
pub const SrcLoc = struct {
    /// Byte offset into the source file (0 = no location).
    byte_offset: u32 = 0,
    /// Index into Module.source_files (for future multi-file support).
    file_index: u16 = 0,
};

/// Debug info for a function, mapping mangled C names back to Run names.
pub const FunctionDebugInfo = struct {
    mangled_name: []const u8,
    original_name: []const u8,
    source_byte_offset: u32,
};

pub const Inst = struct {
    op: Op,
    result: Ref,
    arg1: Ref,
    arg2: Ref,
    /// Source location for debug info (default = no location).
    src_loc: SrcLoc = .{},

    pub const Op = enum(u8) {
        // Constants
        const_int,
        const_float,
        const_string,
        const_bool,
        const_null,

        // Arithmetic
        add,
        sub,
        mul,
        div,
        mod,
        neg,

        // Comparison
        eq,
        ne,
        lt,
        le,
        gt,
        ge,

        // Logical
        log_and,
        log_or,
        log_not,

        // Memory
        alloc_local,
        load,
        store,
        field_ptr,
        index_ptr,

        // Generational references
        gen_alloc,
        gen_free,
        gen_check,
        gen_get_gen, // result = generation of ptr in arg1
        gen_ref_create, // result = run_gen_ref_t from ptr in arg1
        gen_ref_deref, // result = checked ptr from run_gen_ref_t in arg1

        // Function calls
        call,
        ret,
        ret_void,

        // Control flow
        br,
        br_cond,

        // Concurrency
        spawn,
        chan_send,
        chan_recv,
        chan_new,
        chan_close,

        // Map operations
        map_new,     // result = run_map_new(key_size=arg1, val_size=arg2, ...)
        map_set,     // arg1 = map, arg2 = call_info idx (key_ref, val_ref)
        map_get,     // result = found, arg1 = map, arg2 = call_info idx (key_ref, val_out_ref)
        map_delete,  // result = found, arg1 = map, arg2 = key_ref
        map_len,     // result = count, arg1 = map

        // Error handling
        try_unwrap,
        error_wrap,

        // Closures
        closure_create,

        // Type conversion
        cast,

        // Local variables (for C codegen — not SSA)
        local_set, // arg1 = local_idx, arg2 = value ref
        local_get, // result = ref, arg1 = local_idx

        // Inline assembly
        inline_asm, // result = asm output, arg1 = asm_info index in Module.asm_infos

        // SSA / misc
        phi,
        nop,

        pub fn isTerminator(self: Op) bool {
            return switch (self) {
                .br, .br_cond, .ret, .ret_void => true,
                else => false,
            };
        }
    };
};

pub const BasicBlock = struct {
    label: u32,
    insts: std.ArrayList(Inst),

    pub fn init(label: u32) BasicBlock {
        return .{
            .label = label,
            .insts = .empty,
        };
    }

    pub fn deinit(self: *BasicBlock, allocator: std.mem.Allocator) void {
        self.insts.deinit(allocator);
    }

    pub fn addInst(self: *BasicBlock, allocator: std.mem.Allocator, inst: Inst) !void {
        try self.insts.append(allocator, inst);
    }

    pub fn isTerminated(self: *const BasicBlock) bool {
        if (self.insts.items.len == 0) return false;
        return self.insts.items[self.insts.items.len - 1].op.isTerminator();
    }
};

pub const Function = struct {
    name: []const u8,
    params: std.ArrayList(Param),
    return_type_name: []const u8,
    blocks: std.ArrayList(BasicBlock),
    next_ref: Ref,

    pub const Param = struct {
        name: []const u8,
        type_name: []const u8,
        ref: Ref,
    };

    pub fn init(name: []const u8) Function {
        return .{
            .name = name,
            .params = .empty,
            .return_type_name = "void",
            .blocks = .empty,
            .next_ref = 1, // 0 = null_ref
        };
    }

    pub fn deinit(self: *Function, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*b| {
            b.deinit(allocator);
        }
        self.blocks.deinit(allocator);
        self.params.deinit(allocator);
    }

    pub fn allocRef(self: *Function) Ref {
        const r = self.next_ref;
        self.next_ref += 1;
        return r;
    }

    pub fn addBlock(self: *Function, allocator: std.mem.Allocator) !BlockId {
        const id: BlockId = @intCast(self.blocks.items.len);
        try self.blocks.append(allocator, BasicBlock.init(id));
        return id;
    }

    pub fn addParam(self: *Function, allocator: std.mem.Allocator, name: []const u8, type_name: []const u8) !Ref {
        const r = self.allocRef();
        try self.params.append(allocator, .{
            .name = name,
            .type_name = type_name,
            .ref = r,
        });
        return r;
    }

    pub fn getBlock(self: *Function, id: BlockId) *BasicBlock {
        return &self.blocks.items[id];
    }
};

pub const StringConstant = struct {
    value: []const u8,
    index: u32,
};

/// Stores call target and argument info for `call` instructions.
/// The call instruction's arg1 is the index into Module.call_infos.
pub const CallInfo = struct {
    target_name: []const u8,
    args: std.ArrayList(Ref),
    is_variadic: bool = false,

    pub fn deinit(self: *CallInfo, allocator: std.mem.Allocator) void {
        self.args.deinit(allocator);
    }
};

/// Metadata for a named local variable emitted as a C local.
pub const LocalInfo = struct {
    name: []const u8,
    c_type: []const u8,
};

/// Metadata for an inline assembly expression.
pub const AsmInfo = struct {
    /// The assembly template string (raw source text of instructions)
    template: []const u8,
    /// Input operands: each is (register_name, ir_ref)
    inputs: std.ArrayList(AsmOperand),
    /// Clobber register names
    clobbers: std.ArrayList([]const u8),
    /// C return type string, or "void" if no return
    return_type: []const u8,
    /// Platform-conditional sections (optional)
    platform_sections: std.ArrayList(PlatformSection),

    pub const PlatformSection = struct {
        platform: []const u8,
        template: []const u8,
    };

    pub fn deinit(self: *AsmInfo, allocator: std.mem.Allocator) void {
        self.inputs.deinit(allocator);
        self.clobbers.deinit(allocator);
        self.platform_sections.deinit(allocator);
    }
};

pub const AsmOperand = struct {
    register: []const u8,
    ref: Ref,
};

pub const Module = struct {
    functions: std.ArrayList(Function),
    string_constants: std.ArrayList(StringConstant),
    call_infos: std.ArrayList(CallInfo),
    local_infos: std.ArrayList(LocalInfo),
    asm_infos: std.ArrayList(AsmInfo),
    /// Strings allocated by the lowering pass that this module owns.
    owned_strings: std.ArrayList([]const u8),
    /// Source file paths for debug info (indexed by SrcLoc.file_index).
    source_files: std.ArrayList([]const u8),
    /// Debug info mapping mangled function names to original Run names.
    func_debug_infos: std.ArrayList(FunctionDebugInfo),

    pub fn init() Module {
        return .{
            .functions = .empty,
            .string_constants = .empty,
            .call_infos = .empty,
            .local_infos = .empty,
            .asm_infos = .empty,
            .owned_strings = .empty,
            .source_files = .empty,
            .func_debug_infos = .empty,
        };
    }

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        for (self.functions.items) |*f| {
            f.deinit(allocator);
        }
        self.functions.deinit(allocator);
        self.string_constants.deinit(allocator);
        for (self.call_infos.items) |*ci| {
            ci.deinit(allocator);
        }
        self.call_infos.deinit(allocator);
        self.local_infos.deinit(allocator);
        for (self.asm_infos.items) |*ai| {
            ai.deinit(allocator);
        }
        self.asm_infos.deinit(allocator);
        for (self.owned_strings.items) |s| {
            allocator.free(s);
        }
        self.owned_strings.deinit(allocator);
        self.source_files.deinit(allocator);
        self.func_debug_infos.deinit(allocator);
    }

    pub fn addFunction(self: *Module, allocator: std.mem.Allocator, name: []const u8) !FuncId {
        const id: FuncId = @intCast(self.functions.items.len);
        try self.functions.append(allocator, Function.init(name));
        return id;
    }

    pub fn getFunction(self: *Module, id: FuncId) *Function {
        return &self.functions.items[id];
    }

    /// Add call info and return its index. The call instruction's arg1 should
    /// be set to this index so codegen can look up the target name and args.
    pub fn addCallInfo(self: *Module, allocator: std.mem.Allocator, target_name: []const u8, args: []const Ref) !u32 {
        const index: u32 = @intCast(self.call_infos.items.len);
        var arg_list: std.ArrayList(Ref) = .empty;
        for (args) |a| {
            try arg_list.append(allocator, a);
        }
        try self.call_infos.append(allocator, .{
            .target_name = target_name,
            .args = arg_list,
        });
        return index;
    }

    /// Like addCallInfo but marks the call as variadic for codegen.
    pub fn addVariadicCallInfo(self: *Module, allocator: std.mem.Allocator, target_name: []const u8, args: []const Ref) !u32 {
        const index: u32 = @intCast(self.call_infos.items.len);
        var arg_list: std.ArrayList(Ref) = .empty;
        for (args) |a| {
            try arg_list.append(allocator, a);
        }
        try self.call_infos.append(allocator, .{
            .target_name = target_name,
            .args = arg_list,
            .is_variadic = true,
        });
        return index;
    }

    pub fn addLocalInfo(self: *Module, allocator: std.mem.Allocator, name: []const u8, c_type: []const u8) !u32 {
        // Deduplicate by name
        for (self.local_infos.items, 0..) |li, i| {
            if (std.mem.eql(u8, li.name, name)) {
                return @intCast(i);
            }
        }
        const index: u32 = @intCast(self.local_infos.items.len);
        try self.local_infos.append(allocator, .{ .name = name, .c_type = c_type });
        return index;
    }

    pub fn addAsmInfo(self: *Module, allocator: std.mem.Allocator, info: AsmInfo) !u32 {
        const index: u32 = @intCast(self.asm_infos.items.len);
        try self.asm_infos.append(allocator, info);
        return index;
    }

    pub fn addStringConstant(self: *Module, allocator: std.mem.Allocator, value: []const u8) !u32 {
        // Deduplicate: check if this string already exists
        for (self.string_constants.items) |sc| {
            if (std.mem.eql(u8, sc.value, value)) {
                return sc.index;
            }
        }
        const index: u32 = @intCast(self.string_constants.items.len);
        try self.string_constants.append(allocator, .{
            .value = value,
            .index = index,
        });
        return index;
    }
};

/// Helper to build instructions concisely.
pub fn makeInst(op: Inst.Op, result: Ref, arg1: Ref, arg2: Ref) Inst {
    return .{ .op = op, .result = result, .arg1 = arg1, .arg2 = arg2 };
}

/// Helper to build instructions with source location for debug info.
pub fn makeInstWithLoc(op: Inst.Op, result: Ref, arg1: Ref, arg2: Ref, src_loc: SrcLoc) Inst {
    return .{ .op = op, .result = result, .arg1 = arg1, .arg2 = arg2, .src_loc = src_loc };
}

// Tests

test "Module: init and deinit" {
    var module = Module.init();
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), module.functions.items.len);
    try std.testing.expectEqual(@as(usize, 0), module.string_constants.items.len);
}

test "Module: addFunction" {
    var module = Module.init();
    defer module.deinit(std.testing.allocator);

    const id = try module.addFunction(std.testing.allocator, "main");
    try std.testing.expectEqual(@as(FuncId, 0), id);
    try std.testing.expectEqualStrings("main", module.getFunction(id).name);

    const id2 = try module.addFunction(std.testing.allocator, "helper");
    try std.testing.expectEqual(@as(FuncId, 1), id2);
}

test "Module: addStringConstant deduplication" {
    var module = Module.init();
    defer module.deinit(std.testing.allocator);

    const idx1 = try module.addStringConstant(std.testing.allocator, "hello");
    const idx2 = try module.addStringConstant(std.testing.allocator, "world");
    const idx3 = try module.addStringConstant(std.testing.allocator, "hello");

    try std.testing.expectEqual(@as(u32, 0), idx1);
    try std.testing.expectEqual(@as(u32, 1), idx2);
    try std.testing.expectEqual(idx1, idx3); // deduplicated
    try std.testing.expectEqual(@as(usize, 2), module.string_constants.items.len);
}

test "Function: allocRef starts at 1" {
    var func = Function.init("test_fn");
    defer func.deinit(std.testing.allocator);

    const r1 = func.allocRef();
    const r2 = func.allocRef();
    const r3 = func.allocRef();

    try std.testing.expectEqual(@as(Ref, 1), r1);
    try std.testing.expectEqual(@as(Ref, 2), r2);
    try std.testing.expectEqual(@as(Ref, 3), r3);
}

test "Function: addBlock and addParam" {
    var func = Function.init("test_fn");
    defer func.deinit(std.testing.allocator);

    const b0 = try func.addBlock(std.testing.allocator);
    try std.testing.expectEqual(@as(BlockId, 0), b0);

    const p_ref = try func.addParam(std.testing.allocator, "x", "int64_t");
    try std.testing.expectEqual(@as(Ref, 1), p_ref);
    try std.testing.expectEqualStrings("x", func.params.items[0].name);
}

test "BasicBlock: addInst and isTerminated" {
    var block = BasicBlock.init(0);
    defer block.deinit(std.testing.allocator);

    try std.testing.expect(!block.isTerminated());

    try block.addInst(std.testing.allocator, makeInst(.const_int, 1, 42, 0));
    try std.testing.expect(!block.isTerminated());

    try block.addInst(std.testing.allocator, makeInst(.ret, 0, 1, 0));
    try std.testing.expect(block.isTerminated());
}

test "Inst.Op: isTerminator" {
    try std.testing.expect(Inst.Op.br.isTerminator());
    try std.testing.expect(Inst.Op.br_cond.isTerminator());
    try std.testing.expect(Inst.Op.ret.isTerminator());
    try std.testing.expect(Inst.Op.ret_void.isTerminator());
    try std.testing.expect(!Inst.Op.add.isTerminator());
    try std.testing.expect(!Inst.Op.call.isTerminator());
    try std.testing.expect(!Inst.Op.const_int.isTerminator());
}

test "Function: build simple function with instructions" {
    var module = Module.init();
    defer module.deinit(std.testing.allocator);

    const fid = try module.addFunction(std.testing.allocator, "run_main__main");
    var func = module.getFunction(fid);
    func.return_type_name = "void";

    const b0 = try func.addBlock(std.testing.allocator);
    var block = func.getBlock(b0);

    // const_string _t1 = "Hello, World!"
    const str_idx = try module.addStringConstant(std.testing.allocator, "Hello, World!");
    const t1 = func.allocRef();
    try block.addInst(std.testing.allocator, makeInst(.const_string, t1, str_idx, 0));

    // call run_fmt_println(_t1)
    const t2 = func.allocRef();
    try block.addInst(std.testing.allocator, makeInst(.call, t2, t1, 0));

    // ret_void
    try block.addInst(std.testing.allocator, makeInst(.ret_void, 0, 0, 0));

    try std.testing.expectEqual(@as(usize, 3), block.insts.items.len);
    try std.testing.expect(block.isTerminated());
    try std.testing.expectEqual(@as(usize, 1), module.string_constants.items.len);
}

test "null_ref is zero" {
    try std.testing.expectEqual(@as(Ref, 0), null_ref);
}

test "Inst.Op: generational ref ops are not terminators" {
    try std.testing.expect(!Inst.Op.gen_alloc.isTerminator());
    try std.testing.expect(!Inst.Op.gen_free.isTerminator());
    try std.testing.expect(!Inst.Op.gen_check.isTerminator());
    try std.testing.expect(!Inst.Op.gen_get_gen.isTerminator());
    try std.testing.expect(!Inst.Op.gen_ref_create.isTerminator());
    try std.testing.expect(!Inst.Op.gen_ref_deref.isTerminator());
}

test "Function: generational ref alloc and deref sequence" {
    var module = Module.init();
    defer module.deinit(std.testing.allocator);

    const fid = try module.addFunction(std.testing.allocator, "run_main__gen_lifecycle");
    var func = module.getFunction(fid);
    func.return_type_name = "void";

    const b0 = try func.addBlock(std.testing.allocator);
    var block = func.getBlock(b0);

    // Allocate 64 bytes
    const size_ref = func.allocRef();
    try block.addInst(std.testing.allocator, makeInst(.const_int, size_ref, 64, 0));
    const ptr_ref = func.allocRef();
    try block.addInst(std.testing.allocator, makeInst(.gen_alloc, ptr_ref, size_ref, 0));

    // Create a generational reference
    const ref_ref = func.allocRef();
    try block.addInst(std.testing.allocator, makeInst(.gen_ref_create, ref_ref, ptr_ref, 0));

    // Dereference the generational reference (with check)
    const deref_ref = func.allocRef();
    try block.addInst(std.testing.allocator, makeInst(.gen_ref_deref, deref_ref, ref_ref, 0));

    // Get the generation
    const gen_ref = func.allocRef();
    try block.addInst(std.testing.allocator, makeInst(.gen_get_gen, gen_ref, ptr_ref, 0));

    // Free
    try block.addInst(std.testing.allocator, makeInst(.gen_free, 0, ptr_ref, 0));

    // Return
    try block.addInst(std.testing.allocator, makeInst(.ret_void, 0, 0, 0));

    try std.testing.expectEqual(@as(usize, 7), block.insts.items.len);
    try std.testing.expect(block.isTerminated());
    try std.testing.expectEqual(Inst.Op.gen_alloc, block.insts.items[1].op);
    try std.testing.expectEqual(Inst.Op.gen_ref_create, block.insts.items[2].op);
    try std.testing.expectEqual(Inst.Op.gen_ref_deref, block.insts.items[3].op);
    try std.testing.expectEqual(Inst.Op.gen_get_gen, block.insts.items[4].op);
    try std.testing.expectEqual(Inst.Op.gen_free, block.insts.items[5].op);
}
