//! Run Language Compiler
//!
//! A systems programming language with Go's simplicity, generational memory
//! safety, and native performance. Compiler written in Zig.

pub const Token = @import("token.zig").Token;
pub const Lexer = @import("lexer.zig").Lexer;
pub const Ast = @import("ast.zig").Ast;
pub const Node = @import("ast.zig").Node;
pub const NodeIndex = @import("ast.zig").NodeIndex;
pub const Parser = @import("parser.zig").Parser;
pub const naming = @import("naming.zig");
pub const types = @import("types.zig");
pub const symbol = @import("symbol.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const ir = @import("ir.zig");
pub const codegen_c = @import("codegen_c.zig");
pub const resolve = @import("resolve.zig");
pub const typecheck = @import("typecheck.zig");
pub const lower = @import("lower.zig");
pub const ownership = @import("ownership.zig");
pub const driver = @import("driver.zig");
pub const dce = @import("dce.zig");

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
