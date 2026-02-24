const std = @import("std");
const Token = @import("token.zig").Token;

/// Index into the nodes array of an Ast.
pub const NodeIndex = u32;
pub const null_node: NodeIndex = 0;

/// Represents a source location range for error reporting.
pub const Span = struct {
    start: u32,
    end: u32,
};

/// Abstract Syntax Tree for the Run language.
pub const Ast = struct {
    source: []const u8,
    nodes: std.ArrayList(Node),
    extra_data: std.ArrayList(NodeIndex),
    errors: std.ArrayList(Error),
    allocator: std.mem.Allocator,

    pub const Error = struct {
        tag: ErrorTag,
        loc: Token.Loc,
        expected: ?Token.Tag = null,
    };

    pub const ErrorTag = enum {
        expected_token,
        expected_expression,
        expected_type,
        expected_identifier,
        expected_block,
        invalid_token,
        unexpected_eof,
    };

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Ast {
        var nodes: std.ArrayList(Node) = .empty;
        // Reserve index 0 as null sentinel
        nodes.append(allocator, .{ .tag = .root, .main_token = 0, .data = .{ .lhs = 0, .rhs = 0 } }) catch {};
        return .{
            .source = source,
            .nodes = nodes,
            .extra_data = .empty,
            .errors = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Ast) void {
        self.nodes.deinit(self.allocator);
        self.extra_data.deinit(self.allocator);
        self.errors.deinit(self.allocator);
    }

    pub fn addNode(self: *Ast, node: Node) !NodeIndex {
        const index: NodeIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        return index;
    }

    pub fn addExtra(self: *Ast, data: NodeIndex) !u32 {
        const index: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.append(self.allocator, data);
        return index;
    }
};

pub const Node = struct {
    tag: Tag,
    main_token: u32,
    data: Data,

    pub const Data = struct {
        lhs: NodeIndex,
        rhs: NodeIndex,
    };

    pub const Tag = enum(u8) {
        // Top-level
        root,

        // Declarations
        /// `fn name(params) ret_type { body }`
        /// lhs = params (extra_data range), rhs = body block
        fn_decl,
        /// `pub fn ...` wraps fn_decl
        /// lhs = inner declaration node
        pub_decl,
        /// `var name type = expr` or `var name type`
        /// lhs = type node (or null_node), rhs = init expr (or null_node)
        var_decl,
        /// `const name type = expr`
        /// lhs = type node (or null_node), rhs = init expr (or null_node)
        const_decl,
        /// `name := expr`
        /// lhs = null_node, rhs = init expr
        short_var_decl,
        /// `struct { fields }`
        /// lhs = extra_data start for fields, rhs = field count
        struct_decl,
        /// `trait { methods }`
        /// lhs = extra_data start for method sigs, rhs = count
        trait_decl,
        /// `impl Trait for Type { methods }`
        /// lhs = trait name node, rhs = extra_data start for methods
        impl_decl,
        /// `type Name = variants`
        /// lhs = extra_data start for variants, rhs = variant count
        type_alias,
        /// `import "path"`
        /// main_token points to the string literal
        import_decl,

        // Struct internals
        /// A single struct field: `name: type`
        /// lhs = type node, rhs = default value (or null_node)
        field_decl,

        // Function parts
        /// A function parameter: `name: type`
        /// lhs = type node
        param,
        /// A method receiver: `(self: &Type)` or `(self: @Type)`
        /// lhs = type node
        receiver,

        // Statements
        /// `return expr`
        /// lhs = expr (or null_node for bare return)
        return_stmt,
        /// `defer expr`
        /// lhs = expr
        defer_stmt,
        /// `break`
        break_stmt,
        /// `continue`
        continue_stmt,
        /// `run expr`
        /// lhs = function call expr
        run_stmt,
        /// Expression used as statement
        /// lhs = expr
        expr_stmt,
        /// `{ stmts }`
        /// lhs = extra_data start, rhs = statement count
        block,
        /// `if cond { then } else { otherwise }`
        /// lhs = condition, rhs = then block (else stored in extra_data)
        if_stmt,
        /// `for cond { body }` or `for item in iter { body }`
        /// lhs = condition/iterator, rhs = body block
        for_stmt,
        /// `switch expr { arms }`
        /// lhs = expr, rhs = extra_data start for arms
        switch_stmt,
        /// A single switch arm: `pattern => expr`
        /// lhs = pattern, rhs = body
        switch_arm,
        /// Assignment: `lhs = rhs`
        assign,
        /// Channel send: `ch <- val`
        /// lhs = channel expr, rhs = value expr
        chan_send,

        // Expressions
        /// Integer literal
        int_literal,
        /// Float literal
        float_literal,
        /// String literal
        string_literal,
        /// Bool literal (true/false)
        bool_literal,
        /// `null`
        null_literal,
        /// Identifier reference
        ident,
        /// `a + b`, `a - b`, etc.
        /// lhs = left operand, rhs = right operand
        binary_op,
        /// `-a`, `!a`, `not a`
        /// lhs = operand
        unary_op,
        /// `func(args)`
        /// lhs = callee, rhs = extra_data start for args
        call,
        /// Struct literal: `Type{ field: val, ... }` or `Type{ .field = val, ... }`
        /// lhs = type name node, rhs = extra_data start for field inits
        struct_literal,
        /// A struct literal field init: `name: expr` or `name = expr`
        /// lhs = value expr
        struct_field_init,
        /// `obj.field`
        /// lhs = object expr
        field_access,
        /// `arr[index]`
        /// lhs = array expr, rhs = index expr
        index_access,
        /// `&expr` (address-of, read/write pointer)
        addr_of,
        /// `@expr` (address-of, read-only pointer)
        addr_of_const,
        /// `expr.*` or `*expr` (dereference)
        deref,
        /// `try expr`
        try_expr,
        /// Range expression: `a..b`
        /// lhs = start, rhs = end
        range,
        /// `<-ch` (channel receive)
        /// lhs = channel expr
        chan_recv,
        /// Anonymous function / closure
        /// lhs = params (extra_data range), rhs = body
        closure,
        /// `.variant` or `.variant(data)` — sum type variant
        /// lhs = data expr (or null_node)
        variant,

        // Types (used in type position)
        /// Simple named type: `int`, `str`, `MyStruct`
        type_name,
        /// Pointer type: `&T`
        type_ptr,
        /// Const pointer type: `@T`
        type_const_ptr,
        /// Nullable type: `T?`
        type_nullable,
        /// Error union type: `!T`
        type_error_union,
        /// Slice type: `[]T`
        type_slice,
        /// Channel type: `chan T`
        type_chan,
        /// Array type: `[N]T`
        type_array,
    };
};
