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

test "Dora.entry" {
    var map = try IntMap.init(t.allocator);
    defer map.deinit();

    try expectEqual(null, map.entry(1));
    _ = try map.put(1, 2);

    {
        var ent = map.entry(1).?;
        defer ent.release();
        try expectEqual(1, ent.key);
        try expectEqual(2, ent.value.*);
        ent.value.* = 3;
    }

    // The shard was released, so these do not deadlock.
    try expectEqual(3, map.getCopy(1));
    try expectEqual(3, try map.put(1, 4));
    try expectEqual(4, map.getCopy(1));
}

test "Context.deinit is called for removed and remaining values" {
    const CountingContext = struct {
        var deinit_count: u32 = 0;

        pub fn hash(_: @This(), key: u32) u64 {
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
        }
        pub fn eql(_: @This(), a: u32, b: u32) bool {
            return a == b;
        }
        pub fn deinit(_: @This(), value: u32) void {
            _ = value;
            deinit_count += 1;
        }
    };
    CountingContext.deinit_count = 0;

    const Map = Dora(u32, u32, CountingContext, std.hash_map.default_max_load_percentage);
    {
        var map = try Map.init(t.allocator);
        defer map.deinit();

        for (0..10) |i| try map.insert(@intCast(i), @intCast(i));
        try t.expect(map.delete(3));
        try t.expect(!map.delete(3));
        try expectEqual(1, CountingContext.deinit_count);
    }
    // deinit() cleans up the 9 remaining values
    try expectEqual(10, CountingContext.deinit_count);
}
