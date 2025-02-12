const std = @import("std");
const Dora = @import("../dora.zig").Dora;
const AutoDora = @import("../dora.zig").AutoDora;

const t = std.testing;
const expectEqual = t.expectEqual;

const IntMap = Dora(
    u32,
    u32,
    std.hash_map.AutoContext(u32),
    std.hash_map.default_max_load_percentage,
);

test "Dora.put" {
    var map = try IntMap.init(t.allocator);
    defer map.deinit();

    try expectEqual(0, map.sizeSlow());

    // insert 1 -> 2
    var existing: ?u32 = null;
    existing = try map.put(1, 2);
    try expectEqual(null, existing);
    try expectEqual(1, map.sizeSlow());

    // replace 2 with 3
    existing = try map.put(1, 3);
    try expectEqual(2, existing);
    try expectEqual(1, map.sizeSlow());
    try expectEqual(3, map.getCopy(1));
}

test "Dora.parIter" {
    var map = try IntMap.init(t.allocator);
    defer map.deinit();

    // add some stuff
    for (0..100) |i| {
        const x: u32 = @intCast(i);
        try map.insert(x, x);
    }
    try t.expectEqual(100, map.sizeSlow());

    const Context = struct {
        iter_count: u32 = 0,
        pub fn next(this: *@This(), _: *u32) void {
            _ = @atomicRmw(u32, &this.iter_count, .Add, 1, .monotonic);
        }
    };

    var ctx: Context = .{};
    {
        var it = try map.parIter(
            *Context,
            &ctx,
            // create a thread pool instead of using an existing one
            null,
        );
        defer it.deinit();
        try it.run();
    }
    try expectEqual(map.sizeSlow(), ctx.iter_count);
}

