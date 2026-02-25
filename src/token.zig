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
        kw_fn,
        kw_pub,
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
        kw_import,
        kw_struct,
        kw_trait,
        kw_impl,
        kw_type,
        kw_chan,
        kw_unsafe,
        kw_true,
        kw_false,
        kw_null,
        kw_and,
        kw_or,
        kw_not,

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
        dot_dot, // ..
        dot, // .
        pipe, // |

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
        fat_arrow, // =>

        // Special
        newline,
        eof,
        invalid,

        pub fn isKeyword(tag: Tag) bool {
            return @intFromEnum(tag) >= @intFromEnum(Tag.kw_fn) and
                @intFromEnum(tag) <= @intFromEnum(Tag.kw_not);
        }
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "fn", .kw_fn },
        .{ "pub", .kw_pub },
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
        .{ "import", .kw_import },
        .{ "struct", .kw_struct },
        .{ "trait", .kw_trait },
        .{ "impl", .kw_impl },
        .{ "type", .kw_type },
        .{ "chan", .kw_chan },
        .{ "unsafe", .kw_unsafe },
        .{ "true", .kw_true },
        .{ "false", .kw_false },
        .{ "null", .kw_null },
        .{ "and", .kw_and },
        .{ "or", .kw_or },
        .{ "not", .kw_not },
    });

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.loc.start..self.loc.end];
    }
};
