const std = @import("std");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const ThreadPool = std.Thread.Pool;
const WaitGroup = std.Thread.WaitGroup;

pub fn ParIter(TDora: type, Context: type, comptime ty: util.RW) type {
    return struct {
        pool: *ThreadPool,
        does_own_pool: bool,
        dora: *TDora,
        context: Context,
        wait_group: WaitGroup = .{},

        const Self = @This();

        pub fn init(dora: *TDora, context: Context, allocator: Allocator) !Self {
            const pool = try allocator.create(ThreadPool);
            errdefer allocator.destroy(pool);
            try ThreadPool.init(pool, .{
                .allocator = allocator,
                .n_jobs = dora.shard_count,
            });

            return Self{
                .pool = pool,
                .does_own_pool = true,
                .dora = dora,
                .context = context,
            };
        }

        pub fn run(self: *Self) !void {
            var shards = self.dora.shards[0..self.dora.shard_count];
            _ = &shards;
            for (shards) |*shard| {
                self.pool.spawnWg(&self.wait_group, runOnShard, .{ self.context, shard });
                // self.pool.spawn(&self.wait_group, runOnShard, .{ self.context, shard });
            }
        }

        pub fn deinit(self: *Self) void {
            // No point in waiting if we own the pool; joining the threads will
            // do that for us.
            self.wait_group.wait();
            if (self.does_own_pool) {
                const allocator = self.pool.allocator;
                self.pool.deinit();
                allocator.destroy(self.pool);
            }
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

    for (0..100) |i| {
        const x: u32 = @intCast(i);
        const existing = try map.put(x, x);
        try t.expectEqual(null, existing);
    }
    try t.expectEqual(100, map.sizeSlow());

    var ctx = Context{};
    {
        // SAFETY: init sets a value here
        var pool: std.Thread.Pool = undefined;
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
