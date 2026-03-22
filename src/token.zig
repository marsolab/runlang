const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: u32,
        end: u32,
    };

    pub const Tag = enum(u8) {
        // Literals
        int_literal,
        float_literal,
        string_literal,
        char_literal,

        // Identifiers
        identifier,

        // Keywords
        kw_fun,
        kw_pub,
        kw_var,
        kw_let,
        kw_return,
        kw_if,
        kw_else,
        kw_for,
        kw_in,
        kw_switch,
        kw_break,
        kw_continue,
        kw_defer,
        kw_run,
        kw_try,
        kw_package,
        kw_import,
        kw_struct,
        kw_interface,
        kw_implements,
        kw_type,
        kw_chan,
        kw_map,
        kw_alloc,
        kw_true,
        kw_false,
        kw_null,
        kw_and,
        kw_or,
        kw_not,
        kw_asm,
        kw_clobber,
        kw_syscall,

        // Operators
        plus, // +
        minus, // -
        star, // *
        slash, // /
        percent, // %
        equal, // =
        colon_equal, // :=
        equal_equal, // ==
        bang_equal, // !=
        less, // <
        greater, // >
        less_equal, // <=
        greater_equal, // >=
        bang, // !
        ampersand, // &
        at, // @
        arrow_left, // <-
        arrow_right, // ->
        dot_dot, // ..
        ellipsis, // ...
        dot, // .
        pipe, // |
        hash, // #
        semicolon, // ;

        // Delimiters
        l_paren, // (
        r_paren, // )
        l_brace, // {
        r_brace, // }
        l_bracket, // [
        r_bracket, // ]
        comma, // ,
        colon, // :
        colon_colon, // ::
        question, // ?

        // Special
        newline,
        eof,
        invalid,

        pub fn isKeyword(tag: Tag) bool {
            return @intFromEnum(tag) >= @intFromEnum(Tag.kw_fun) and
                @intFromEnum(tag) <= @intFromEnum(Tag.kw_syscall);
        }
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "fn", .kw_fun },
        .{ "fun", .kw_fun },
        .{ "pub", .kw_pub },
        .{ "var", .kw_var },
        .{ "let", .kw_let },
        .{ "return", .kw_return },
        .{ "if", .kw_if },
        .{ "else", .kw_else },
        .{ "for", .kw_for },
        .{ "in", .kw_in },
        .{ "switch", .kw_switch },
        .{ "break", .kw_break },
        .{ "continue", .kw_continue },
        .{ "defer", .kw_defer },
        .{ "run", .kw_run },
        .{ "try", .kw_try },
        .{ "package", .kw_package },
        .{ "use", .kw_import },
        .{ "struct", .kw_struct },
        .{ "interface", .kw_interface },
        .{ "implements", .kw_implements },
        .{ "type", .kw_type },
        .{ "chan", .kw_chan },
        .{ "map", .kw_map },
        .{ "alloc", .kw_alloc },
        .{ "true", .kw_true },
        .{ "false", .kw_false },
        .{ "null", .kw_null },
        .{ "and", .kw_and },
        .{ "or", .kw_or },
        .{ "not", .kw_not },
        .{ "asm", .kw_asm },
        .{ "clobber", .kw_clobber },
        .{ "syscall", .kw_syscall },
    });

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.loc.start..self.loc.end];
    }
};
