const std = @import("std");
const util = @import("util.zig");
const Io = std.Io;

pub fn ParIter(TDora: type, Context: type, comptime ty: util.RW) type {
    return struct {
        io: Io,
        dora: *TDora,
        context: Context,
        group: Io.Group = .init,

        const Self = @This();
        const Shard = std.meta.Child(@FieldType(TDora, "shards"));

        pub fn init(dora: *TDora, context: Context, io: Io) Self {
            return Self{
                .io = io,
                .dora = dora,
                .context = context,
            };
        }

        /// Spawn one task per shard. Tasks are not guaranteed to have run
        /// until `wait` or `deinit` returns.
        pub fn run(self: *Self) void {
            const shards = self.dora.shards[0..self.dora.shard_count];
            for (shards) |*shard| {
                self.group.async(self.io, runOnShard, .{ self.context, shard });
            }
        }

        /// Block until every spawned task has finished.
        pub fn wait(self: *Self) Io.Cancelable!void {
            try self.group.await(self.io);
        }

        /// Waits for any outstanding tasks to finish, so every value is
        /// visited even if `wait` was never called.
        pub fn deinit(self: *Self) void {
            self.group.await(self.io) catch |err| switch (err) {
                // Cancellation was requested on the caller. Tasks have still
                // all run by the time `await` returns. `deinit` can't return
                // the error, so re-arm it for the caller's next cancel point.
                error.Canceled => self.io.recancel(),
            };
            self.* = undefined;
        }

        fn runOnShard(context: Context, shard: *Shard) void {
            shard.lock(ty);
            defer shard.unlock(ty);

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
        var iter = ParIter(Map, *Context, .read).init(&map, &ctx, t.io);
        defer iter.deinit();
        iter.run();
        try iter.wait();
    }
    try t.expectEqual(map.sizeSlow(), ctx.iter_count);

    for (0..map.shard_count) |i| {
        const shard = &map.shards[i];
        try t.expectEqual(shard._state, .unlocked);
    }
}
