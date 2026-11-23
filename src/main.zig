const std = @import("std");
const dora = @import("dora.zig");

pub fn main(init: std.process.Init) !void {
    var map = try dora.AutoDora(u32, []const u8).init(init.gpa);
    defer map.deinit();
    try map.insert(1, "one");
}
