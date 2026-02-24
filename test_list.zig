const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var list = std.ArrayList(u32).init(allocator);
    defer list.deinit();
    try list.append(42);
    std.debug.print("Value: {d}\n", .{list.items[0]});
}
