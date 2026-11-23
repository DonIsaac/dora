const std = @import("std");
const dora = @import("dora.zig");

var debug_alloc = std.heap.GeneralPurposeAllocator(.{}){};
pub fn main() !void {
    const allocator = debug_alloc.allocator();
    defer if (debug_alloc.deinit() == .leak) {
        std.debug.print("Memory leak detected\n", .{});
    };
    var map = try dora.AutoDora(u32, []const u8).init(allocator);
    defer map.deinit();
    try map.insert(1, "one");
}
