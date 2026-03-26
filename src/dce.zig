const std = @import("std");
const ir = @import("ir.zig");

pub const DceResult = struct {
    warnings: std.ArrayList(Warning),

    pub const Warning = struct {
        kind: Kind,
        name: []const u8,
        context: []const u8 = "",

        pub const Kind = enum {
            unused_variable,
            unused_function,
        };
    };

    pub fn deinit(self: *DceResult, allocator: std.mem.Allocator) void {
        self.warnings.deinit(allocator);
    }
};

/// Run dead code elimination on the IR module.
/// Removes unreachable functions, eliminates dead branches with constant
/// conditions, and detects/removes unused local variables.
pub fn eliminate(allocator: std.mem.Allocator, module: *ir.Module) !DceResult {
    var result = DceResult{ .warnings = .empty };

    // 1. Find reachable functions via call graph traversal from entry point
    var reachable = try findReachableFunctions(allocator, module);
    defer reachable.deinit(allocator);

    // 2. Remove unreachable functions and emit warnings
    {
        var i: usize = 0;
        while (i < module.functions.items.len) {
            const func = &module.functions.items[i];
            if (!reachable.contains(func.name)) {
                const short_name = stripMangledPrefix(func.name);
                if (!std.mem.startsWith(u8, short_name, "_")) {
                    try result.warnings.append(allocator, .{
                        .kind = .unused_function,
                        .name = short_name,
                    });
                }
                func.deinit(allocator);
                _ = module.functions.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }

    // 3. Per-function optimizations on remaining functions
    for (module.functions.items) |*func| {
        eliminateDeadBranches(func);
        try detectUnusedLocals(allocator, module, func, &result.warnings);
    }

    return result;
}

/// Strip the "run_main__" mangling prefix to get the user-visible name.
fn stripMangledPrefix(name: []const u8) []const u8 {
    const prefix = "run_main__";
    if (std.mem.startsWith(u8, name, prefix)) {
        return name[prefix.len..];
    }
    return name;
}

/// BFS from entry point (run_main__main) over the call graph to find
/// all transitively reachable functions.
fn findReachableFunctions(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
) !std.StringHashMapUnmanaged(void) {
    // Build lookup set of module-local function names
    var func_set: std.StringHashMapUnmanaged(void) = .empty;
    defer func_set.deinit(allocator);
    for (module.functions.items) |*func| {
        try func_set.put(allocator, func.name, {});
    }

    var reachable: std.StringHashMapUnmanaged(void) = .empty;
    var worklist: std.ArrayList([]const u8) = .empty;
    defer worklist.deinit(allocator);

    // Seed with entry point
    if (func_set.contains("run_main__main")) {
        try reachable.put(allocator, "run_main__main", {});
        try worklist.append(allocator, "run_main__main");
    }

    while (worklist.items.len > 0) {
        const name = worklist.orderedRemove(0);

        // Find function and scan its call/spawn targets
        for (module.functions.items) |*func| {
            if (!std.mem.eql(u8, func.name, name)) continue;

            for (func.blocks.items) |*block| {
                for (block.insts.items) |inst| {
                    if (inst.op != .call and inst.op != .spawn and inst.op != .spawn_on_node) continue;
                    if (inst.arg1 >= module.call_infos.items.len) continue;

                    const target = module.call_infos.items[inst.arg1].target_name;
                    if (reachable.contains(target)) continue;
                    if (!func_set.contains(target)) continue; // external/built-in

                    try reachable.put(allocator, target, {});
                    try worklist.append(allocator, target);
                }
            }
            break;
        }
    }

    return reachable;
}

/// Replace br_cond instructions whose condition is a known constant
/// with unconditional br (if true) or nop (if false).
fn eliminateDeadBranches(func: *ir.Function) void {
    var const_bools: [256]?bool = [1]?bool{null} ** 256;

    for (func.blocks.items) |*block| {
        for (block.insts.items) |*inst| {
            switch (inst.op) {
                .const_bool => {
                    if (inst.result > 0 and inst.result < 256) {
                        const_bools[inst.result] = inst.arg1 != 0;
                    }
                },
                .br_cond => {
                    if (inst.arg1 > 0 and inst.arg1 < 256) {
                        if (const_bools[inst.arg1]) |val| {
                            if (val) {
                                // Always true: unconditional branch to target
                                inst.op = .br;
                                inst.arg1 = inst.arg2;
                                inst.arg2 = 0;
                            } else {
                                // Always false: branch never taken
                                inst.op = .nop;
                                inst.result = 0;
                                inst.arg1 = 0;
                                inst.arg2 = 0;
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }
}

/// Detect local variables that are written (local_set) but never read
/// (local_get) within a function. Emits warnings and removes dead stores.
fn detectUnusedLocals(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    func: *ir.Function,
    warnings: *std.ArrayList(DceResult.Warning),
) !void {
    var written = [1]bool{false} ** 256;
    var read = [1]bool{false} ** 256;

    for (func.blocks.items) |*block| {
        for (block.insts.items) |inst| {
            if (inst.op == .local_set and inst.arg1 < 256) written[inst.arg1] = true;
            if (inst.op == .local_get and inst.arg1 < 256) read[inst.arg1] = true;
        }
    }

    // Warn about locals that are written but never read
    for (0..256) |idx| {
        if (written[idx] and !read[idx] and idx < module.local_infos.items.len) {
            const name = module.local_infos.items[idx].name;
            if (!std.mem.startsWith(u8, name, "_")) {
                try warnings.append(allocator, .{
                    .kind = .unused_variable,
                    .name = name,
                    .context = stripMangledPrefix(func.name),
                });
            }
        }
    }

    // Remove local_set instructions for unused locals
    for (func.blocks.items) |*block| {
        var j: usize = 0;
        while (j < block.insts.items.len) {
            const inst = block.insts.items[j];
            if (inst.op == .local_set and inst.arg1 < 256 and written[inst.arg1] and !read[inst.arg1]) {
                _ = block.insts.orderedRemove(j);
                continue;
            }
            j += 1;
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "eliminate: removes unreachable functions" {
    const alloc = std.testing.allocator;
    var module = ir.Module.init();
    defer module.deinit(alloc);

    // main calls helper; unused is never called
    const main_id = try module.addFunction(alloc, "run_main__main");
    {
        var func = module.getFunction(main_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);

        const ci = try module.addCallInfo(alloc, "run_main__helper", &.{});
        const t1 = func.allocRef();
        try block.addInst(alloc, ir.makeInst(.call, t1, ci, 0));
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    const helper_id = try module.addFunction(alloc, "run_main__helper");
    {
        var func = module.getFunction(helper_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    const unused_id = try module.addFunction(alloc, "run_main__unused");
    {
        var func = module.getFunction(unused_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    try std.testing.expectEqual(@as(usize, 3), module.functions.items.len);

    var result = try eliminate(alloc, &module);
    defer result.deinit(alloc);

    // Only main and helper should remain
    try std.testing.expectEqual(@as(usize, 2), module.functions.items.len);
    try std.testing.expectEqualStrings("run_main__main", module.functions.items[0].name);
    try std.testing.expectEqualStrings("run_main__helper", module.functions.items[1].name);

    // Warning for unused function
    try std.testing.expectEqual(@as(usize, 1), result.warnings.items.len);
    try std.testing.expectEqual(DceResult.Warning.Kind.unused_function, result.warnings.items[0].kind);
    try std.testing.expectEqualStrings("unused", result.warnings.items[0].name);
}

test "eliminate: transitive reachability" {
    const alloc = std.testing.allocator;
    var module = ir.Module.init();
    defer module.deinit(alloc);

    // main → a → b; c is unreachable
    const main_id = try module.addFunction(alloc, "run_main__main");
    {
        var func = module.getFunction(main_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        const ci = try module.addCallInfo(alloc, "run_main__a", &.{});
        const t1 = func.allocRef();
        try block.addInst(alloc, ir.makeInst(.call, t1, ci, 0));
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    const a_id = try module.addFunction(alloc, "run_main__a");
    {
        var func = module.getFunction(a_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        const ci = try module.addCallInfo(alloc, "run_main__b", &.{});
        const t1 = func.allocRef();
        try block.addInst(alloc, ir.makeInst(.call, t1, ci, 0));
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    const b_id = try module.addFunction(alloc, "run_main__b");
    {
        var func = module.getFunction(b_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    const c_id = try module.addFunction(alloc, "run_main__c");
    {
        var func = module.getFunction(c_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    var result = try eliminate(alloc, &module);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), module.functions.items.len);
    try std.testing.expectEqualStrings("run_main__main", module.functions.items[0].name);
    try std.testing.expectEqualStrings("run_main__a", module.functions.items[1].name);
    try std.testing.expectEqualStrings("run_main__b", module.functions.items[2].name);
}

test "eliminate: spawn targets are reachable" {
    const alloc = std.testing.allocator;
    var module = ir.Module.init();
    defer module.deinit(alloc);

    const main_id = try module.addFunction(alloc, "run_main__main");
    {
        var func = module.getFunction(main_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        const ci = try module.addCallInfo(alloc, "run_main__worker", &.{});
        try block.addInst(alloc, ir.makeInst(.spawn, 0, ci, 0));
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    const worker_id = try module.addFunction(alloc, "run_main__worker");
    {
        var func = module.getFunction(worker_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    var result = try eliminate(alloc, &module);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), module.functions.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.items.len);
}

test "eliminate: spawn_on_node targets are reachable" {
    const alloc = std.testing.allocator;
    var module = ir.Module.init();
    defer module.deinit(alloc);

    const main_id = try module.addFunction(alloc, "run_main__main");
    {
        var func = module.getFunction(main_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        const ci = try module.addCallInfo(alloc, "run_main__worker", &.{});
        try block.addInst(alloc, ir.makeInst(.spawn_on_node, 0, ci, 0));
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    const worker_id = try module.addFunction(alloc, "run_main__worker");
    {
        var func = module.getFunction(worker_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    var result = try eliminate(alloc, &module);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), module.functions.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.items.len);
}

test "eliminate: _ prefix suppresses unused function warning" {
    const alloc = std.testing.allocator;
    var module = ir.Module.init();
    defer module.deinit(alloc);

    const main_id = try module.addFunction(alloc, "run_main__main");
    {
        var func = module.getFunction(main_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    const unused_id = try module.addFunction(alloc, "run_main___hidden");
    {
        var func = module.getFunction(unused_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    var result = try eliminate(alloc, &module);
    defer result.deinit(alloc);

    // Function removed but no warning due to _ prefix
    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.items.len);
}

test "eliminateDeadBranches: constant true replaces br_cond with br" {
    const alloc = std.testing.allocator;
    var func = ir.Function.init("test");
    defer func.deinit(alloc);

    const b0 = try func.addBlock(alloc);
    var block = func.getBlock(b0);

    const t1 = func.allocRef();
    try block.addInst(alloc, ir.makeInst(.const_bool, t1, 1, 0));
    try block.addInst(alloc, ir.makeInst(.br_cond, 0, t1, 5));

    eliminateDeadBranches(&func);

    const inst = block.insts.items[1];
    try std.testing.expectEqual(ir.Inst.Op.br, inst.op);
    try std.testing.expectEqual(@as(ir.Ref, 5), inst.arg1);
}

test "eliminateDeadBranches: constant false replaces br_cond with nop" {
    const alloc = std.testing.allocator;
    var func = ir.Function.init("test");
    defer func.deinit(alloc);

    const b0 = try func.addBlock(alloc);
    var block = func.getBlock(b0);

    const t1 = func.allocRef();
    try block.addInst(alloc, ir.makeInst(.const_bool, t1, 0, 0));
    try block.addInst(alloc, ir.makeInst(.br_cond, 0, t1, 5));

    eliminateDeadBranches(&func);

    const inst = block.insts.items[1];
    try std.testing.expectEqual(ir.Inst.Op.nop, inst.op);
}

test "eliminateDeadBranches: non-constant condition preserved" {
    const alloc = std.testing.allocator;
    var func = ir.Function.init("test");
    defer func.deinit(alloc);

    const b0 = try func.addBlock(alloc);
    var block = func.getBlock(b0);

    // br_cond with a ref that's not from const_bool
    try block.addInst(alloc, ir.makeInst(.br_cond, 0, 3, 5));

    eliminateDeadBranches(&func);

    try std.testing.expectEqual(ir.Inst.Op.br_cond, block.insts.items[0].op);
}

test "detectUnusedLocals: warns about unused variable" {
    const alloc = std.testing.allocator;
    var module = ir.Module.init();
    defer module.deinit(alloc);

    const local_idx = try module.addLocalInfo(alloc, "x", "int64_t");

    const fid = try module.addFunction(alloc, "run_main__main");
    var func = module.getFunction(fid);
    func.return_type_name = "void";
    const b0 = try func.addBlock(alloc);
    var block = func.getBlock(b0);

    const t1 = func.allocRef();
    try block.addInst(alloc, ir.makeInst(.const_int, t1, 42, 0));
    try block.addInst(alloc, ir.makeInst(.local_set, 0, local_idx, t1));
    try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));

    var warnings: std.ArrayList(DceResult.Warning) = .empty;
    defer warnings.deinit(alloc);

    try detectUnusedLocals(alloc, &module, func, &warnings);

    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    try std.testing.expectEqual(DceResult.Warning.Kind.unused_variable, warnings.items[0].kind);
    try std.testing.expectEqualStrings("x", warnings.items[0].name);

    // local_set should be removed
    try std.testing.expectEqual(@as(usize, 2), block.insts.items.len);
    try std.testing.expectEqual(ir.Inst.Op.const_int, block.insts.items[0].op);
    try std.testing.expectEqual(ir.Inst.Op.ret_void, block.insts.items[1].op);
}

test "detectUnusedLocals: used variable not warned" {
    const alloc = std.testing.allocator;
    var module = ir.Module.init();
    defer module.deinit(alloc);

    const local_idx = try module.addLocalInfo(alloc, "x", "int64_t");

    const fid = try module.addFunction(alloc, "run_main__main");
    var func = module.getFunction(fid);
    func.return_type_name = "void";
    const b0 = try func.addBlock(alloc);
    var block = func.getBlock(b0);

    const t1 = func.allocRef();
    try block.addInst(alloc, ir.makeInst(.const_int, t1, 42, 0));
    try block.addInst(alloc, ir.makeInst(.local_set, 0, local_idx, t1));
    const t2 = func.allocRef();
    try block.addInst(alloc, ir.makeInst(.local_get, t2, local_idx, 0));
    try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));

    var warnings: std.ArrayList(DceResult.Warning) = .empty;
    defer warnings.deinit(alloc);

    try detectUnusedLocals(alloc, &module, func, &warnings);

    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    try std.testing.expectEqual(@as(usize, 4), block.insts.items.len);
}

test "detectUnusedLocals: _ prefix suppresses warning" {
    const alloc = std.testing.allocator;
    var module = ir.Module.init();
    defer module.deinit(alloc);

    const local_idx = try module.addLocalInfo(alloc, "_unused", "int64_t");

    const fid = try module.addFunction(alloc, "run_main__main");
    var func = module.getFunction(fid);
    func.return_type_name = "void";
    const b0 = try func.addBlock(alloc);
    var block = func.getBlock(b0);

    const t1 = func.allocRef();
    try block.addInst(alloc, ir.makeInst(.const_int, t1, 0, 0));
    try block.addInst(alloc, ir.makeInst(.local_set, 0, local_idx, t1));
    try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));

    var warnings: std.ArrayList(DceResult.Warning) = .empty;
    defer warnings.deinit(alloc);

    try detectUnusedLocals(alloc, &module, func, &warnings);

    // No warning, but local_set still removed
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    try std.testing.expectEqual(@as(usize, 2), block.insts.items.len);
}

test "eliminate: idempotent" {
    const alloc = std.testing.allocator;
    var module = ir.Module.init();
    defer module.deinit(alloc);

    const main_id = try module.addFunction(alloc, "run_main__main");
    {
        var func = module.getFunction(main_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    _ = try module.addFunction(alloc, "run_main__dead");
    {
        var func = module.getFunction(1);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    // First pass
    var r1 = try eliminate(alloc, &module);
    defer r1.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);

    // Second pass — should produce identical result
    var r2 = try eliminate(alloc, &module);
    defer r2.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    try std.testing.expectEqual(@as(usize, 0), r2.warnings.items.len);
}

test "eliminate: entry point always preserved" {
    const alloc = std.testing.allocator;
    var module = ir.Module.init();
    defer module.deinit(alloc);

    const main_id = try module.addFunction(alloc, "run_main__main");
    {
        var func = module.getFunction(main_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    var result = try eliminate(alloc, &module);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    try std.testing.expectEqualStrings("run_main__main", module.functions.items[0].name);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.items.len);
}

test "eliminate: recursive function stays reachable" {
    const alloc = std.testing.allocator;
    var module = ir.Module.init();
    defer module.deinit(alloc);

    const main_id = try module.addFunction(alloc, "run_main__main");
    {
        var func = module.getFunction(main_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        const ci = try module.addCallInfo(alloc, "run_main__recurse", &.{});
        const t1 = func.allocRef();
        try block.addInst(alloc, ir.makeInst(.call, t1, ci, 0));
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    const rec_id = try module.addFunction(alloc, "run_main__recurse");
    {
        var func = module.getFunction(rec_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        // Calls itself
        const ci = try module.addCallInfo(alloc, "run_main__recurse", &.{});
        const t1 = func.allocRef();
        try block.addInst(alloc, ir.makeInst(.call, t1, ci, 0));
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    var result = try eliminate(alloc, &module);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), module.functions.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.items.len);
}

test "eliminate: external calls don't cause errors" {
    const alloc = std.testing.allocator;
    var module = ir.Module.init();
    defer module.deinit(alloc);

    const main_id = try module.addFunction(alloc, "run_main__main");
    {
        var func = module.getFunction(main_id);
        func.return_type_name = "void";
        const b0 = try func.addBlock(alloc);
        var block = func.getBlock(b0);
        // Call to built-in (not in module.functions)
        const ci = try module.addCallInfo(alloc, "run_fmt_println", &.{});
        const t1 = func.allocRef();
        try block.addInst(alloc, ir.makeInst(.call, t1, ci, 0));
        try block.addInst(alloc, ir.makeInst(.ret_void, 0, 0, 0));
    }

    var result = try eliminate(alloc, &module);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), module.functions.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.items.len);
}
