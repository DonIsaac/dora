pub fn AutoDora(
    comptime K: type,
    comptime V: type,
) type {
    return Dora(K, V, std.hash_map.AutoContext(K), std.hash_map.default_max_load_percentage);
}

/// ## Contexts
/// Context has the following interface:
/// ```zig
/// const Context = struct {
///    pub fn hash(self: @This(), key: K) u64;
///    pub fn eql(self: @This(), a: K, b: K) bool;
///    // optional. For heap-allocated values.
///    pub fn deinit(self: @This(), value: V) void;
/// };
/// ```
pub fn Dora(
    /// Key type. Will not be freed when entries are removed, so it should not
    /// own any allocations. It should also be relatively small, since it will
    /// be copied frequently.
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime max_load_percentage: u64,
) type {
    if (!@hasDecl(Context, "hash") or !@hasDecl(Context, "eql")) {
        @compileError("Context must have hash and eql functions");
    }
    if (@hasDecl(Context, "deinit")) {
        switch (@typeInfo(Context.deinit)) {
            .Fn => |signature| if (signature.params.len != 2) {
                @compileError("Context.deinit must match signature `fn (self: @This(), value: V) void, found " ++ @typeName(@TypeOf(Context.deinit)));
            },
            else => @compileError("Context.deinit must be a function"),
        }
    }

    return struct {
        // not using slice to save a word
        shards: [*]align(cache_line) Shard,
        shard_count: u32,
        shift: u6,
        allocator: Allocator,

        const Self = @This();
        const Hash = u64;
        // our wrappers compute key hashes themselves. we just forward hashes to the
        // underlying map
        const Bucket = std.HashMapUnmanaged(Hash, V, IdentityContext, max_load_percentage);
        const Shard = struct {
            bucket: Bucket = .{},
            _lock: RwLock = .{},
            _state: DebugState = if (is_safe) .unlocked else {},
            const is_safe = std.debug.runtime_safety;

            const DebugState = if (!is_safe) void else union(enum) {
                unlocked: void,
                locked: struct { state: util.RW, owner: u64 },
            };

            pub inline fn lock(self: *Shard, comptime ty: util.RW) void {
                if (comptime ty == .write) {
                    self._lock.lock();
                } else {
                    self._lock.lockShared();
                }
                if (is_safe) {
                    assert(self._state == .unlocked);
                    self._state = .{
                        .locked = .{ .owner = std.Thread.getCurrentId(), .state = ty },
                    };
                }
            }

            pub inline fn unlock(self: *@This()) void {
                self._lock.unlock();
                if (is_safe) {
                    assert(self._state == .locked);
                    assert(self._state.locked.owner == std.Thread.getCurrentId());
                    self._state = .unlocked;
                }
            }

            inline fn assertCurrentThreadWritable(self: *Shard) void {
                if (is_safe) {
                    assert(self._state == .locked);
                    assert(self._state.locked.state == .write);
                    assert(self._state.locked.owner == std.Thread.getCurrentId());
                }
            }

            inline fn assertCurrentThreadReadable(self: *Shard) void {
                if (is_safe) {
                    assert(self._state == .locked);
                    assert(self._state.locked.state == .read);
                    assert(self._state.locked.owner == std.Thread.getCurrentId());
                }
            }
        };

        pub fn init(allocator: Allocator) Allocator.Error!Self {
            return initCapacity(allocator, 0);
        }

        pub fn initCapacity(allocator: Allocator, capacity: usize) Allocator.Error!Self {
            return initCapacityAndShardAmount(allocator, capacity, defaultShardAmount());
        }

        pub fn initCapacityAndShardAmount(
            allocator: Allocator,
            capacity: usize,
            shard_amount: u32,
        ) Allocator.Error!Self {
            assert(shard_amount > 1);
            assert(util.isPowerOfTwo(shard_amount));

            const shift = @as(u32, util.ptrSizeBits) - @ctz(shard_amount);

            const actual_capacity = if (capacity != 0)
                (capacity + (shard_amount - 1)) & ~(shard_amount - 1)
            else
                capacity;

            const cps: u32 = @intCast(actual_capacity / shard_amount);

            var shards = try allocator.alignedAlloc(Shard, cache_line, shard_amount);
            errdefer allocator.free(shards);

            for (0..shard_amount) |i| {
                shards[i] = .{};
                var shard = &shards[i];
                try shard.bucket.ensureTotalCapacity(allocator, cps);
            }

            return Self{
                .shards = @ptrCast(shards),
                .shard_count = shard_amount,
                .shift = @intCast(shift),
                .allocator = allocator,
            };
        }

        pub fn get(self: *Self, key: K) ?Ref {
            const hash, var shard = self.lock(key, .read);
            if (shard.bucket.getPtr(hash)) |value| {
                return Ref{ .value = value, .shard = shard };
            } else {
                shard.unlock();
                return null;
            }
        }

        pub fn getCopy(self: *Self, key: K) ?V {
            const hash, var shard = self.lock(key, .read);
            defer shard.unlock();
            return shard.bucket.get(hash);
        }

        pub fn entry(self: *Self, key: K) ?Bucket.Entry {
            const hash, var shard = self.lock(key, .write);
            return shard.bucket.getEntry(hash) orelse empty: {
                shard.unlock();
                break :empty null;
            };
        }

        pub fn sizeSlow(self: *Self) usize {
            var size: usize = 0;
            for (self.getShards()) |*shard| {
                shard.lock(.read);
                defer shard.unlock();
                size += shard.bucket.size;
            }
            return size;
        }

        /// add a new entry. Asserts no entry exists under `key`.
        pub fn insert(self: *Self, key: K, value: V) Allocator.Error!void {
            const hash, var shard = self.lock(key, .write);
            shard.assertCurrentThreadWritable();
            // assert(shard.)
            defer shard.unlock();
            try shard.bucket.putNoClobber(self.allocator, hash, value);
        }

        pub fn put(self: *Self, key: K, value: V) Allocator.Error!?V {
            const hash, var shard = self.lock(key, .write);
            defer shard.unlock();
            const old: ?V = if (shard.bucket.get(hash)) |v| v else null;
            try shard.bucket.put(self.allocator, hash, value);
            return old;
        }

        pub fn delete(self: *Self, key: K) bool {
            const hash, var shard = self.lock(key, .write);
            defer shard.unlock();
            const ent = shard.bucket.getEntry(hash) orelse return false;
            deinitValue(ent.value_ptr);

            shard.bucket.removeByPtr(ent.key_ptr);
            return true;
        }

        inline fn deinitValue(value: *V) void {
            if (comptime @hasDecl(Context, "deinit")) {
                Context.deinit(value);
            }
        }

        pub fn deinit(self: *Self) void {
            const c = self.shard_count;
            var shards = self.shards[0..c];
            _ = &shards;
            for (shards) |*shard| {
                shard.lock(.write);
                if (@hasDecl(Context, "deinit")) {
                    var iter = shard.bucket.valueIterator();
                    while (iter.next()) |value| {
                        Context.deinit(value);
                    }
                }
                shard.bucket.deinit(self.allocator);
            }
            self.allocator.free(shards);
        }

        /// Hash a key and lock the related shard for read-only access.
        /// You must unlock the shard after you are done with it.
        fn lock(self: *Self, key: K, comptime ty: util.RW) struct { Hash, *Shard } {
            const hash = Context.hash(undefined, key);
            if (@TypeOf(hash) != Hash) {
                @compileError("Context " ++ @typeName(Context) ++ " has a generic hash function that returns the wrong type! " ++ @typeName(Hash) ++ " was expected, but found " ++ @typeName(@TypeOf(hash)));
            }
            const shard_idx = self.determineShard(hash);
            var shard = &self.shards[shard_idx];
            shard.lock(ty);
            return .{ hash, shard };
        }

        fn determineShard(self: *const Self, hash: Hash) usize {
            // Leave the high 7 bits for the HashBrown SIMD tag.
            return (hash << 7) >> self.shift;
        }

        inline fn getShards(self: *Self) []Shard {
            return self.shards[0..self.shard_count];
        }

        const Ref = struct {
            value: *const V,
            shard: *Shard,
            pub fn release(self: *Ref) void {
                self.shard.unlock();
            }
        };

        const RefMut = struct {
            value: *V,
            shard: *Shard,
            pub fn release(self: *RefMut) void {
                self.shard.unlock();
            }
        };

        const Entry = struct {
            key: *const K,
            value: *const V,
            shard: *Shard,
            pub fn release(self: *Entry) void {
                self.shard.unlock();
            }
        };

        const EntryMut = struct {
            key: *const K,
            value: *V,
            lock: *RwLock,
            pub fn release(self: *EntryMut) void {
                self.lock.unlock();
            }
        };
    };
}

const IdentityContext = struct {
    pub fn hash(_: IdentityContext, key: u64) u64 {
        return key;
    }
    pub fn eql(_: IdentityContext, a: u64, b: u64) bool {
        return a == b;
    }
};

fn defaultShardAmount() u32 {
    const Static = struct {
        const b = @import("builtin");
        fn doCalculateDefaultShardAmount() void {
            const nthreads = if (b.single_threaded)
                1
            else
                std.Thread.getCpuCount() catch 1;
            amount = util.nextPowerOfTwo(u32, @truncate(nthreads * 4));
        }
        var amount: u32 = 0;
        var calculateDefaultShardAmount = std.once(doCalculateDefaultShardAmount);
    };

    Static.calculateDefaultShardAmount.call();
    std.debug.assert(Static.amount > 0);
    return Static.amount;
}

const std = @import("std");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const RwLock = std.Thread.RwLock;

const assert = std.debug.assert;
const cache_line = std.atomic.cache_line;

const t = std.testing;
const expectEqual = t.expectEqual;

test {
    t.refAllDecls(AutoDora(u32, u32));
}

test Dora {
    const Map = Dora(
        u32,
        u32,
        std.hash_map.AutoContext(u32),
        std.hash_map.default_max_load_percentage,
    );

    var map = try Map.initCapacity(t.allocator, 16);
    defer map.deinit();

    try expectEqual(null, map.get(1));
    try map.insert(1, 2);
    try expectEqual(1, map.sizeSlow());
    {
        var ref = map.get(1).?;
        defer ref.release();
        try expectEqual(2, ref.value.*);
    }
    try expectEqual(2, map.getCopy(1));
}
