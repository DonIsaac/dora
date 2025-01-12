const std = @import("std");
const util = @import("util.zig");
const Dora = @import("dora.zig").Dora;
const Allocator = std.mem.Allocator;
const ThreadPool = std.Thread.Pool;

pub fn ParIter(TDora: type, Context: type, comptime ty: util.RW) type {
    return struct {
        pool: *ThreadPool,
        does_own_pool: bool,
        dora: *TDora,
        context: Context,
        const Self = @This();

        pub fn init(dora: *TDora, context: Context, allocator: Allocator) !Self {
            var pool: ThreadPool = undefined;
            try ThreadPool.init(.{
                .allocator = allocator,
                .n_jobs = dora.shard_count,
            });

            return Self{
                .pool = &pool,
                .does_own_pool = true,
                .dora = dora,
                .context = context,
            };
        }

        pub fn run(self: *Self) !void {
            var shards = self.dora.shards[0..self.dora.shard_count];
            _ = &shards;
            for (shards) |*shard| {
                try self.pool.spawn(runOnShard, .{ self.context, shard });
            }
        }
        pub fn deinit(self: *Self) void {
            if (self.does_own_pool) self.pool.deinit();
            self.* = undefined;
        }

        fn runOnShard(context: Context, shard: anytype) void {
            shard.lock(ty);
            defer shard.unlock();

            const bucket = &shard.bucket;
            var iter = bucket.iterator();
            while (iter.next()) |ent| {
                context.next(ent.value_ptr);
            }
        }
    };
}

test ParIter {
    const t = std.testing;
    const Map = @import("dora.zig").AutoDora(u32, u32);

    const Context = struct {
        iter_count: u32 = 0,
        pub fn next(this: *@This(), value: *u32) void {
            _ = value;
            _ = @atomicRmw(u32, &this.iter_count, .Add, 1, .monotonic);
        }
    };

    var map = try Map.init(t.allocator);
    defer map.deinit();

    var pool: std.Thread.Pool = undefined;

    for (0..100) |i| {
        const x: u32 = @intCast(i);
        const existing = try map.put(x, x);
        try t.expectEqual(null, existing);
    }
    try t.expectEqual(100, map.sizeSlow());

    var ctx = Context{};
    {
        try pool.init(.{ .allocator = t.allocator });
        defer pool.deinit();
        var iter = ParIter(Map, *Context, .read){
            .context = &ctx,
            .pool = &pool,
            .does_own_pool = false,
            .dora = &map,
        };
        try iter.run();
    }
    try t.expectEqual(map.sizeSlow(), ctx.iter_count);

    for (0..map.shard_count) |i| {
        const shard = &map.shards[i];
        try t.expectEqual(shard._state, .unlocked);
    }
}
