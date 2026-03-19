const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;

test "fuzz parser" {
    try std.testing.fuzz(.{}, struct {
        fn testOne(_: @TypeOf(.{}), input: []const u8) anyerror!void {
            const allocator = std.testing.allocator;

            var lexer = Lexer.init(input);
            var tokens = lexer.tokenize(allocator) catch return;
            defer tokens.deinit(allocator);

            var parser = Parser.init(allocator, tokens.items, input);
            defer parser.deinit();

            _ = parser.parseFile() catch return;
        }
    }.testOne, .{
        .corpus = &.{
            "package main\npub fun main() {\n}\n",
            "package main\nuse \"fmt\"\npub fun main() {\n    fmt.println(\"hello\")\n}\n",
            "package main\nlet x = 42\npub fun main() {\n    if x > 5 {\n    }\n}\n",
            "package main\nfun add(a int, b int) int {\n    return a + b\n}\npub fun main() {\n}\n",
            "",
            "type Foo struct {\n    x int\n    y int\n}\n",
        },
    });
}
