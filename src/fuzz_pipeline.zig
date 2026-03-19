const std = @import("std");
const driver = @import("driver.zig");

test "fuzz full pipeline (check mode)" {
    try std.testing.fuzz(.{}, struct {
        fn testOne(_: @TypeOf(.{}), input: []const u8) anyerror!void {
            const allocator = std.testing.allocator;

            const tmp_path = "/tmp/run_fuzz_input.run";
            {
                const f = std.fs.cwd().createFile(tmp_path, .{}) catch return;
                defer f.close();
                f.writeAll(input) catch return;
            }
            defer std.fs.cwd().deleteFile(tmp_path) catch {};

            // Run check mode only — must not crash regardless of input.
            driver.compile(allocator, .{
                .input_path = tmp_path,
                .command = .check,
                .no_color = true,
            }) catch {
                return;
            };
        }
    }.testOne, .{
        .corpus = &.{
            "package main\npub fun main() {\n}\n",
            "package main\nuse \"fmt\"\npub fun main() {\n    fmt.println(\"hello\")\n}\n",
        },
    });
}
