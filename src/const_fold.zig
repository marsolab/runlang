const std = @import("std");
const ir = @import("ir.zig");
const diagnostics = @import("diagnostics.zig");

pub const FoldResult = struct {
    diagnostics: diagnostics.DiagnosticList,
    folded_count: u32,

    pub fn deinit(self: *FoldResult) void {
        self.diagnostics.deinit();
    }
};

const ConstValue = union(enum) {
    int: i64,
    bool_val: bool,
};

/// Run constant folding on the IR module in-place.
/// Folds constant arithmetic, boolean logic, comparisons, and propagates
/// constants through local variables within basic blocks.
pub fn fold(allocator: std.mem.Allocator, module: *ir.Module) !FoldResult {
    var result = FoldResult{
        .diagnostics = diagnostics.DiagnosticList.init(allocator),
        .folded_count = 0,
    };

    for (module.functions.items) |*func| {
        // Ref constants persist across blocks — each ref is defined exactly once.
        var ref_consts = std.AutoHashMap(ir.Ref, ConstValue).init(allocator);
        defer ref_consts.deinit();

        for (func.blocks.items) |*block| {
            // Local constants reset per block — conservative across control flow.
            var local_consts = std.AutoHashMap(u32, ConstValue).init(allocator);
            defer local_consts.deinit();

            for (block.insts.items) |*inst| {
                try foldInst(inst, &ref_consts, &local_consts, &result, func.name);
            }
        }
    }

    return result;
}

fn foldInst(
    inst: *ir.Inst,
    ref_consts: *std.AutoHashMap(ir.Ref, ConstValue),
    local_consts: *std.AutoHashMap(u32, ConstValue),
    result: *FoldResult,
    func_name: []const u8,
) !void {
    switch (inst.op) {
        .const_int => {
            try ref_consts.put(inst.result, .{ .int = ir.decodeConstInt(inst.*) });
        },
        .const_bool => {
            try ref_consts.put(inst.result, .{ .bool_val = inst.arg1 != 0 });
        },

        .add, .sub, .mul, .div, .mod => {
            const lhs = ref_consts.get(inst.arg1) orelse return;
            const rhs = ref_consts.get(inst.arg2) orelse return;
            const a = switch (lhs) {
                .int => |v| v,
                else => return,
            };
            const b = switch (rhs) {
                .int => |v| v,
                else => return,
            };

            if ((inst.op == .div or inst.op == .mod) and b == 0) {
                try result.diagnostics.addErrorFmt(0, 0, "division by zero in function '{s}'", .{func_name});
                return;
            }

            const val: i64 = switch (inst.op) {
                .add => a +% b,
                .sub => a -% b,
                .mul => a *% b,
                .div => @divTrunc(a, b),
                .mod => @rem(a, b),
                else => unreachable,
            };

            inst.* = ir.makeConstInt(inst.result, val);
            try ref_consts.put(inst.result, .{ .int = val });
            result.folded_count += 1;
        },

        .neg => {
            const operand = ref_consts.get(inst.arg1) orelse return;
            const a = switch (operand) {
                .int => |v| v,
                else => return,
            };
            const val = 0 -% a;
            inst.* = ir.makeConstInt(inst.result, val);
            try ref_consts.put(inst.result, .{ .int = val });
            result.folded_count += 1;
        },

        .eq, .ne, .lt, .le, .gt, .ge => {
            const lhs = ref_consts.get(inst.arg1) orelse return;
            const rhs = ref_consts.get(inst.arg2) orelse return;

            const val: ?bool = switch (lhs) {
                .int => |a| switch (rhs) {
                    .int => |b| switch (inst.op) {
                        .eq => a == b,
                        .ne => a != b,
                        .lt => a < b,
                        .le => a <= b,
                        .gt => a > b,
                        .ge => a >= b,
                        else => unreachable,
                    },
                    else => null,
                },
                .bool_val => |a| switch (rhs) {
                    .bool_val => |b| switch (inst.op) {
                        .eq => a == b,
                        .ne => a != b,
                        else => null,
                    },
                    else => null,
                },
            };

            if (val) |v| {
                inst.* = ir.makeInst(.const_bool, inst.result, if (v) 1 else 0, 0);
                try ref_consts.put(inst.result, .{ .bool_val = v });
                result.folded_count += 1;
            }
        },

        .log_and, .log_or => {
            const lhs = ref_consts.get(inst.arg1) orelse return;
            const rhs = ref_consts.get(inst.arg2) orelse return;
            const a = switch (lhs) {
                .bool_val => |v| v,
                else => return,
            };
            const b = switch (rhs) {
                .bool_val => |v| v,
                else => return,
            };

            const val: bool = switch (inst.op) {
                .log_and => a and b,
                .log_or => a or b,
                else => unreachable,
            };

            inst.* = ir.makeInst(.const_bool, inst.result, if (val) 1 else 0, 0);
            try ref_consts.put(inst.result, .{ .bool_val = val });
            result.folded_count += 1;
        },

        .log_not => {
            const operand = ref_consts.get(inst.arg1) orelse return;
            const a = switch (operand) {
                .bool_val => |v| v,
                else => return,
            };
            const val = !a;
            inst.* = ir.makeInst(.const_bool, inst.result, if (val) 1 else 0, 0);
            try ref_consts.put(inst.result, .{ .bool_val = val });
            result.folded_count += 1;
        },

        .local_set => {
            if (ref_consts.get(inst.arg2)) |val| {
                try local_consts.put(inst.arg1, val);
            } else {
                _ = local_consts.remove(inst.arg1);
            }
        },

        .local_get => {
            if (local_consts.get(inst.arg1)) |val| {
                switch (val) {
                    .int => |v| {
                        inst.* = ir.makeConstInt(inst.result, v);
                    },
                    .bool_val => |v| {
                        inst.* = ir.makeInst(.const_bool, inst.result, if (v) 1 else 0, 0);
                    },
                }
                try ref_consts.put(inst.result, val);
                result.folded_count += 1;
            }
        },

        else => {},
    }
}

/// Decode a split const_int payload into i64.
fn decodeInt(low: u32, high: u32) i64 {
    const bits = @as(u64, low) | (@as(u64, high) << 32);
    return @as(i64, @bitCast(bits));
}

/// Encode an i64 value to the low 32 bits of the const_int payload.
fn encodeInt(val: i64) u32 {
    return ir.makeConstInt(0, val).arg1;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn makeTestModule(allocator: std.mem.Allocator) !struct { module: ir.Module, func: *ir.Function, block: *ir.BasicBlock } {
    var module = ir.Module.init();
    const fid = try module.addFunction(allocator, "run_main__test");
    var func = module.getFunction(fid);
    func.return_type_name = "void";
    const b0 = try func.addBlock(allocator);
    const block = func.getBlock(b0);
    return .{ .module = module, .func = func, .block = block };
}

test "fold: integer addition 2 + 3 = 5" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 2, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t2, 3, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.add, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expect(!result.diagnostics.hasErrors());
    try testing.expectEqual(@as(u32, 1), result.folded_count);

    const folded = ctx.block.insts.items[2];
    try testing.expectEqual(ir.Inst.Op.const_int, folded.op);
    try testing.expectEqual(t3, folded.result);
    try testing.expectEqual(@as(u32, 5), folded.arg1);
}

test "fold: integer subtraction 10 - 3 = 7" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 10, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t2, 3, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.sub, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.folded_count);
    try testing.expectEqual(ir.Inst.Op.const_int, ctx.block.insts.items[2].op);
    try testing.expectEqual(@as(u32, 7), ctx.block.insts.items[2].arg1);
}

test "fold: integer multiplication 4 * 5 = 20" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 4, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t2, 5, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.mul, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.folded_count);
    try testing.expectEqual(@as(u32, 20), ctx.block.insts.items[2].arg1);
}

test "fold: integer division 10 / 3 = 3" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 10, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t2, 3, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.div, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.folded_count);
    try testing.expectEqual(@as(u32, 3), ctx.block.insts.items[2].arg1);
}

test "fold: integer modulo 10 % 3 = 1" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 10, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t2, 3, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.mod, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.folded_count);
    try testing.expectEqual(@as(u32, 1), ctx.block.insts.items[2].arg1);
}

test "fold: division by zero produces error" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 10, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t2, 0, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.div, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expect(result.diagnostics.hasErrors());
    try testing.expectEqual(@as(u32, 0), result.folded_count);
    // Instruction is NOT folded — left as-is
    try testing.expectEqual(ir.Inst.Op.div, ctx.block.insts.items[2].op);
}

test "fold: modulo by zero produces error" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 7, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t2, 0, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.mod, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expect(result.diagnostics.hasErrors());
}

test "fold: boolean AND true && false = false" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_bool, t1, 1, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_bool, t2, 0, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.log_and, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.folded_count);
    try testing.expectEqual(ir.Inst.Op.const_bool, ctx.block.insts.items[2].op);
    try testing.expectEqual(@as(u32, 0), ctx.block.insts.items[2].arg1); // false
}

test "fold: boolean OR true || false = true" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_bool, t1, 1, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_bool, t2, 0, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.log_or, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.folded_count);
    try testing.expectEqual(@as(u32, 1), ctx.block.insts.items[2].arg1); // true
}

test "fold: boolean NOT !true = false" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_bool, t1, 1, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.log_not, t2, t1, 0));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.folded_count);
    try testing.expectEqual(ir.Inst.Op.const_bool, ctx.block.insts.items[1].op);
    try testing.expectEqual(@as(u32, 0), ctx.block.insts.items[1].arg1); // false
}

test "fold: comparison 5 > 3 = true" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 5, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t2, 3, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.gt, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.folded_count);
    try testing.expectEqual(ir.Inst.Op.const_bool, ctx.block.insts.items[2].op);
    try testing.expectEqual(@as(u32, 1), ctx.block.insts.items[2].arg1); // true
}

test "fold: comparison 3 > 5 = false" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 3, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t2, 5, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.gt, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.folded_count);
    try testing.expectEqual(@as(u32, 0), ctx.block.insts.items[2].arg1); // false
}

test "fold: equality 5 == 5 = true" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 5, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t2, 5, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.eq, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.folded_count);
    try testing.expectEqual(@as(u32, 1), ctx.block.insts.items[2].arg1); // true
}

test "fold: inequality 5 != 5 = false" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 5, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t2, 5, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ne, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.folded_count);
    try testing.expectEqual(@as(u32, 0), ctx.block.insts.items[2].arg1); // false
}

test "fold: negation -(42) = -42" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 42, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.neg, t2, t1, 0));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.folded_count);
    try testing.expectEqual(ir.Inst.Op.const_int, ctx.block.insts.items[1].op);
    // -42 encoded: @as(u64, @bitCast(@as(i64, -42))) & 0xFFFFFFFF
    try testing.expectEqual(encodeInt(-42), ctx.block.insts.items[1].arg1);
}

test "fold: chain folding 1 + 2 + 3 = 6" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 1, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t2, 2, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.add, t3, t1, t2)); // 1+2=3
    const t4 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t4, 3, 0));
    const t5 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.add, t5, t3, t4)); // 3+3=6
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 2), result.folded_count);
    try testing.expectEqual(@as(u32, 6), ctx.block.insts.items[4].arg1);
}

test "fold: constant propagation through local variable" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    // let x = 5
    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 5, 0));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.local_set, 0, 0, t1)); // local[0] = 5

    // y = x + 1
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.local_get, t2, 0, 0)); // t2 = local[0]
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t3, 1, 0));
    const t4 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.add, t4, t2, t3)); // t4 = t2 + 1

    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    // local_get folded to const_int(5), then add(5,1) folded to const_int(6)
    try testing.expectEqual(@as(u32, 2), result.folded_count);
    try testing.expectEqual(ir.Inst.Op.const_int, ctx.block.insts.items[2].op);
    try testing.expectEqual(@as(u32, 5), ctx.block.insts.items[2].arg1);
    try testing.expectEqual(ir.Inst.Op.const_int, ctx.block.insts.items[4].op);
    try testing.expectEqual(@as(u32, 6), ctx.block.insts.items[4].arg1);
}

test "fold: local reassignment invalidates constant" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    // let x = 5
    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 5, 0));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.local_set, 0, 0, t1));

    // x = <non-constant> (simulated by a ref that is not in ref_consts)
    const t_unknown = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.call, t_unknown, 0, 0)); // call result, not constant
    try ctx.block.addInst(testing.allocator, ir.makeInst(.local_set, 0, 0, t_unknown));

    // y = x (should NOT be folded)
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.local_get, t2, 0, 0));

    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 0), result.folded_count);
    try testing.expectEqual(ir.Inst.Op.local_get, ctx.block.insts.items[4].op); // NOT folded
}

test "fold: non-constant operands are not folded" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 5, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.call, t2, 0, 0)); // non-constant
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.add, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 0), result.folded_count);
    try testing.expectEqual(ir.Inst.Op.add, ctx.block.insts.items[2].op); // unchanged
}

test "fold: empty module" {
    var module = ir.Module.init();
    defer module.deinit(testing.allocator);

    var result = try fold(testing.allocator, &module);
    defer result.deinit();

    try testing.expect(!result.diagnostics.hasErrors());
    try testing.expectEqual(@as(u32, 0), result.folded_count);
}

test "fold: le and ge comparisons" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 5, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t2, 5, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.le, t3, t1, t2)); // 5 <= 5 = true
    const t4 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ge, t4, t1, t2)); // 5 >= 5 = true
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 2), result.folded_count);
    try testing.expectEqual(@as(u32, 1), ctx.block.insts.items[2].arg1); // true
    try testing.expectEqual(@as(u32, 1), ctx.block.insts.items[3].arg1); // true
}

test "fold: boolean equality true == false = false" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_bool, t1, 1, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_bool, t2, 0, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.eq, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.folded_count);
    try testing.expectEqual(@as(u32, 0), ctx.block.insts.items[2].arg1); // false
}

test "fold: wrapping arithmetic on overflow" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    // Use large u32 values that would overflow when multiplied
    const large: u32 = 0x7FFFFFFF; // max i32
    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, large, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t2, 2, 0));
    const t3 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.mul, t3, t1, t2));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    // Should fold successfully using wrapping multiplication
    try testing.expect(!result.diagnostics.hasErrors());
    try testing.expectEqual(@as(u32, 1), result.folded_count);
    try testing.expectEqual(ir.Inst.Op.const_int, ctx.block.insts.items[2].op);

    // 0x7FFFFFFF * 2 = 0xFFFFFFFE = 4294967294 as i64
    // encoded as u32: 0xFFFFFFFE
    const expected = encodeInt(decodeInt(large, 0) *% decodeInt(2, 0));
    try testing.expectEqual(expected, ctx.block.insts.items[2].arg1);
}

test "fold: ref constants persist across blocks" {
    var ctx = try makeTestModule(testing.allocator);
    defer ctx.module.deinit(testing.allocator);

    // Block 0: define constants and branch
    const b1 = try ctx.func.addBlock(testing.allocator);
    const t1 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t1, 10, 0));
    const t2 = ctx.func.allocRef();
    try ctx.block.addInst(testing.allocator, ir.makeInst(.const_int, t2, 20, 0));
    try ctx.block.addInst(testing.allocator, ir.makeInst(.br, 0, b1, 0));

    // Block 1: use the constants defined in block 0
    var block1 = ctx.func.getBlock(b1);
    const t3 = ctx.func.allocRef();
    try block1.addInst(testing.allocator, ir.makeInst(.add, t3, t1, t2));
    try block1.addInst(testing.allocator, ir.makeInst(.ret_void, 0, 0, 0));

    var result = try fold(testing.allocator, &ctx.module);
    defer result.deinit();

    try testing.expectEqual(@as(u32, 1), result.folded_count);
    try testing.expectEqual(ir.Inst.Op.const_int, block1.insts.items[0].op);
    try testing.expectEqual(@as(u32, 30), block1.insts.items[0].arg1);
}
