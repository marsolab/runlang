const std = @import("std");
const ast = @import("ast.zig");
const Ast = ast.Ast;
const Node = ast.Node;
const NodeIndex = ast.NodeIndex;
const null_node = ast.null_node;
const Token = @import("token.zig").Token;

/// Formats Run language source code from a parsed AST back to canonical form.
pub const Formatter = struct {
    tree: *const Ast,
    tokens: []const Token,
    source: []const u8,
    buf: std.ArrayList(u8),
    indent_level: u32,
    allocator: std.mem.Allocator,

    const indent_width = 4;

    pub fn init(allocator: std.mem.Allocator, tree: *const Ast, tokens: []const Token, source: []const u8) Formatter {
        return .{
            .tree = tree,
            .tokens = tokens,
            .source = source,
            .buf = .empty,
            .indent_level = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Formatter) void {
        self.buf.deinit(self.allocator);
    }

    pub fn format(self: *Formatter) ![]const u8 {
        const root = self.tree.nodes.items[0];
        const start = root.data.lhs;
        const count = root.data.rhs;
        const decl_indices = self.tree.extra_data.items[start .. start + count];

        for (decl_indices, 0..) |decl_idx, i| {
            if (i > 0) {
                // Blank line between top-level declarations
                try self.newline();
            }
            try self.formatNode(decl_idx);
            try self.newline();
        }

        return self.buf.items;
    }

    fn formatNode(self: *Formatter, idx: NodeIndex) error{OutOfMemory}!void {
        if (idx == null_node) return;
        const node = self.tree.nodes.items[idx];
        switch (node.tag) {
            .root => {},
            .package_decl => try self.formatPackageDecl(node),
            .import_decl => try self.formatImportDecl(node),
            .fn_decl => try self.formatFnDecl(node),
            .pub_decl => try self.formatPubDecl(node),
            .inline_decl => try self.formatInlineDecl(node),
            .var_decl => try self.formatVarDecl(node),
            .let_decl => try self.formatLetDecl(node),
            .short_var_decl => try self.formatShortVarDecl(node),
            .struct_decl => try self.formatStructDecl(node),
            .interface_decl => try self.formatInterfaceDecl(node),
            .type_alias => try self.formatTypeAlias(node),
            .type_decl => try self.formatTypeDecl(node),
            .field_decl => try self.formatFieldDecl(node),
            .return_stmt => try self.formatReturnStmt(node),
            .defer_stmt => try self.formatDeferStmt(node),
            .break_stmt => try self.write("break"),
            .continue_stmt => try self.write("continue"),
            .run_stmt => try self.formatRunStmt(node),
            .expr_stmt => try self.formatNode(node.data.lhs),
            .block => try self.formatBlock(node),
            .if_stmt => try self.formatIfStmt(node),
            .if_expr => try self.formatIfExpr(node),
            .for_stmt => try self.formatForStmt(node),
            .switch_stmt => try self.formatSwitchStmt(node),
            .switch_arm => try self.formatSwitchArm(node),
            .assign => try self.formatAssign(node),
            .chan_send => try self.formatChanSend(node),
            .int_literal, .float_literal, .string_literal, .bool_literal, .null_literal => try self.formatLiteral(node),
            .ident => try self.formatIdent(node),
            .binary_op => try self.formatBinaryOp(node),
            .unary_op => try self.formatUnaryOp(node),
            .call => try self.formatCall(node),
            .struct_literal => try self.formatStructLiteral(node),
            .simd_literal => try self.formatSimdLiteral(node),
            .array_literal => try self.formatArrayLiteral(node),
            .tuple_literal => try self.formatTupleLiteral(node),
            .struct_field_init => try self.formatStructFieldInit(node),
            .field_access => try self.formatFieldAccess(node),
            .index_access => try self.formatIndexAccess(node),
            .addr_of => try self.formatAddrOf(node),
            .addr_of_const => try self.formatAddrOfConst(node),
            .deref => try self.formatDeref(node),
            .try_expr => try self.formatTryExpr(node),
            .range => try self.formatRange(node),
            .chan_recv => try self.formatChanRecv(node),
            .closure => try self.formatClosure(node),
            .variant => try self.formatVariant(node),
            .alloc_expr => try self.formatAllocExpr(node),
            .anon_struct_literal => try self.formatAnonStructLiteral(node),
            .type_name => try self.formatTypeName(node),
            .type_ptr => try self.formatTypePtr(node),
            .type_const_ptr => try self.formatTypeConstPtr(node),
            .type_nullable => try self.formatTypeNullable(node),
            .type_error_union => try self.formatTypeErrorUnion(node),
            .type_slice => try self.formatTypeSlice(node),
            .type_chan => try self.formatTypeChan(node),
            .type_map => try self.formatTypeMap(node),
            .type_array => try self.formatTypeArray(node),
            .type_tuple => try self.formatTypeTuple(node),
            .type_anon_struct => try self.formatTypeAnonStruct(node),
            .param => try self.formatParam(node),
            .variadic_param => try self.formatVariadicParam(node),
            .receiver => try self.formatReceiver(node),
            .method_sig => try self.formatMethodSig(node),
            .asm_expr => try self.formatAsmExpr(node),
            .asm_input => try self.formatAsmInput(node),
            .asm_body => try self.formatAsmBody(node),
            .asm_simple_body => try self.formatAsmSimpleBody(node),
            .asm_platform => try self.formatAsmPlatform(node),
        }
    }

    // --- Top-level declarations ---

    fn formatPackageDecl(self: *Formatter, node: Node) !void {
        try self.write("package ");
        try self.writeToken(node.main_token);
    }

    fn formatImportDecl(self: *Formatter, node: Node) !void {
        try self.write("use ");
        try self.writeToken(node.main_token);
    }

    fn formatPubDecl(self: *Formatter, node: Node) !void {
        try self.write("pub ");
        try self.formatNode(node.data.lhs);
    }

    fn formatInlineDecl(self: *Formatter, node: Node) !void {
        try self.write("inline ");
        try self.formatNode(node.data.lhs);
    }

    fn formatFnDecl(self: *Formatter, node: Node) !void {
        try self.write("fun ");

        // extra_data layout: [param1, ..., paramN, count, receiver_node, ret_type]
        const params_start = node.data.lhs;
        const body = node.data.rhs;

        // Read count from extra_data to find params
        // We need to scan to find the count — it's at some offset
        // The fn_tok is main_token, next token is the name (or receiver comes first)

        // Read receiver and ret_type from extra_data
        // Extra data after params: [...params, count, receiver, ret_type]
        // We need to find count first
        var idx = params_start;
        // Scan forward to find the count (it stores a value that, when read back
        // to the start, gives us the right number of params)
        // Actually, the layout is: extra_data[params_start..] = [p1, p2, ..., pN, N, receiver, ret_type]
        // So we need to find N. We read values until we find one where
        // extra_data[params_start + val] == val
        // Simpler: look at the pattern. We know the fn_tok, next comes name.
        // Let's just iterate to find count by looking at the stored count value.
        // The count is stored after all params. We can find it by reading until
        // the value at position i equals (i - params_start).
        var param_count: u32 = 0;
        // Try to find count: it's stored such that extra_data[params_start + param_count] == param_count
        while (idx < self.tree.extra_data.items.len) {
            const val = self.tree.extra_data.items[idx];
            if (val == idx - params_start) {
                param_count = val;
                break;
            }
            idx += 1;
        }
        const receiver_idx = self.tree.extra_data.items[params_start + param_count + 1];
        const ret_type_idx = self.tree.extra_data.items[params_start + param_count + 2];

        // Receiver
        if (receiver_idx != null_node) {
            try self.formatNode(receiver_idx);
            try self.write(" ");
        }

        // Function name - it's the token after fn keyword
        const fn_tok = node.main_token;
        // For methods with receiver, the name is fn_tok+1
        try self.writeToken(fn_tok + 1);

        // Parameters
        try self.write("(");
        const params = self.tree.extra_data.items[params_start .. params_start + param_count];
        for (params, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            try self.formatNode(p);
        }
        try self.write(")");

        // Return type
        if (ret_type_idx != null_node) {
            try self.write(" ");
            try self.formatNode(ret_type_idx);
        }

        // Body
        if (body != null_node) {
            try self.write(" ");
            try self.formatNode(body);
        }
    }

    fn formatVarDecl(self: *Formatter, node: Node) !void {
        try self.write("var ");
        // main_token points to kw_var, name is next token
        try self.writeToken(node.main_token + 1);

        // Type
        if (node.data.lhs != null_node) {
            try self.write(" ");
            try self.formatNode(node.data.lhs);
        }

        // Init
        if (node.data.rhs != null_node) {
            try self.write(" = ");
            try self.formatNode(node.data.rhs);
        }
    }

    fn formatLetDecl(self: *Formatter, node: Node) !void {
        try self.write("let ");
        try self.writeToken(node.main_token + 1);

        // Type
        if (node.data.lhs != null_node) {
            try self.write(" ");
            try self.formatNode(node.data.lhs);
        }

        // Init (required for let)
        try self.write(" = ");
        try self.formatNode(node.data.rhs);
    }

    fn formatShortVarDecl(self: *Formatter, node: Node) !void {
        // lhs is an ident node (the name), main_token is :=
        try self.formatNode(node.data.lhs);
        try self.write(" := ");
        try self.formatNode(node.data.rhs);
    }

    fn formatStructDecl(self: *Formatter, node: Node) !void {
        // main_token = name identifier
        try self.writeToken(node.main_token);
        try self.write(" struct {");

        const extra_start = node.data.lhs;
        const field_count = node.data.rhs;

        // First value in extra_data is implements_count
        const implements_count = self.tree.extra_data.items[extra_start];

        // Implements interfaces
        if (implements_count > 0) {
            try self.newline();
            self.indent_level += 1;
            try self.writeIndent();
            try self.write("implements(");
            var i: u32 = 0;
            while (i < implements_count) : (i += 1) {
                if (i > 0) try self.write(", ");
                const iface_idx = self.tree.extra_data.items[extra_start + 1 + i];
                try self.formatNode(iface_idx);
            }
            try self.write(")");
            self.indent_level -= 1;
        }

        // Fields
        const fields_start = extra_start + 1 + implements_count;
        if (field_count > 0) {
            try self.newline();
            self.indent_level += 1;
            var i: u32 = 0;
            while (i < field_count) : (i += 1) {
                try self.writeIndent();
                const field_idx = self.tree.extra_data.items[fields_start + i];
                try self.formatNode(field_idx);
                try self.newline();
            }
            self.indent_level -= 1;
        } else if (implements_count > 0) {
            try self.newline();
        }

        try self.writeIndent();
        try self.write("}");
    }

    fn formatInterfaceDecl(self: *Formatter, node: Node) !void {
        const name_tok = if (self.tokens[node.main_token].tag == .kw_interface) node.main_token + 1 else node.main_token;
        try self.write("interface ");
        try self.writeToken(name_tok);
        try self.write(" {");

        const methods_start = node.data.lhs;
        const method_count = node.data.rhs;

        if (method_count > 0) {
            try self.newline();
            self.indent_level += 1;
            var i: u32 = 0;
            while (i < method_count) : (i += 1) {
                try self.writeIndent();
                const method_idx = self.tree.extra_data.items[methods_start + i];
                try self.formatNode(method_idx);
                try self.newline();
            }
            self.indent_level -= 1;
        }

        try self.writeIndent();
        try self.write("}");
    }

    fn formatMethodSig(self: *Formatter, node: Node) !void {
        // main_token = method name
        try self.writeToken(node.main_token);

        // Parameters from extra_data
        const params_start = node.data.lhs;
        try self.write("(");
        var pidx = params_start;
        var param_count: u32 = 0;
        while (pidx < self.tree.extra_data.items.len) {
            const val = self.tree.extra_data.items[pidx];
            if (val == pidx - params_start) {
                param_count = val;
                break;
            }
            pidx += 1;
        }
        const params = self.tree.extra_data.items[params_start .. params_start + param_count];
        for (params, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            try self.formatNode(p);
        }
        try self.write(")");

        // Return type is stored after [params..., count] in extra_data
        const ret_type_idx = self.tree.extra_data.items[params_start + param_count + 1];
        if (ret_type_idx != null_node) {
            try self.write(" ");
            try self.formatNode(ret_type_idx);
        }
    }

    fn formatTypeAlias(self: *Formatter, node: Node) !void {
        try self.write("type ");
        // main_token = kw_type, name is next token
        try self.writeToken(node.main_token + 1);
        try self.write(" = ");

        // Variants in extra_data
        const variants_start = node.data.lhs;
        const variant_count = node.data.rhs;
        var i: u32 = 0;
        while (i < variant_count) : (i += 1) {
            if (i > 0) try self.write(" | ");
            const v_idx = self.tree.extra_data.items[variants_start + i];
            try self.formatNode(v_idx);
        }
    }

    fn formatTypeDecl(self: *Formatter, node: Node) !void {
        try self.write("type ");
        try self.writeToken(node.main_token + 1);
        try self.write(" ");
        try self.formatNode(node.data.lhs);
    }

    fn formatFieldDecl(self: *Formatter, node: Node) !void {
        try self.writeToken(node.main_token);
        try self.write(" ");
        try self.formatNode(node.data.lhs); // type

        if (node.data.rhs != null_node) {
            try self.write(" = ");
            try self.formatNode(node.data.rhs); // default
        }
    }

    fn formatParam(self: *Formatter, node: Node) !void {
        try self.writeToken(node.main_token);
        try self.write(" ");
        try self.formatNode(node.data.lhs); // type
    }

    fn formatVariadicParam(self: *Formatter, node: Node) !void {
        try self.writeToken(node.main_token);
        try self.write(" ...");
        try self.formatNode(node.data.lhs);
    }

    fn formatReceiver(self: *Formatter, node: Node) !void {
        try self.write("(");
        try self.writeToken(node.main_token);
        try self.write(" ");
        try self.formatNode(node.data.lhs); // type
        try self.write(")");
    }

    // --- Statements ---

    fn formatReturnStmt(self: *Formatter, node: Node) !void {
        try self.write("return");
        if (node.data.lhs != null_node) {
            try self.write(" ");
            try self.formatNode(node.data.lhs);
        }
    }

    fn formatDeferStmt(self: *Formatter, node: Node) !void {
        try self.write("defer ");
        try self.formatNode(node.data.lhs);
    }

    fn formatRunStmt(self: *Formatter, node: Node) !void {
        try self.write("run ");
        try self.formatNode(node.data.lhs);
    }

    fn formatBlock(self: *Formatter, node: Node) !void {
        const start = node.data.lhs;
        const count = node.data.rhs;

        try self.write("{");

        if (count > 0) {
            try self.newline();
            self.indent_level += 1;
            const stmts = self.tree.extra_data.items[start .. start + count];
            for (stmts) |stmt_idx| {
                try self.writeIndent();
                try self.formatNode(stmt_idx);
                try self.newline();
            }
            self.indent_level -= 1;
        }

        try self.writeIndent();
        try self.write("}");
    }

    fn formatIfStmt(self: *Formatter, node: Node) !void {
        try self.write("if ");
        try self.formatNode(node.data.lhs); // condition

        const extra_start = node.data.rhs;
        const then_block = self.tree.extra_data.items[extra_start];
        const else_node = self.tree.extra_data.items[extra_start + 1];

        try self.write(" ");
        try self.formatNode(then_block);

        if (else_node != null_node) {
            try self.write(" else ");
            try self.formatNode(else_node);
        }
    }

    fn formatIfExpr(self: *Formatter, node: Node) !void {
        try self.write("if ");
        try self.formatNode(node.data.lhs); // condition
        try self.write(" :: ");

        const extra_start = node.data.rhs;
        const then_expr = self.tree.extra_data.items[extra_start];
        const else_expr = self.tree.extra_data.items[extra_start + 1];

        try self.formatNode(then_expr);
        try self.write(" else ");
        try self.formatNode(else_expr);
    }

    fn formatForStmt(self: *Formatter, node: Node) !void {
        try self.write("for ");

        if (node.data.lhs == null_node) {
            // Infinite loop: for { }
            try self.formatNode(node.data.rhs);
            return;
        }

        // Check if this is a for-in by looking at the node structure
        // For for-in, there's an extra_data entry before the body for the iteration variable
        // Actually, the for-in stores: lhs = iterable, rhs = body
        // and the iteration variable is in extra_data just before body was appended
        // We can detect for-in by checking if the token sequence has 'in'

        // Look at the tokens around the for keyword
        const for_tok = node.main_token;
        // After 'for', scan for 'in' keyword before '{'
        var scan = for_tok + 1;
        var is_for_in = false;
        while (scan < self.tokens.len) {
            if (self.tokens[scan].tag == .kw_in) {
                is_for_in = true;
                break;
            }
            if (self.tokens[scan].tag == .l_brace) break;
            scan += 1;
        }

        if (is_for_in) {
            // for item in collection { body }
            // The iteration variable was pushed to extra_data
            // lhs = iterable, rhs = body
            // Find the iter var from extra_data (it's at body's extra_data position - 1... actually it's stored at some point)
            // Easier: just look at the token after 'for' — that's the variable name
            try self.writeToken(for_tok + 1);
            try self.write(" in ");
            try self.formatNode(node.data.lhs);
        } else {
            // for condition { body }
            try self.formatNode(node.data.lhs);
        }

        try self.write(" ");
        try self.formatNode(node.data.rhs);
    }

    fn formatSwitchStmt(self: *Formatter, node: Node) !void {
        try self.write("switch ");
        try self.formatNode(node.data.lhs);
        try self.write(" {");

        const arms_start = node.data.rhs;
        // Find arm count — stored after all arm indices
        var aidx = arms_start;
        while (aidx < self.tree.extra_data.items.len) {
            // The count is stored at arms_start + count
            const val = self.tree.extra_data.items[aidx];
            if (val == aidx - arms_start) {
                break;
            }
            aidx += 1;
        }
        const arm_count = self.tree.extra_data.items[aidx];
        const arms = self.tree.extra_data.items[arms_start .. arms_start + arm_count];

        if (arms.len > 0) {
            try self.newline();
            self.indent_level += 1;
            for (arms) |arm_idx| {
                try self.writeIndent();
                try self.formatNode(arm_idx);
                try self.newline();
            }
            self.indent_level -= 1;
        }

        try self.writeIndent();
        try self.write("}");
    }

    fn formatSwitchArm(self: *Formatter, node: Node) !void {
        try self.formatNode(node.data.lhs); // pattern
        try self.write(" :: ");
        try self.formatNode(node.data.rhs); // body
    }

    fn formatAssign(self: *Formatter, node: Node) !void {
        try self.formatNode(node.data.lhs);
        try self.write(" = ");
        try self.formatNode(node.data.rhs);
    }

    fn formatChanSend(self: *Formatter, node: Node) !void {
        try self.formatNode(node.data.lhs);
        try self.write(" <- ");
        try self.formatNode(node.data.rhs);
    }

    // --- Expressions ---

    fn formatLiteral(self: *Formatter, node: Node) !void {
        try self.writeToken(node.main_token);
    }

    fn formatIdent(self: *Formatter, node: Node) !void {
        try self.writeToken(node.main_token);
    }

    fn formatBinaryOp(self: *Formatter, node: Node) !void {
        try self.formatNode(node.data.lhs);
        try self.write(" ");
        try self.writeToken(node.main_token);
        try self.write(" ");
        try self.formatNode(node.data.rhs);
    }

    fn formatUnaryOp(self: *Formatter, node: Node) !void {
        const tag = self.tokens[node.main_token].tag;
        if (tag == .kw_not) {
            try self.write("not ");
        } else {
            try self.writeToken(node.main_token);
        }
        try self.formatNode(node.data.lhs);
    }

    fn formatCall(self: *Formatter, node: Node) !void {
        try self.formatNode(node.data.lhs); // callee

        const args_start = node.data.rhs;
        // Find arg count
        var aidx = args_start;
        while (aidx < self.tree.extra_data.items.len) {
            const val = self.tree.extra_data.items[aidx];
            if (val == aidx - args_start) break;
            aidx += 1;
        }
        const arg_count = self.tree.extra_data.items[aidx];
        const args = self.tree.extra_data.items[args_start .. args_start + arg_count];

        try self.write("(");
        for (args, 0..) |a, i| {
            if (i > 0) try self.write(", ");
            try self.formatNode(a);
        }
        try self.write(")");
    }

    fn formatStructLiteral(self: *Formatter, node: Node) !void {
        try self.formatNode(node.data.lhs); // type name

        const fields_start = node.data.rhs;
        var fidx = fields_start;
        while (fidx < self.tree.extra_data.items.len) {
            const val = self.tree.extra_data.items[fidx];
            if (val == fidx - fields_start) break;
            fidx += 1;
        }
        const field_count = self.tree.extra_data.items[fidx];
        const fields = self.tree.extra_data.items[fields_start .. fields_start + field_count];

        try self.write("{");
        for (fields, 0..) |f, i| {
            if (i > 0) try self.write(", ");
            try self.formatNode(f);
        }
        try self.write("}");
    }

    fn formatSimdLiteral(self: *Formatter, node: Node) !void {
        try self.formatNode(node.data.lhs); // type name

        const lanes_start = node.data.rhs;
        var lane_idx = lanes_start;
        while (lane_idx < self.tree.extra_data.items.len) {
            const val = self.tree.extra_data.items[lane_idx];
            if (val == lane_idx - lanes_start) break;
            lane_idx += 1;
        }
        const lane_count = self.tree.extra_data.items[lane_idx];
        const lanes = self.tree.extra_data.items[lanes_start .. lanes_start + lane_count];

        try self.write("{");
        for (lanes, 0..) |lane, i| {
            if (i > 0) try self.write(", ");
            try self.formatNode(lane);
        }
        try self.write("}");
    }

    fn formatArrayLiteral(self: *Formatter, node: Node) !void {
        const elems_start = node.data.rhs;
        var elem_idx = elems_start;
        while (elem_idx < self.tree.extra_data.items.len) {
            const val = self.tree.extra_data.items[elem_idx];
            if (val == elem_idx - elems_start) break;
            elem_idx += 1;
        }
        const elem_count = self.tree.extra_data.items[elem_idx];
        const elems = self.tree.extra_data.items[elems_start .. elems_start + elem_count];

        if (node.data.lhs != null_node) {
            try self.formatNode(node.data.lhs);
            try self.write("{");
        } else {
            try self.write("[");
        }

        for (elems, 0..) |elem, i| {
            if (i > 0) try self.write(", ");
            try self.formatNode(elem);
        }

        if (node.data.lhs != null_node) {
            try self.write("}");
        } else {
            try self.write("]");
        }
    }

    fn formatTupleLiteral(self: *Formatter, node: Node) !void {
        const items_start = node.data.rhs;
        var item_idx = items_start;
        while (item_idx < self.tree.extra_data.items.len) {
            const val = self.tree.extra_data.items[item_idx];
            if (val == item_idx - items_start) break;
            item_idx += 1;
        }
        const item_count = self.tree.extra_data.items[item_idx];
        const items = self.tree.extra_data.items[items_start .. items_start + item_count];

        try self.write("(");
        for (items, 0..) |item, i| {
            if (i > 0) try self.write(", ");
            try self.formatNode(item);
        }
        try self.write(")");
    }

    fn formatStructFieldInit(self: *Formatter, node: Node) !void {
        try self.writeToken(node.main_token);
        try self.write(": ");
        try self.formatNode(node.data.lhs);
    }

    fn formatFieldAccess(self: *Formatter, node: Node) !void {
        try self.formatNode(node.data.lhs);
        try self.write(".");
        // The field name is the token after the dot
        try self.writeToken(node.main_token + 1);
    }

    fn formatIndexAccess(self: *Formatter, node: Node) !void {
        try self.formatNode(node.data.lhs);
        try self.write("[");
        try self.formatNode(node.data.rhs);
        try self.write("]");
    }

    fn formatAddrOf(self: *Formatter, node: Node) !void {
        try self.write("&");
        try self.formatNode(node.data.lhs);
    }

    fn formatAddrOfConst(self: *Formatter, node: Node) !void {
        try self.write("@");
        try self.formatNode(node.data.lhs);
    }

    fn formatDeref(self: *Formatter, node: Node) !void {
        try self.formatNode(node.data.lhs);
        try self.write(".*");
    }

    fn formatTryExpr(self: *Formatter, node: Node) !void {
        try self.write("try ");
        try self.formatNode(node.data.lhs);
        if (node.data.rhs != null_node) {
            try self.write(" :: ");
            try self.formatNode(node.data.rhs);
        }
    }

    fn formatRange(self: *Formatter, node: Node) !void {
        try self.formatNode(node.data.lhs);
        try self.write("..");
        try self.formatNode(node.data.rhs);
    }

    fn formatChanRecv(self: *Formatter, node: Node) !void {
        try self.write("<-");
        try self.formatNode(node.data.lhs);
    }

    fn formatClosure(self: *Formatter, node: Node) !void {
        try self.write("fun");

        const params_start = node.data.lhs;
        const body = node.data.rhs;

        var pidx = params_start;
        var param_count: u32 = 0;
        while (pidx < self.tree.extra_data.items.len) {
            const val = self.tree.extra_data.items[pidx];
            if (val == pidx - params_start) {
                param_count = val;
                break;
            }
            pidx += 1;
        }

        try self.write("(");
        const params = self.tree.extra_data.items[params_start .. params_start + param_count];
        for (params, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            try self.formatNode(p);
        }
        try self.write(")");

        // Return type is at params_start + param_count + 1
        const ret_type_idx = self.tree.extra_data.items[params_start + param_count + 1];
        if (ret_type_idx != null_node) {
            try self.write(" ");
            try self.formatNode(ret_type_idx);
        }

        try self.write(" ");
        try self.formatNode(body);
    }

    fn formatVariant(self: *Formatter, node: Node) !void {
        try self.write(".");
        // Variant name is token after the dot
        try self.writeToken(node.main_token + 1);
        if (node.data.lhs != null_node) {
            try self.write("(");
            try self.formatNode(node.data.lhs);
            try self.write(")");
        }
    }

    fn formatAllocExpr(self: *Formatter, node: Node) !void {
        try self.write("alloc(");
        try self.formatNode(node.data.lhs); // type

        const extra_start = node.data.rhs;
        const capacity = self.tree.extra_data.items[extra_start];
        const allocator_expr = self.tree.extra_data.items[extra_start + 1];

        if (capacity != null_node) {
            try self.write(", ");
            try self.formatNode(capacity);
        }
        if (allocator_expr != null_node) {
            try self.write(", allocator: ");
            try self.formatNode(allocator_expr);
        }
        try self.write(")");
    }

    fn formatAnonStructLiteral(self: *Formatter, node: Node) !void {
        const fields_start = node.data.rhs;
        var fidx = fields_start;
        while (fidx < self.tree.extra_data.items.len) {
            const val = self.tree.extra_data.items[fidx];
            if (val == fidx - fields_start) break;
            fidx += 1;
        }
        const field_count = self.tree.extra_data.items[fidx];
        const fields = self.tree.extra_data.items[fields_start .. fields_start + field_count];

        try self.write(".{");
        for (fields, 0..) |f, i| {
            if (i > 0) try self.write(", ");
            try self.formatNode(f);
        }
        try self.write("}");
    }

    // --- Types ---

    fn formatTypeName(self: *Formatter, node: Node) !void {
        try self.writeToken(node.main_token);
    }

    fn formatTypePtr(self: *Formatter, node: Node) !void {
        try self.write("&");
        try self.formatNode(node.data.lhs);
    }

    fn formatTypeConstPtr(self: *Formatter, node: Node) !void {
        try self.write("@");
        try self.formatNode(node.data.lhs);
    }

    fn formatTypeNullable(self: *Formatter, node: Node) !void {
        try self.formatNode(node.data.lhs);
        try self.write("?");
    }

    fn formatTypeErrorUnion(self: *Formatter, node: Node) !void {
        try self.write("!");
        try self.formatNode(node.data.lhs);
    }

    fn formatTypeSlice(self: *Formatter, node: Node) !void {
        try self.write("[]");
        try self.formatNode(node.data.lhs);
    }

    fn formatTypeChan(self: *Formatter, node: Node) !void {
        try self.write("chan ");
        try self.formatNode(node.data.lhs);
    }

    fn formatTypeMap(self: *Formatter, node: Node) !void {
        const extra_start = node.data.lhs;
        const key_type = self.tree.extra_data.items[extra_start];
        const value_type = self.tree.extra_data.items[extra_start + 1];

        try self.write("map[");
        try self.formatNode(key_type);
        try self.write("]");
        try self.formatNode(value_type);
    }

    fn formatTypeArray(self: *Formatter, node: Node) !void {
        try self.write("[");
        try self.formatNode(node.data.lhs); // size expr
        try self.write("]");
        try self.formatNode(node.data.rhs); // element type
    }

    fn formatTypeTuple(self: *Formatter, node: Node) !void {
        const items_start = node.data.lhs;
        const item_count = node.data.rhs;

        try self.write("(");
        var i: u32 = 0;
        while (i < item_count) : (i += 1) {
            if (i > 0) try self.write(", ");
            try self.formatNode(self.tree.extra_data.items[items_start + i]);
        }
        try self.write(")");
    }

    fn formatTypeAnonStruct(self: *Formatter, node: Node) !void {
        try self.write("struct {");
        const fields_start = node.data.lhs;
        const field_count = node.data.rhs;

        if (field_count > 0) {
            try self.write(" ");
            var i: u32 = 0;
            while (i < field_count) : (i += 1) {
                if (i > 0) try self.write(", ");
                const f_idx = self.tree.extra_data.items[fields_start + i];
                try self.formatNode(f_idx);
            }
            try self.write(" ");
        }
        try self.write("}");
    }

    // --- Assembly ---

    fn formatAsmExpr(self: *Formatter, node: Node) !void {
        try self.write("asm(");
        const extra = self.tree.extra_data.items;
        const start = node.data.lhs;
        const input_count = extra[start];

        // Format inputs
        var i: u32 = 0;
        while (i < input_count) : (i += 1) {
            if (i > 0) try self.write(", ");
            try self.formatNode(extra[start + 1 + i]);
        }

        // Format clobbers
        const clobber_offset = start + 1 + input_count;
        const clobber_count = extra[clobber_offset];
        if (clobber_count > 0) {
            try self.write("; clobber: ");
            var j: u32 = 0;
            while (j < clobber_count) : (j += 1) {
                if (j > 0) try self.write(", ");
                try self.formatNode(extra[clobber_offset + 1 + j]);
            }
        }

        try self.write(")");

        // Format return type
        const ret_type_idx = extra[clobber_offset + 1 + clobber_count];
        if (ret_type_idx != null_node) {
            try self.write(" ");
            try self.formatNode(ret_type_idx);
        }

        try self.write(" ");
        try self.formatNode(node.data.rhs);
    }

    fn formatAsmInput(self: *Formatter, node: Node) !void {
        try self.formatNode(node.data.lhs);
        try self.write(" -> ");
        try self.writeToken(node.main_token);
    }

    fn formatAsmBody(self: *Formatter, node: Node) !void {
        try self.write("{\n");
        self.indent_level += 1;
        const extra = self.tree.extra_data.items;
        const start = node.data.lhs;
        const count = node.data.rhs;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            try self.writeIndent();
            try self.formatNode(extra[start + i]);
            try self.newline();
        }
        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}");
    }

    fn formatAsmSimpleBody(self: *Formatter, node: Node) !void {
        // Emit raw source text for assembly instructions
        const src_start = node.data.lhs;
        const src_end = node.data.rhs;
        if (src_start < src_end and src_end <= self.source.len) {
            const text = std.mem.trim(u8, self.source[src_start..src_end], " \t\n\r");
            try self.write(text);
        }
    }

    fn formatAsmPlatform(self: *Formatter, node: Node) !void {
        try self.write("#");
        // Platform name is the token after hash
        try self.writeToken(node.main_token + 1);
        try self.write(" {\n");
        self.indent_level += 1;
        const src_start = node.data.lhs;
        const src_end = node.data.rhs;
        if (src_start < src_end and src_end <= self.source.len) {
            const text = std.mem.trim(u8, self.source[src_start..src_end], " \t\n\r");
            try self.writeIndent();
            try self.write(text);
            try self.newline();
        }
        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}");
    }

    // --- Utilities ---

    fn write(self: *Formatter, s: []const u8) !void {
        try self.buf.appendSlice(self.allocator, s);
    }

    fn newline(self: *Formatter) !void {
        try self.buf.append(self.allocator, '\n');
    }

    fn writeIndent(self: *Formatter) !void {
        var i: u32 = 0;
        while (i < self.indent_level * indent_width) : (i += 1) {
            try self.buf.append(self.allocator, ' ');
        }
    }

    fn writeToken(self: *Formatter, tok_idx: u32) !void {
        if (tok_idx < self.tokens.len) {
            const tok = self.tokens[tok_idx];
            if (tok.loc.start < tok.loc.end) {
                try self.write(tok.slice(self.source));
            }
        }
    }
};

// Tests

test "format simple var declaration" {
    const source = "package main\nvar x int = 42";
    const result = try formatSource(std.testing.allocator, source);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("package main\n\nvar x int = 42\n", result);
}

test "format function declaration" {
    const source = "package main\npub fun main() {\n    return\n}";
    const result = try formatSource(std.testing.allocator, source);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("package main\n\npub fun main() {\n    return\n}\n", result);
}

test "format let declaration" {
    const source = "package main\nlet x int = 10";
    const result = try formatSource(std.testing.allocator, source);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("package main\n\nlet x int = 10\n", result);
}

test "format binary expression" {
    const source = "package main\nvar x int = 1 + 2";
    const result = try formatSource(std.testing.allocator, source);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("package main\n\nvar x int = 1 + 2\n", result);
}

test "format idempotency" {
    const source = "package main\n\nfun main() {\n    var x int = 42\n    return x\n}\n";
    const result = try formatSource(std.testing.allocator, source);
    defer std.testing.allocator.free(result);

    // Format the result again
    const result2 = try formatSource(std.testing.allocator, result);
    defer std.testing.allocator.free(result2);

    try std.testing.expectEqualStrings(result, result2);
}

test "format struct declaration" {
    const source = "package main\nPoint struct {\nx int\ny int\n}";
    const result = try formatSource(std.testing.allocator, source);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("package main\n\nPoint struct {\n    x int\n    y int\n}\n", result);
}

/// Helper that lexes, parses, and formats source code.
pub fn formatSource(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;

    var lexer = Lexer.init(source);
    var tokens = try lexer.tokenize(allocator);
    defer tokens.deinit(allocator);

    var parser = Parser.init(allocator, tokens.items, source);
    defer parser.deinit();

    _ = try parser.parseFile();

    if (parser.tree.errors.items.len > 0) {
        return error.ParseFailed;
    }

    var formatter = Formatter.init(allocator, &parser.tree, tokens.items, source);
    defer formatter.deinit();

    const result = try formatter.format();

    // Copy to owned slice
    const owned = try allocator.alloc(u8, result.len);
    @memcpy(owned, result);
    return owned;
}
