const std = @import("std");

/// A handle into the TypePool's type array.
pub const TypeId = u32;

/// Sentinel: TypeId 0 is always `void`.
pub const null_type: TypeId = 0;

/// Well-known TypeIds for primitive types, pre-registered in every TypePool.
pub const primitives = struct {
    pub const void_id: TypeId = 0;
    pub const bool_id: TypeId = 1;
    pub const int_id: TypeId = 2;
    pub const uint_id: TypeId = 3;
    pub const i32_id: TypeId = 4;
    pub const i64_id: TypeId = 5;
    pub const u32_id: TypeId = 6;
    pub const u64_id: TypeId = 7;
    pub const byte_id: TypeId = 8;
    pub const f32_id: TypeId = 9;
    pub const f64_id: TypeId = 10;
    pub const string_id: TypeId = 11;
    pub const any_id: TypeId = 12;
    pub const i8_id: TypeId = 13;
    pub const i16_id: TypeId = 14;
    pub const v2bool_id: TypeId = 15;
    pub const v4bool_id: TypeId = 16;
    pub const v8bool_id: TypeId = 17;
    pub const v16bool_id: TypeId = 18;
    pub const v32bool_id: TypeId = 19;
    pub const v4f32_id: TypeId = 20;
    pub const v2f64_id: TypeId = 21;
    pub const v4i32_id: TypeId = 22;
    pub const v8i16_id: TypeId = 23;
    pub const v16i8_id: TypeId = 24;
    pub const v8f32_id: TypeId = 25;
    pub const v4f64_id: TypeId = 26;
    pub const v8i32_id: TypeId = 27;
    pub const v16i16_id: TypeId = 28;
    pub const v32i8_id: TypeId = 29;

    /// Number of pre-registered primitives.
    pub const count: u32 = 30;
};

/// Represents every type in the Run language.
pub const Type = union(enum) {
    void_type,
    bool_type,
    any_type,
    int_type: IntType,
    float_type: FloatType,
    string_type,
    simd_type: SimdType,
    struct_type: StructType,
    interface_type: InterfaceType,
    sum_type: SumType,
    newtype: NewType,
    ptr_type: PtrType,
    nullable_type: NullableType,
    error_union_type: ErrorUnionType,
    slice_type: SliceType,
    map_type: MapType,
    chan_type: ChanType,
    array_type: ArrayType,
    fn_type: FnType,

    pub fn eql(a: Type, b: Type) bool {
        const tag_a = std.meta.activeTag(a);
        const tag_b = std.meta.activeTag(b);
        if (tag_a != tag_b) return false;

        return switch (a) {
            .void_type, .bool_type, .string_type, .any_type => true,
            .int_type => |ia| {
                const ib = b.int_type;
                return ia.bits == ib.bits and ia.signed == ib.signed;
            },
            .float_type => |fa| fa.bits == b.float_type.bits,
            .simd_type => |sa| {
                const sb = b.simd_type;
                return sa.lanes == sb.lanes and sa.elem_kind == sb.elem_kind and sa.elem_bits == sb.elem_bits;
            },
            .ptr_type => |pa| pa.pointee == b.ptr_type.pointee and pa.is_const == b.ptr_type.is_const,
            .nullable_type => |na| na.inner == b.nullable_type.inner,
            .error_union_type => |ea| ea.payload == b.error_union_type.payload,
            .slice_type => |sa| sa.elem == b.slice_type.elem,
            .map_type => |ma| {
                const mb = b.map_type;
                return ma.key == mb.key and ma.value == mb.value;
            },
            .chan_type => |ca| ca.elem == b.chan_type.elem,
            .array_type => |aa| {
                const ab = b.array_type;
                return aa.elem == ab.elem and aa.len == ab.len;
            },
            .fn_type => |fa| {
                const fb = b.fn_type;
                if (fa.return_type != fb.return_type) return false;
                if (fa.is_variadic != fb.is_variadic) return false;
                if (fa.params.len != fb.params.len) return false;
                return std.mem.eql(TypeId, fa.params, fb.params);
            },
            .newtype => |na| {
                const nb = b.newtype;
                return std.mem.eql(u8, na.name, nb.name) and na.underlying == nb.underlying;
            },
            // Nominal types: identity comparison would require TypeId.
            // For structural equality of struct/interface/sum we compare name only.
            .struct_type => |sa| std.mem.eql(u8, sa.name, b.struct_type.name),
            .interface_type => |ia| std.mem.eql(u8, ia.name, b.interface_type.name),
            .sum_type => |sa| std.mem.eql(u8, sa.name, b.sum_type.name),
        };
    }
};

pub const IntType = struct {
    bits: u8,
    signed: bool,
};

pub const FloatType = struct {
    bits: u8,
};

pub const SimdElementKind = enum {
    bool,
    int,
    float,
};

pub const SimdType = struct {
    lanes: u8,
    elem_kind: SimdElementKind,
    elem_bits: u8,
};

pub const StructField = struct {
    name: []const u8,
    type_id: TypeId,
};

pub const StructType = struct {
    name: []const u8,
    fields: []const StructField,
    methods: []const TypeId, // TypeIds of fn_type entries
    implements: []const TypeId, // interface TypeIds
};

pub const MethodSig = struct {
    name: []const u8,
    type_id: TypeId, // a fn_type TypeId
};

pub const InterfaceType = struct {
    name: []const u8,
    methods: []const MethodSig,
};

pub const Variant = struct {
    name: []const u8,
    payload: TypeId, // null_type if no payload
};

pub const SumType = struct {
    name: []const u8,
    variants: []const Variant,
};

pub const NewType = struct {
    name: []const u8,
    underlying: TypeId,
};

pub const PtrType = struct {
    pointee: TypeId,
    is_const: bool,
};

pub const NullableType = struct {
    inner: TypeId,
};

pub const ErrorUnionType = struct {
    payload: TypeId,
};

pub const SliceType = struct {
    elem: TypeId,
};

pub const MapType = struct {
    key: TypeId,
    value: TypeId,
};

pub const ChanType = struct {
    elem: TypeId,
};

pub const ArrayType = struct {
    elem: TypeId,
    len: u32,
};

pub const FnType = struct {
    params: []const TypeId,
    return_type: TypeId,
    is_variadic: bool = false,
};

/// A 64-bit key for deduplicating structural wrapper types.
/// Encodes the discriminant tag plus up to two u32 payloads.
const WrapperKey = u64;

fn wrapperKey(tag: u8, a: u32, b: u32) WrapperKey {
    // Pack: [8-bit tag][24 bits unused][16 high bits of a][16 low bits of a] — no, simpler:
    // Just use tag in high byte, a in next 28 bits, b in low 28 bits.
    // Actually, simplest: hash them together.
    return (@as(u64, tag) << 56) | (@as(u64, a) << 28) | @as(u64, b);
}

/// Stores and deduplicates all types in the compiler.
pub const TypePool = struct {
    types: std.ArrayList(Type),
    /// Maps wrapper-key -> TypeId for structural wrapper types
    /// (ptr, nullable, error_union, slice, map, chan, array).
    wrapper_map: std.AutoHashMap(WrapperKey, TypeId),

    pub fn init(allocator: std.mem.Allocator) TypePool {
        var pool = TypePool{
            .types = .empty,
            .wrapper_map = std.AutoHashMap(WrapperKey, TypeId).init(allocator),
        };
        // Pre-register primitive types at known indices.
        // Order must match primitives.* constants.
        pool.types.append(allocator, .void_type) catch unreachable; // 0: void
        pool.types.append(allocator, .bool_type) catch unreachable; // 1: bool
        pool.types.append(allocator, .{ .int_type = .{ .bits = 64, .signed = true } }) catch unreachable; // 2: int
        pool.types.append(allocator, .{ .int_type = .{ .bits = 64, .signed = false } }) catch unreachable; // 3: uint
        pool.types.append(allocator, .{ .int_type = .{ .bits = 32, .signed = true } }) catch unreachable; // 4: i32
        pool.types.append(allocator, .{ .int_type = .{ .bits = 64, .signed = true } }) catch unreachable; // 5: i64
        pool.types.append(allocator, .{ .int_type = .{ .bits = 32, .signed = false } }) catch unreachable; // 6: u32
        pool.types.append(allocator, .{ .int_type = .{ .bits = 64, .signed = false } }) catch unreachable; // 7: u64
        pool.types.append(allocator, .{ .int_type = .{ .bits = 8, .signed = false } }) catch unreachable; // 8: byte
        pool.types.append(allocator, .{ .float_type = .{ .bits = 32 } }) catch unreachable; // 9: f32
        pool.types.append(allocator, .{ .float_type = .{ .bits = 64 } }) catch unreachable; // 10: f64
        pool.types.append(allocator, .string_type) catch unreachable; // 11: string
        pool.types.append(allocator, .any_type) catch unreachable; // 12: any
        pool.types.append(allocator, .{ .int_type = .{ .bits = 8, .signed = true } }) catch unreachable; // 13: i8
        pool.types.append(allocator, .{ .int_type = .{ .bits = 16, .signed = true } }) catch unreachable; // 14: i16
        pool.types.append(allocator, .{ .simd_type = .{ .lanes = 2, .elem_kind = .bool, .elem_bits = 1 } }) catch unreachable; // 15: v2bool
        pool.types.append(allocator, .{ .simd_type = .{ .lanes = 4, .elem_kind = .bool, .elem_bits = 1 } }) catch unreachable; // 16: v4bool
        pool.types.append(allocator, .{ .simd_type = .{ .lanes = 8, .elem_kind = .bool, .elem_bits = 1 } }) catch unreachable; // 17: v8bool
        pool.types.append(allocator, .{ .simd_type = .{ .lanes = 16, .elem_kind = .bool, .elem_bits = 1 } }) catch unreachable; // 18: v16bool
        pool.types.append(allocator, .{ .simd_type = .{ .lanes = 32, .elem_kind = .bool, .elem_bits = 1 } }) catch unreachable; // 19: v32bool
        pool.types.append(allocator, .{ .simd_type = .{ .lanes = 4, .elem_kind = .float, .elem_bits = 32 } }) catch unreachable; // 20: v4f32
        pool.types.append(allocator, .{ .simd_type = .{ .lanes = 2, .elem_kind = .float, .elem_bits = 64 } }) catch unreachable; // 21: v2f64
        pool.types.append(allocator, .{ .simd_type = .{ .lanes = 4, .elem_kind = .int, .elem_bits = 32 } }) catch unreachable; // 22: v4i32
        pool.types.append(allocator, .{ .simd_type = .{ .lanes = 8, .elem_kind = .int, .elem_bits = 16 } }) catch unreachable; // 23: v8i16
        pool.types.append(allocator, .{ .simd_type = .{ .lanes = 16, .elem_kind = .int, .elem_bits = 8 } }) catch unreachable; // 24: v16i8
        pool.types.append(allocator, .{ .simd_type = .{ .lanes = 8, .elem_kind = .float, .elem_bits = 32 } }) catch unreachable; // 25: v8f32
        pool.types.append(allocator, .{ .simd_type = .{ .lanes = 4, .elem_kind = .float, .elem_bits = 64 } }) catch unreachable; // 26: v4f64
        pool.types.append(allocator, .{ .simd_type = .{ .lanes = 8, .elem_kind = .int, .elem_bits = 32 } }) catch unreachable; // 27: v8i32
        pool.types.append(allocator, .{ .simd_type = .{ .lanes = 16, .elem_kind = .int, .elem_bits = 16 } }) catch unreachable; // 28: v16i16
        pool.types.append(allocator, .{ .simd_type = .{ .lanes = 32, .elem_kind = .int, .elem_bits = 8 } }) catch unreachable; // 29: v32i8
        return pool;
    }

    pub fn deinit(self: *TypePool, allocator: std.mem.Allocator) void {
        self.types.deinit(allocator);
        self.wrapper_map.deinit();
    }

    /// Look up a primitive type by name. Returns null if the name is not a primitive.
    pub fn lookupPrimitive(name: []const u8) ?TypeId {
        const map = std.StaticStringMap(TypeId).initComptime(.{
            .{ "void", primitives.void_id },
            .{ "bool", primitives.bool_id },
            .{ "int", primitives.int_id },
            .{ "uint", primitives.uint_id },
            .{ "i32", primitives.i32_id },
            .{ "i64", primitives.i64_id },
            .{ "u32", primitives.u32_id },
            .{ "u64", primitives.u64_id },
            .{ "byte", primitives.byte_id },
            .{ "f32", primitives.f32_id },
            .{ "f64", primitives.f64_id },
            .{ "string", primitives.string_id },
            .{ "any", primitives.any_id },
            .{ "i8", primitives.i8_id },
            .{ "i16", primitives.i16_id },
            .{ "v2bool", primitives.v2bool_id },
            .{ "v4bool", primitives.v4bool_id },
            .{ "v8bool", primitives.v8bool_id },
            .{ "v16bool", primitives.v16bool_id },
            .{ "v32bool", primitives.v32bool_id },
            .{ "v4f32", primitives.v4f32_id },
            .{ "v2f64", primitives.v2f64_id },
            .{ "v4i32", primitives.v4i32_id },
            .{ "v8i16", primitives.v8i16_id },
            .{ "v16i8", primitives.v16i8_id },
            .{ "v8f32", primitives.v8f32_id },
            .{ "v4f64", primitives.v4f64_id },
            .{ "v8i32", primitives.v8i32_id },
            .{ "v16i16", primitives.v16i16_id },
            .{ "v32i8", primitives.v32i8_id },
        });
        return map.get(name);
    }

    /// Add a new type without deduplication. Returns its TypeId.
    pub fn addType(self: *TypePool, allocator: std.mem.Allocator, typ: Type) !TypeId {
        const id: TypeId = @intCast(self.types.items.len);
        try self.types.append(allocator, typ);
        return id;
    }

    /// Get the Type for a given TypeId.
    pub fn get(self: *const TypePool, id: TypeId) Type {
        return self.types.items[id];
    }

    /// Intern a wrapper type with deduplication.
    /// For ptr, nullable, error_union, slice, chan, map, array types.
    pub fn intern(self: *TypePool, allocator: std.mem.Allocator, typ: Type) !TypeId {
        const key = typeToWrapperKey(typ) orelse {
            // Not a wrapper type; add without dedup.
            return self.addType(allocator, typ);
        };
        const result = try self.wrapper_map.getOrPut(key);
        if (result.found_existing) {
            return result.value_ptr.*;
        }
        const id: TypeId = @intCast(self.types.items.len);
        try self.types.append(allocator, typ);
        result.value_ptr.* = id;
        return id;
    }

    /// Returns whether two TypeIds refer to the same type.
    pub fn typeEql(self: *const TypePool, a: TypeId, b: TypeId) bool {
        if (a == b) return true;
        return self.get(a).eql(self.get(b));
    }

    /// Check if a type is numeric (int or float).
    pub fn isNumeric(self: *const TypePool, id: TypeId) bool {
        return switch (self.get(id)) {
            .int_type, .float_type => true,
            else => false,
        };
    }

    /// Check if a type is an integer type.
    pub fn isInteger(self: *const TypePool, id: TypeId) bool {
        return switch (self.get(id)) {
            .int_type => true,
            else => false,
        };
    }

    /// Check if a type is a float type.
    pub fn isFloat(self: *const TypePool, id: TypeId) bool {
        return switch (self.get(id)) {
            .float_type => true,
            else => false,
        };
    }

    /// Check if a type is nullable.
    pub fn isNullable(self: *const TypePool, id: TypeId) bool {
        return switch (self.get(id)) {
            .nullable_type => true,
            else => false,
        };
    }

    /// Check if a type is an error union.
    pub fn isErrorUnion(self: *const TypePool, id: TypeId) bool {
        return switch (self.get(id)) {
            .error_union_type => true,
            else => false,
        };
    }

    /// Unwrap nullable: T? -> T. Returns null if not nullable.
    pub fn unwrapNullable(self: *const TypePool, id: TypeId) ?TypeId {
        return switch (self.get(id)) {
            .nullable_type => |n| n.inner,
            else => null,
        };
    }

    /// Unwrap error union: !T -> T. Returns null if not error union.
    pub fn unwrapErrorUnion(self: *const TypePool, id: TypeId) ?TypeId {
        return switch (self.get(id)) {
            .error_union_type => |e| e.payload,
            else => null,
        };
    }

    /// Unwrap pointer: &T or @T -> T. Returns null if not a pointer.
    pub fn unwrapPointer(self: *const TypePool, id: TypeId) ?TypeId {
        return switch (self.get(id)) {
            .ptr_type => |p| p.pointee,
            else => null,
        };
    }

    /// Unwrap newtype to its underlying type.
    pub fn unwrapNewtype(self: *const TypePool, id: TypeId) ?TypeId {
        return switch (self.get(id)) {
            .newtype => |n| n.underlying,
            else => null,
        };
    }

    pub fn isSimd(self: *const TypePool, id: TypeId) bool {
        return switch (self.get(id)) {
            .simd_type => true,
            else => false,
        };
    }

    pub fn isSimdMask(self: *const TypePool, id: TypeId) bool {
        return switch (self.get(id)) {
            .simd_type => |simd| simd.elem_kind == .bool,
            else => false,
        };
    }

    pub fn getSimd(self: *const TypePool, id: TypeId) ?SimdType {
        return switch (self.get(id)) {
            .simd_type => |simd| simd,
            else => null,
        };
    }

    pub fn simdMaskFor(self: *const TypePool, id: TypeId) ?TypeId {
        const simd = self.getSimd(id) orelse return null;
        return switch (simd.lanes) {
            2 => primitives.v2bool_id,
            4 => primitives.v4bool_id,
            8 => primitives.v8bool_id,
            16 => primitives.v16bool_id,
            32 => primitives.v32bool_id,
            else => null,
        };
    }

    pub fn simdElementType(self: *const TypePool, id: TypeId) ?TypeId {
        const simd = self.getSimd(id) orelse return null;
        return switch (simd.elem_kind) {
            .bool => primitives.bool_id,
            .float => switch (simd.elem_bits) {
                32 => primitives.f32_id,
                64 => primitives.f64_id,
                else => null,
            },
            .int => switch (simd.elem_bits) {
                8 => primitives.i8_id,
                16 => primitives.i16_id,
                32 => primitives.i32_id,
                64 => primitives.i64_id,
                else => null,
            },
        };
    }

    pub fn simdAlignment(self: *const TypePool, id: TypeId) ?u32 {
        const simd = self.getSimd(id) orelse return null;
        const byte_width = (@as(u32, simd.lanes) * @as(u32, simd.elem_bits) + 7) / 8;
        return switch (byte_width) {
            16 => 16,
            32 => 32,
            else => null,
        };
    }
};

/// Maps a structural wrapper Type to its deduplication key, or null for nominal types.
fn typeToWrapperKey(typ: Type) ?WrapperKey {
    return switch (typ) {
        .ptr_type => |p| wrapperKey(0, p.pointee, @intFromBool(p.is_const)),
        .nullable_type => |n| wrapperKey(1, n.inner, 0),
        .error_union_type => |e| wrapperKey(2, e.payload, 0),
        .slice_type => |s| wrapperKey(3, s.elem, 0),
        .chan_type => |c| wrapperKey(4, c.elem, 0),
        .map_type => |m| wrapperKey(5, m.key, m.value),
        .array_type => |a| wrapperKey(6, a.elem, a.len),
        else => null,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────────

test "primitive types are pre-registered" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    try std.testing.expectEqual(Type.void_type, pool.get(primitives.void_id));
    try std.testing.expectEqual(Type.bool_type, pool.get(primitives.bool_id));
    try std.testing.expectEqual(Type.string_type, pool.get(primitives.string_id));

    // int is 64-bit signed
    const int_type = pool.get(primitives.int_id);
    try std.testing.expectEqual(IntType{ .bits = 64, .signed = true }, int_type.int_type);

    // uint is 64-bit unsigned
    const uint_type = pool.get(primitives.uint_id);
    try std.testing.expectEqual(IntType{ .bits = 64, .signed = false }, uint_type.int_type);

    // byte is 8-bit unsigned
    const byte_type = pool.get(primitives.byte_id);
    try std.testing.expectEqual(IntType{ .bits = 8, .signed = false }, byte_type.int_type);

    // f32
    const f32_type = pool.get(primitives.f32_id);
    try std.testing.expectEqual(FloatType{ .bits = 32 }, f32_type.float_type);

    // f64
    const f64_type = pool.get(primitives.f64_id);
    try std.testing.expectEqual(FloatType{ .bits = 64 }, f64_type.float_type);

    const i8_type = pool.get(primitives.i8_id);
    try std.testing.expectEqual(IntType{ .bits = 8, .signed = true }, i8_type.int_type);

    const v4f32_type = pool.get(primitives.v4f32_id);
    try std.testing.expectEqual(SimdType{ .lanes = 4, .elem_kind = .float, .elem_bits = 32 }, v4f32_type.simd_type);
}

test "lookupPrimitive" {
    try std.testing.expectEqual(primitives.int_id, TypePool.lookupPrimitive("int").?);
    try std.testing.expectEqual(primitives.string_id, TypePool.lookupPrimitive("string").?);
    try std.testing.expectEqual(primitives.bool_id, TypePool.lookupPrimitive("bool").?);
    try std.testing.expectEqual(primitives.f64_id, TypePool.lookupPrimitive("f64").?);
    try std.testing.expectEqual(primitives.byte_id, TypePool.lookupPrimitive("byte").?);
    try std.testing.expectEqual(primitives.v8f32_id, TypePool.lookupPrimitive("v8f32").?);
    try std.testing.expectEqual(primitives.v4bool_id, TypePool.lookupPrimitive("v4bool").?);
    try std.testing.expect(TypePool.lookupPrimitive("MyStruct") == null);
    try std.testing.expect(TypePool.lookupPrimitive("unknown") == null);
}

test "addType creates new types" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const struct_id = try pool.addType(allocator, .{ .struct_type = .{
        .name = "Point",
        .fields = &.{},
        .methods = &.{},
        .implements = &.{},
    } });

    try std.testing.expect(struct_id >= primitives.count);
    try std.testing.expectEqualStrings("Point", pool.get(struct_id).struct_type.name);
}

test "intern deduplicates wrapper types" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    // Two pointers to the same type should get the same TypeId.
    const ptr1 = try pool.intern(allocator, .{ .ptr_type = .{ .pointee = primitives.int_id, .is_const = false } });
    const ptr2 = try pool.intern(allocator, .{ .ptr_type = .{ .pointee = primitives.int_id, .is_const = false } });
    try std.testing.expectEqual(ptr1, ptr2);

    // Const pointer is different from mutable pointer.
    const cptr = try pool.intern(allocator, .{ .ptr_type = .{ .pointee = primitives.int_id, .is_const = true } });
    try std.testing.expect(cptr != ptr1);

    // Nullable types.
    const n1 = try pool.intern(allocator, .{ .nullable_type = .{ .inner = primitives.int_id } });
    const n2 = try pool.intern(allocator, .{ .nullable_type = .{ .inner = primitives.int_id } });
    try std.testing.expectEqual(n1, n2);

    // Different inner type is different.
    const n3 = try pool.intern(allocator, .{ .nullable_type = .{ .inner = primitives.string_id } });
    try std.testing.expect(n3 != n1);
}

test "intern deduplicates slice and map types" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const s1 = try pool.intern(allocator, .{ .slice_type = .{ .elem = primitives.int_id } });
    const s2 = try pool.intern(allocator, .{ .slice_type = .{ .elem = primitives.int_id } });
    try std.testing.expectEqual(s1, s2);

    const m1 = try pool.intern(allocator, .{ .map_type = .{ .key = primitives.string_id, .value = primitives.int_id } });
    const m2 = try pool.intern(allocator, .{ .map_type = .{ .key = primitives.string_id, .value = primitives.int_id } });
    try std.testing.expectEqual(m1, m2);

    // Different key type => different map.
    const m3 = try pool.intern(allocator, .{ .map_type = .{ .key = primitives.int_id, .value = primitives.int_id } });
    try std.testing.expect(m3 != m1);
}

test "intern deduplicates array and chan types" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const a1 = try pool.intern(allocator, .{ .array_type = .{ .elem = primitives.f32_id, .len = 10 } });
    const a2 = try pool.intern(allocator, .{ .array_type = .{ .elem = primitives.f32_id, .len = 10 } });
    try std.testing.expectEqual(a1, a2);

    // Different length => different type.
    const a3 = try pool.intern(allocator, .{ .array_type = .{ .elem = primitives.f32_id, .len = 20 } });
    try std.testing.expect(a3 != a1);

    const c1 = try pool.intern(allocator, .{ .chan_type = .{ .elem = primitives.int_id } });
    const c2 = try pool.intern(allocator, .{ .chan_type = .{ .elem = primitives.int_id } });
    try std.testing.expectEqual(c1, c2);
}

test "intern deduplicates error union types" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const e1 = try pool.intern(allocator, .{ .error_union_type = .{ .payload = primitives.string_id } });
    const e2 = try pool.intern(allocator, .{ .error_union_type = .{ .payload = primitives.string_id } });
    try std.testing.expectEqual(e1, e2);

    const e3 = try pool.intern(allocator, .{ .error_union_type = .{ .payload = primitives.int_id } });
    try std.testing.expect(e3 != e1);
}

test "Type.eql" {
    const a = Type{ .int_type = .{ .bits = 32, .signed = true } };
    const b = Type{ .int_type = .{ .bits = 32, .signed = true } };
    const c = Type{ .int_type = .{ .bits = 64, .signed = true } };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(Type.void_type));
    const void_a: Type = .void_type;
    const void_b: Type = .void_type;
    try std.testing.expect(void_a.eql(void_b));
    const str_a: Type = .string_type;
    const str_b: Type = .string_type;
    try std.testing.expect(str_a.eql(str_b));
    const bool_a: Type = .bool_type;
    try std.testing.expect(!str_a.eql(bool_a));
}

test "typeEql via pool" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    // Same id is equal.
    try std.testing.expect(pool.typeEql(primitives.int_id, primitives.int_id));
    // Different primitives are not.
    try std.testing.expect(!pool.typeEql(primitives.int_id, primitives.uint_id));
    // i64 and int are structurally equal (both 64-bit signed).
    try std.testing.expect(pool.typeEql(primitives.int_id, primitives.i64_id));
}

test "isNumeric / isInteger / isFloat" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    try std.testing.expect(pool.isNumeric(primitives.int_id));
    try std.testing.expect(pool.isNumeric(primitives.f64_id));
    try std.testing.expect(!pool.isNumeric(primitives.string_id));
    try std.testing.expect(!pool.isNumeric(primitives.bool_id));

    try std.testing.expect(pool.isInteger(primitives.int_id));
    try std.testing.expect(pool.isInteger(primitives.byte_id));
    try std.testing.expect(!pool.isInteger(primitives.f32_id));

    try std.testing.expect(pool.isFloat(primitives.f32_id));
    try std.testing.expect(pool.isFloat(primitives.f64_id));
    try std.testing.expect(!pool.isFloat(primitives.int_id));
}

test "simd helpers" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    try std.testing.expect(pool.isSimd(primitives.v4f32_id));
    try std.testing.expect(!pool.isSimd(primitives.f32_id));
    try std.testing.expect(pool.isSimdMask(primitives.v8bool_id));
    try std.testing.expect(!pool.isSimdMask(primitives.v8f32_id));
    try std.testing.expectEqual(primitives.v4bool_id, pool.simdMaskFor(primitives.v4f32_id).?);
    try std.testing.expectEqual(primitives.f32_id, pool.simdElementType(primitives.v4f32_id).?);
    try std.testing.expectEqual(primitives.i16_id, pool.simdElementType(primitives.v8i16_id).?);
    try std.testing.expectEqual(@as(u32, 16), pool.simdAlignment(primitives.v4f32_id).?);
    try std.testing.expectEqual(@as(u32, 32), pool.simdAlignment(primitives.v8f32_id).?);
}

test "unwrap helpers" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const nullable_int = try pool.intern(allocator, .{ .nullable_type = .{ .inner = primitives.int_id } });
    try std.testing.expectEqual(primitives.int_id, pool.unwrapNullable(nullable_int).?);
    try std.testing.expect(pool.unwrapNullable(primitives.int_id) == null);

    const err_string = try pool.intern(allocator, .{ .error_union_type = .{ .payload = primitives.string_id } });
    try std.testing.expectEqual(primitives.string_id, pool.unwrapErrorUnion(err_string).?);
    try std.testing.expect(pool.unwrapErrorUnion(primitives.int_id) == null);

    const ptr_int = try pool.intern(allocator, .{ .ptr_type = .{ .pointee = primitives.int_id, .is_const = false } });
    try std.testing.expectEqual(primitives.int_id, pool.unwrapPointer(ptr_int).?);
    try std.testing.expect(pool.unwrapPointer(primitives.int_id) == null);

    const newtype_id = try pool.addType(allocator, .{ .newtype = .{ .name = "UserID", .underlying = primitives.int_id } });
    try std.testing.expectEqual(primitives.int_id, pool.unwrapNewtype(newtype_id).?);
    try std.testing.expect(pool.unwrapNewtype(primitives.int_id) == null);
}

test "isNullable / isErrorUnion" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    const nullable_int = try pool.intern(allocator, .{ .nullable_type = .{ .inner = primitives.int_id } });
    try std.testing.expect(pool.isNullable(nullable_int));
    try std.testing.expect(!pool.isNullable(primitives.int_id));

    const err_string = try pool.intern(allocator, .{ .error_union_type = .{ .payload = primitives.string_id } });
    try std.testing.expect(pool.isErrorUnion(err_string));
    try std.testing.expect(!pool.isErrorUnion(primitives.int_id));
}

test "fn_type equality" {
    const a = Type{ .fn_type = .{ .params = &[_]TypeId{ primitives.int_id, primitives.string_id }, .return_type = primitives.bool_id } };
    const b = Type{ .fn_type = .{ .params = &[_]TypeId{ primitives.int_id, primitives.string_id }, .return_type = primitives.bool_id } };
    const c = Type{ .fn_type = .{ .params = &[_]TypeId{primitives.int_id}, .return_type = primitives.bool_id } };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}
