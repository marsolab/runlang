const std = @import("std");
const types = @import("types.zig");
const ast = @import("ast.zig");

pub const TypeId = types.TypeId;
pub const NodeIndex = ast.NodeIndex;

/// A handle into the SymbolTable's symbol array.
pub const SymbolId = u32;

/// Sentinel: no symbol.
pub const null_symbol: SymbolId = std.math.maxInt(SymbolId);

pub const Symbol = struct {
    name: []const u8,
    kind: Kind,
    type_id: TypeId,
    is_pub: bool,
    is_mutable: bool,
    decl_node: NodeIndex,

    pub const Kind = enum {
        variable,
        function,
        type_def,
        param,
        field,
        method,
        package,
    };
};

/// A method table key: (type, method name) -> SymbolId.
const MethodKey = struct {
    type_id: TypeId,
    name: []const u8,
};

const MethodKeyContext = struct {
    pub fn hash(_: MethodKeyContext, key: MethodKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key.type_id));
        h.update(key.name);
        return h.final();
    }

    pub fn eql(_: MethodKeyContext, a: MethodKey, b: MethodKey) bool {
        return a.type_id == b.type_id and std.mem.eql(u8, a.name, b.name);
    }
};

pub const SymbolTable = struct {
    /// Flat array of all symbols. SymbolId is an index into this.
    symbols: std.ArrayList(Symbol),
    /// Stack of scopes. Each scope maps names to SymbolIds.
    scopes: std.ArrayList(Scope),
    /// Method table: (TypeId, method_name) -> SymbolId.
    method_table: std.HashMap(MethodKey, SymbolId, MethodKeyContext, std.hash_map.default_max_load_percentage),

    const Scope = std.StringHashMap(SymbolId);

    pub fn init(allocator: std.mem.Allocator) SymbolTable {
        var table = SymbolTable{
            .symbols = .empty,
            .scopes = .empty,
            .method_table = std.HashMap(MethodKey, SymbolId, MethodKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
        // Push the global scope.
        table.scopes.append(allocator, Scope.init(allocator)) catch unreachable;
        return table;
    }

    pub fn deinit(self: *SymbolTable, allocator: std.mem.Allocator) void {
        for (self.scopes.items) |*scope| {
            scope.deinit();
        }
        self.scopes.deinit(allocator);
        self.symbols.deinit(allocator);
        self.method_table.deinit();
    }

    /// Push a new child scope onto the scope stack.
    pub fn pushScope(self: *SymbolTable, allocator: std.mem.Allocator) !void {
        try self.scopes.append(allocator, Scope.init(allocator));
    }

    /// Pop the innermost scope. Panics if only the global scope remains.
    pub fn popScope(self: *SymbolTable, allocator: std.mem.Allocator) void {
        _ = allocator;
        std.debug.assert(self.scopes.items.len > 1);
        const len = self.scopes.items.len;
        self.scopes.items[len - 1].deinit();
        self.scopes.items.len = len - 1;
    }

    /// Define a symbol in the current (innermost) scope.
    /// Returns error.DuplicateSymbol if the name already exists in the current scope.
    pub fn define(self: *SymbolTable, allocator: std.mem.Allocator, name: []const u8, sym: Symbol) !SymbolId {
        const id: SymbolId = @intCast(self.symbols.items.len);
        const current = &self.scopes.items[self.scopes.items.len - 1];
        const result = try current.getOrPut(name);
        if (result.found_existing) {
            return error.DuplicateSymbol;
        }
        try self.symbols.append(allocator, sym);
        result.value_ptr.* = id;
        return id;
    }

    /// Look up a name starting from the innermost scope outward.
    /// Returns null if not found in any scope.
    pub fn lookup(self: *const SymbolTable, name: []const u8) ?SymbolId {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |id| {
                return id;
            }
        }
        return null;
    }

    /// Look up a name only in the current (innermost) scope.
    pub fn lookupInCurrentScope(self: *const SymbolTable, name: []const u8) ?SymbolId {
        return self.scopes.items[self.scopes.items.len - 1].get(name);
    }

    /// Get the Symbol for a given SymbolId.
    pub fn getSymbol(self: *const SymbolTable, id: SymbolId) Symbol {
        return self.symbols.items[id];
    }

    /// Register a method for a type.
    pub fn defineMethod(self: *SymbolTable, type_id: TypeId, name: []const u8, sym_id: SymbolId) !void {
        try self.method_table.put(.{ .type_id = type_id, .name = name }, sym_id);
    }

    /// Look up a method on a type.
    pub fn lookupMethod(self: *const SymbolTable, type_id: TypeId, name: []const u8) ?SymbolId {
        return self.method_table.get(.{ .type_id = type_id, .name = name });
    }

    /// Returns the current scope depth (0 = global).
    pub fn scopeDepth(self: *const SymbolTable) usize {
        return self.scopes.items.len - 1;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────────

test "define and lookup in global scope" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit(allocator);

    const id = try table.define(allocator, "x", .{
        .name = "x",
        .kind = .variable,
        .type_id = types.primitives.int_id,
        .is_pub = false,
        .is_mutable = true,
        .decl_node = 1,
    });

    try std.testing.expectEqual(id, table.lookup("x").?);
    try std.testing.expectEqualStrings("x", table.getSymbol(id).name);
    try std.testing.expectEqual(Symbol.Kind.variable, table.getSymbol(id).kind);
    try std.testing.expect(table.lookup("y") == null);
}

test "duplicate symbol in same scope" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit(allocator);

    _ = try table.define(allocator, "x", .{
        .name = "x",
        .kind = .variable,
        .type_id = types.primitives.int_id,
        .is_pub = false,
        .is_mutable = true,
        .decl_node = 1,
    });

    const result = table.define(allocator, "x", .{
        .name = "x",
        .kind = .variable,
        .type_id = types.primitives.string_id,
        .is_pub = false,
        .is_mutable = true,
        .decl_node = 2,
    });

    try std.testing.expectError(error.DuplicateSymbol, result);
}

test "scope shadowing" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit(allocator);

    const outer_id = try table.define(allocator, "x", .{
        .name = "x",
        .kind = .variable,
        .type_id = types.primitives.int_id,
        .is_pub = false,
        .is_mutable = true,
        .decl_node = 1,
    });

    try table.pushScope(allocator);

    // Same name in inner scope should work (shadowing).
    const inner_id = try table.define(allocator, "x", .{
        .name = "x",
        .kind = .variable,
        .type_id = types.primitives.string_id,
        .is_pub = false,
        .is_mutable = false,
        .decl_node = 2,
    });

    // Lookup should find inner.
    try std.testing.expectEqual(inner_id, table.lookup("x").?);
    try std.testing.expect(inner_id != outer_id);

    table.popScope(allocator);

    // After pop, should find outer again.
    try std.testing.expectEqual(outer_id, table.lookup("x").?);
}

test "nested scopes and lookupInCurrentScope" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit(allocator);

    _ = try table.define(allocator, "global", .{
        .name = "global",
        .kind = .variable,
        .type_id = types.primitives.int_id,
        .is_pub = true,
        .is_mutable = false,
        .decl_node = 1,
    });

    try table.pushScope(allocator);

    _ = try table.define(allocator, "local", .{
        .name = "local",
        .kind = .variable,
        .type_id = types.primitives.string_id,
        .is_pub = false,
        .is_mutable = true,
        .decl_node = 2,
    });

    // lookup finds both.
    try std.testing.expect(table.lookup("global") != null);
    try std.testing.expect(table.lookup("local") != null);

    // lookupInCurrentScope only finds local.
    try std.testing.expect(table.lookupInCurrentScope("local") != null);
    try std.testing.expect(table.lookupInCurrentScope("global") == null);

    table.popScope(allocator);

    // After pop, local is gone.
    try std.testing.expect(table.lookup("local") == null);
    try std.testing.expect(table.lookup("global") != null);
}

test "method table" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit(allocator);

    const point_type: TypeId = 100; // hypothetical type id

    const method_id = try table.define(allocator, "length", .{
        .name = "length",
        .kind = .method,
        .type_id = types.primitives.f64_id,
        .is_pub = true,
        .is_mutable = false,
        .decl_node = 5,
    });

    try table.defineMethod(point_type, "length", method_id);

    try std.testing.expectEqual(method_id, table.lookupMethod(point_type, "length").?);
    try std.testing.expect(table.lookupMethod(point_type, "nonexistent") == null);
    try std.testing.expect(table.lookupMethod(200, "length") == null);
}

test "scopeDepth" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), table.scopeDepth());

    try table.pushScope(allocator);
    try std.testing.expectEqual(@as(usize, 1), table.scopeDepth());

    try table.pushScope(allocator);
    try std.testing.expectEqual(@as(usize, 2), table.scopeDepth());

    table.popScope(allocator);
    try std.testing.expectEqual(@as(usize, 1), table.scopeDepth());

    table.popScope(allocator);
    try std.testing.expectEqual(@as(usize, 0), table.scopeDepth());
}

test "multiple symbols in same scope" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit(allocator);

    const a = try table.define(allocator, "a", .{
        .name = "a",
        .kind = .variable,
        .type_id = types.primitives.int_id,
        .is_pub = false,
        .is_mutable = true,
        .decl_node = 1,
    });
    const b = try table.define(allocator, "b", .{
        .name = "b",
        .kind = .function,
        .type_id = types.primitives.void_id,
        .is_pub = true,
        .is_mutable = false,
        .decl_node = 2,
    });
    const c = try table.define(allocator, "c", .{
        .name = "c",
        .kind = .type_def,
        .type_id = types.primitives.string_id,
        .is_pub = false,
        .is_mutable = false,
        .decl_node = 3,
    });

    try std.testing.expectEqual(a, table.lookup("a").?);
    try std.testing.expectEqual(b, table.lookup("b").?);
    try std.testing.expectEqual(c, table.lookup("c").?);
    try std.testing.expect(a != b);
    try std.testing.expect(b != c);
}
