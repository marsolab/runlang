const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;

test "fuzz lexer tokenization" {
    try std.testing.fuzz(.{}, struct {
        fn testOne(_: @TypeOf(.{}), input: []const u8) anyerror!void {
            var lexer = Lexer.init(input);
            var count: usize = 0;
            while (count < 1_000_000) : (count += 1) {
                const tok = lexer.next();
                if (tok.tag == .eof) break;
            }
        }
    }.testOne, .{
        .corpus = &.{
            "package main\npub fun main() {\n}\n",
            "let x = 42\n",
            "if x > 5 { } else { }\n",
            "\"hello world\"\n",
            "// comment\n",
            "",
            "\x00\xff\n",
            "fun foo(a int, b int) int { return a + b }\n",
            "use \"fmt\"\nuse \"os\"\n",
            "for i < 10 { i = i + 1 }\n",
        },
    });
}
