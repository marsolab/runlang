const std = @import("std");
const Token = @import("token.zig").Token;
const Tag = Token.Tag;

pub const Lexer = struct {
    source: []const u8,
    pos: u32,
    line: u32,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
        };
    }

    pub fn next(self: *Lexer) Token {
        // Skip whitespace (but not newlines)
        self.skipWhitespace();

        if (self.isAtEnd()) {
            return self.makeToken(.eof);
        }

        const c = self.peek();

        // Skip comments
        if (c == '/' and self.peekNext() == '/') {
            self.skipLineComment();
            return self.next();
        }

        // Newline
        if (c == '\n') {
            self.line += 1;
            return self.advance1(.newline);
        }
        if (c == '\r') {
            _ = self.advance();
            if (!self.isAtEnd() and self.peek() == '\n') {
                self.line += 1;
                return self.advance1(.newline);
            }
            return self.next();
        }

        // String literal
        if (c == '"') return self.readString();

        // Char literal
        if (c == '\'') return self.readChar();

        // Number literal
        if (isDigit(c)) return self.readNumber();

        // Identifier or keyword
        if (isAlpha(c) or c == '_') return self.readIdentifier();

        // Operators and delimiters
        return self.readOperator();
    }

    pub fn tokenize(self: *Lexer, allocator: std.mem.Allocator) !std.ArrayList(Token) {
        var tokens: std.ArrayList(Token) = .empty;
        while (true) {
            const tok = self.next();
            try tokens.append(allocator, tok);
            if (tok.tag == .eof) break;
        }
        return tokens;
    }

    // --- Private helpers ---

    fn peek(self: *const Lexer) u8 {
        return self.source[self.pos];
    }

    fn peekNext(self: *const Lexer) ?u8 {
        if (self.pos + 1 >= self.source.len) return null;
        return self.source[self.pos + 1];
    }

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.pos];
        self.pos += 1;
        return c;
    }

    fn advance1(self: *Lexer, tag: Tag) Token {
        const start = self.pos;
        self.pos += 1;
        return .{ .tag = tag, .loc = .{ .start = start, .end = self.pos } };
    }

    fn advance2(self: *Lexer, tag: Tag) Token {
        const start = self.pos;
        self.pos += 2;
        return .{ .tag = tag, .loc = .{ .start = start, .end = self.pos } };
    }

    fn isAtEnd(self: *const Lexer) bool {
        return self.pos >= self.source.len;
    }

    fn makeToken(self: *const Lexer, tag: Tag) Token {
        return .{ .tag = tag, .loc = .{ .start = self.pos, .end = self.pos } };
    }

    fn skipWhitespace(self: *Lexer) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == ' ' or c == '\t') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn skipLineComment(self: *Lexer) void {
        while (!self.isAtEnd() and self.peek() != '\n') {
            self.pos += 1;
        }
    }

    fn readString(self: *Lexer) Token {
        const start = self.pos;
        self.pos += 1; // skip opening "
        while (!self.isAtEnd() and self.peek() != '"') {
            if (self.peek() == '\\') self.pos += 1; // skip escape
            if (!self.isAtEnd()) self.pos += 1;
        }
        if (!self.isAtEnd()) self.pos += 1; // skip closing "
        return .{ .tag = .string_literal, .loc = .{ .start = start, .end = self.pos } };
    }

    fn readChar(self: *Lexer) Token {
        const start = self.pos;
        self.pos += 1; // skip opening '
        if (!self.isAtEnd() and self.peek() == '\\') self.pos += 1;
        if (!self.isAtEnd()) self.pos += 1;
        if (!self.isAtEnd() and self.peek() == '\'') self.pos += 1;
        return .{ .tag = .char_literal, .loc = .{ .start = start, .end = self.pos } };
    }

    fn readNumber(self: *Lexer) Token {
        const start = self.pos;
        var is_float = false;

        // Handle hex, octal, binary prefixes
        if (self.peek() == '0' and self.peekNext() != null) {
            const next_ch = self.peekNext().?;
            if (next_ch == 'x' or next_ch == 'X' or
                next_ch == 'o' or next_ch == 'O' or
                next_ch == 'b' or next_ch == 'B')
            {
                self.pos += 2;
                while (!self.isAtEnd() and (isHexDigit(self.peek()) or self.peek() == '_')) {
                    self.pos += 1;
                }
                return .{ .tag = .int_literal, .loc = .{ .start = start, .end = self.pos } };
            }
        }

        while (!self.isAtEnd() and (isDigit(self.peek()) or self.peek() == '_')) {
            self.pos += 1;
        }

        // Check for decimal point
        if (!self.isAtEnd() and self.peek() == '.' and
            self.peekNext() != null and isDigit(self.peekNext().?))
        {
            is_float = true;
            self.pos += 1; // skip .
            while (!self.isAtEnd() and (isDigit(self.peek()) or self.peek() == '_')) {
                self.pos += 1;
            }
        }

        // Check for exponent
        if (!self.isAtEnd() and (self.peek() == 'e' or self.peek() == 'E')) {
            is_float = true;
            self.pos += 1;
            if (!self.isAtEnd() and (self.peek() == '+' or self.peek() == '-')) {
                self.pos += 1;
            }
            while (!self.isAtEnd() and isDigit(self.peek())) {
                self.pos += 1;
            }
        }

        const tag: Tag = if (is_float) .float_literal else .int_literal;
        return .{ .tag = tag, .loc = .{ .start = start, .end = self.pos } };
    }

    fn readIdentifier(self: *Lexer) Token {
        const start = self.pos;
        while (!self.isAtEnd() and (isAlpha(self.peek()) or isDigit(self.peek()) or self.peek() == '_')) {
            self.pos += 1;
        }
        const text = self.source[start..self.pos];
        const tag = Token.getKeyword(text) orelse Tag.identifier;
        return .{ .tag = tag, .loc = .{ .start = start, .end = self.pos } };
    }

    fn readOperator(self: *Lexer) Token {
        const c = self.peek();
        return switch (c) {
            '+' => self.advance1(.plus),
            '-' => self.advance1(.minus),
            '*' => self.advance1(.star),
            '/' => self.advance1(.slash),
            '%' => self.advance1(.percent),
            '&' => self.advance1(.ampersand),
            '@' => self.advance1(.at),
            '(' => self.advance1(.l_paren),
            ')' => self.advance1(.r_paren),
            '{' => self.advance1(.l_brace),
            '}' => self.advance1(.r_brace),
            '[' => self.advance1(.l_bracket),
            ']' => self.advance1(.r_bracket),
            ',' => self.advance1(.comma),
            '?' => self.advance1(.question),
            '|' => self.advance1(.pipe),
            ':' => blk: {
                if (self.peekNext() == @as(u8, '='))
                    break :blk self.advance2(.colon_equal);
                if (self.peekNext() == @as(u8, ':'))
                    break :blk self.advance2(.colon_colon);
                break :blk self.advance1(.colon);
            },
            '=' => blk: {
                if (self.peekNext() == @as(u8, '='))
                    break :blk self.advance2(.equal_equal);
                if (self.peekNext() == @as(u8, '>'))
                    break :blk self.advance2(.fat_arrow);
                break :blk self.advance1(.equal);
            },
            '!' => blk: {
                if (self.peekNext() == @as(u8, '='))
                    break :blk self.advance2(.bang_equal);
                break :blk self.advance1(.bang);
            },
            '<' => blk: {
                if (self.peekNext() == @as(u8, '='))
                    break :blk self.advance2(.less_equal);
                if (self.peekNext() == @as(u8, '-'))
                    break :blk self.advance2(.arrow_left);
                break :blk self.advance1(.less);
            },
            '>' => blk: {
                if (self.peekNext() == @as(u8, '='))
                    break :blk self.advance2(.greater_equal);
                break :blk self.advance1(.greater);
            },
            '.' => blk: {
                if (self.peekNext() == @as(u8, '.'))
                    break :blk self.advance2(.dot_dot);
                break :blk self.advance1(.dot);
            },
            else => self.advance1(.invalid),
        };
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isHexDigit(c: u8) bool {
        return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }
};

// --- Tests ---

test "lex simple variable declaration" {
    var lexer = Lexer.init("x := 42");
    const t1 = lexer.next();
    try std.testing.expectEqual(Tag.identifier, t1.tag);
    try std.testing.expectEqualStrings("x", t1.slice("x := 42"));

    const t2 = lexer.next();
    try std.testing.expectEqual(Tag.colon_equal, t2.tag);

    const t3 = lexer.next();
    try std.testing.expectEqual(Tag.int_literal, t3.tag);

    const t4 = lexer.next();
    try std.testing.expectEqual(Tag.eof, t4.tag);
}

test "lex keywords" {
    var lexer = Lexer.init("fn pub var let return struct");
    try std.testing.expectEqual(Tag.kw_fn, lexer.next().tag);
    try std.testing.expectEqual(Tag.kw_pub, lexer.next().tag);
    try std.testing.expectEqual(Tag.kw_var, lexer.next().tag);
    try std.testing.expectEqual(Tag.kw_let, lexer.next().tag);
    try std.testing.expectEqual(Tag.kw_return, lexer.next().tag);
    try std.testing.expectEqual(Tag.kw_struct, lexer.next().tag);
    try std.testing.expectEqual(Tag.eof, lexer.next().tag);
}

test "lex function definition" {
    var lexer = Lexer.init("pub fn add(a: int, b: int) int {\n    return a + b\n}");
    try std.testing.expectEqual(Tag.kw_pub, lexer.next().tag);
    try std.testing.expectEqual(Tag.kw_fn, lexer.next().tag);
    try std.testing.expectEqual(Tag.identifier, lexer.next().tag); // add
    try std.testing.expectEqual(Tag.l_paren, lexer.next().tag);
    try std.testing.expectEqual(Tag.identifier, lexer.next().tag); // a
    try std.testing.expectEqual(Tag.colon, lexer.next().tag);
    try std.testing.expectEqual(Tag.identifier, lexer.next().tag); // int
    try std.testing.expectEqual(Tag.comma, lexer.next().tag);
    try std.testing.expectEqual(Tag.identifier, lexer.next().tag); // b
    try std.testing.expectEqual(Tag.colon, lexer.next().tag);
    try std.testing.expectEqual(Tag.identifier, lexer.next().tag); // int
    try std.testing.expectEqual(Tag.r_paren, lexer.next().tag);
    try std.testing.expectEqual(Tag.identifier, lexer.next().tag); // int (return type)
    try std.testing.expectEqual(Tag.l_brace, lexer.next().tag);
    try std.testing.expectEqual(Tag.newline, lexer.next().tag);
    try std.testing.expectEqual(Tag.kw_return, lexer.next().tag);
    try std.testing.expectEqual(Tag.identifier, lexer.next().tag); // a
    try std.testing.expectEqual(Tag.plus, lexer.next().tag);
    try std.testing.expectEqual(Tag.identifier, lexer.next().tag); // b
    try std.testing.expectEqual(Tag.newline, lexer.next().tag);
    try std.testing.expectEqual(Tag.r_brace, lexer.next().tag);
    try std.testing.expectEqual(Tag.eof, lexer.next().tag);
}

test "lex string and float" {
    var lexer = Lexer.init("\"hello world\" 3.14");
    try std.testing.expectEqual(Tag.string_literal, lexer.next().tag);
    try std.testing.expectEqual(Tag.float_literal, lexer.next().tag);
    try std.testing.expectEqual(Tag.eof, lexer.next().tag);
}

test "lex operators" {
    var lexer = Lexer.init(":= == != <= >= <- => .. ::");
    try std.testing.expectEqual(Tag.colon_equal, lexer.next().tag);
    try std.testing.expectEqual(Tag.equal_equal, lexer.next().tag);
    try std.testing.expectEqual(Tag.bang_equal, lexer.next().tag);
    try std.testing.expectEqual(Tag.less_equal, lexer.next().tag);
    try std.testing.expectEqual(Tag.greater_equal, lexer.next().tag);
    try std.testing.expectEqual(Tag.arrow_left, lexer.next().tag);
    try std.testing.expectEqual(Tag.fat_arrow, lexer.next().tag);
    try std.testing.expectEqual(Tag.dot_dot, lexer.next().tag);
    try std.testing.expectEqual(Tag.colon_colon, lexer.next().tag);
    try std.testing.expectEqual(Tag.eof, lexer.next().tag);
}

test "lex colon vs colon_colon" {
    var lexer = Lexer.init(": :: :");
    try std.testing.expectEqual(Tag.colon, lexer.next().tag);
    try std.testing.expectEqual(Tag.colon_colon, lexer.next().tag);
    try std.testing.expectEqual(Tag.colon, lexer.next().tag);
    try std.testing.expectEqual(Tag.eof, lexer.next().tag);
}

test "lex skips comments" {
    var lexer = Lexer.init("x // this is a comment\ny");
    try std.testing.expectEqual(Tag.identifier, lexer.next().tag);
    try std.testing.expectEqual(Tag.newline, lexer.next().tag);
    try std.testing.expectEqual(Tag.identifier, lexer.next().tag);
    try std.testing.expectEqual(Tag.eof, lexer.next().tag);
}
