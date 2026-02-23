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

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
