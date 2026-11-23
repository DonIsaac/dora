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
        _ = map.put(x % MAX_KEY, x) catch |e| std.debug.panic("put failed: {t}", .{e});
    }
}

test ".put() write contention on the same keys" {
    // #threads \in [1, 4]
    const thread_count: u32 = @min(@max(1, std.Thread.getCpuCount() catch 1), 4);
    // Shard amount must be a power of two greater than 1, so it can't track
    // the thread count.
    var map = try IntMap.initCapacityAndShardAmount(t.allocator, 0, 4);
    defer map.deinit();

    {
        // Writers run on separate threads, or one after another in
        // single-threaded builds.
        var group: std.Io.Group = .init;
        defer group.cancel(t.io);
        for (0..thread_count) |_| {
            group.async(t.io, writeInts, .{&map});
        }
        try group.await(t.io);
    }

    try expectEqual(4, map.sizeSlow());
}
