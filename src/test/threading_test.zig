const std = @import("std");
const Dora = @import("../dora.zig").Dora;
const AutoDora = @import("../dora.zig").AutoDora;

const t = std.testing;
const expectEqual = t.expectEqual;

const IntMap = AutoDora(u32, u32);

const MAX_KEY = 4;
fn writeInts(map: *IntMap) void {
    for (0..1000) |i| {
        const x: u32 = @intCast(i);
        _ = map.put(x % MAX_KEY, x) catch |e| std.debug.panic("put failed: {}", .{e});
    }
}

test ".put() write contention on the same keys" {
    // #threads \in [1, 4]
    const thread_count: u32 = @min(@max(1, std.Thread.getCpuCount() catch 1), 4);
    var map = try IntMap.initCapacityAndShardAmount(t.allocator, 0, thread_count);
    defer map.deinit();

    {
        var pool: std.Thread.Pool = undefined;
        try pool.init(.{ .allocator = t.allocator, .n_jobs = thread_count });
        defer pool.deinit();

        for (0..thread_count) |_| {
            try pool.spawn(writeInts, .{&map});
        }
    }

    try expectEqual(4, map.sizeSlow());
}
