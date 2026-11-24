const std = @import("std");
const Dora = @import("../dora.zig").Dora;
const AutoDora = @import("../dora.zig").AutoDora;
const defaultStoreHash = @import("../dora.zig").defaultStoreHash;

const t = std.testing;
const expectEqual = t.expectEqual;

const IntMap = Dora(
    u32,
    u32,
    std.hash_map.AutoContext(u32),
    .{ .max_load_percentage = std.hash_map.default_max_load_percentage, .store_hash = false },
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
        var it = map.parIter(*Context, &ctx, t.io);
        defer it.deinit();
        it.run();
        try it.wait();
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

    const Map = Dora(u32, u32, CountingContext, .{ .max_load_percentage = std.hash_map.default_max_load_percentage, .store_hash = false });
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

/// A legal but weak context: keys that agree in their low byte collide.
/// Also counts calls to `hash`.
const WeakContext = struct {
    var hash_calls: usize = 0;

    pub fn hash(_: @This(), key: u32) u64 {
        hash_calls += 1;
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&@as(u8, @truncate(key))));
    }
    pub fn eql(_: @This(), a: u32, b: u32) bool {
        return a == b;
    }
};

fn WeakMap(comptime store_hash: bool) type {
    return Dora(u32, u32, WeakContext, .{ .max_load_percentage = std.hash_map.default_max_load_percentage, .store_hash = store_hash });
}

test "keys with colliding hashes stay distinct" {
    inline for (.{ false, true }) |store_hash| {
        var map = try WeakMap(store_hash).init(t.allocator);
        defer map.deinit();

        // 1, 257 and 513 have the same hash but are different keys.
        try map.insert(1, 10);
        try map.insert(257, 20);
        try expectEqual(null, map.getCopy(513));
        {
            var ref = map.get(257).?;
            defer ref.release();
            try expectEqual(20, ref.value.*);
        }

        try expectEqual(null, try map.put(513, 30));
        try expectEqual(10, try map.put(1, 11));

        try t.expect(map.delete(1));
        try expectEqual(null, map.getCopy(1));
        try expectEqual(20, map.getCopy(257));
        try expectEqual(30, map.getCopy(513));
        try expectEqual(2, map.sizeSlow());
    }
}

test "store_hash = true never rehashes keys when shards grow" {
    const n = 1000;
    inline for (.{ false, true }) |store_hash| {
        var map = try WeakMap(store_hash).initCapacityAndShardAmount(t.allocator, 0, 2);
        defer map.deinit();

        WeakContext.hash_calls = 0;
        for (0..n) |i| try map.insert(@intCast(i), @intCast(i));
        // One hash per insert, plus rehashes when growing without stored hashes.
        if (store_hash) {
            try expectEqual(n, WeakContext.hash_calls);
        } else {
            try t.expect(WeakContext.hash_calls > n);
        }
    }
}

test "slice keys are compared by content" {
    const Map = Dora([]const u8, u32, std.hash_map.StringContext, .{ .max_load_percentage = std.hash_map.default_max_load_percentage, .store_hash = true });
    var map = try Map.init(t.allocator);
    defer map.deinit();

    try map.insert("foo", 1);
    var foo_copy = "foo".*;
    try expectEqual(1, map.getCopy(&foo_copy));
    try expectEqual(null, map.getCopy("bar"));
}

test defaultStoreHash {
    try t.expect(!defaultStoreHash(u64));
    try t.expect(!defaultStoreHash(*const u32));
    try t.expect(defaultStoreHash([]const u8));
    try t.expect(defaultStoreHash(u128));
}
