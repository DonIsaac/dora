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
        shift: u32,
        allocator: Allocator,

        const Self = @This();
        const Hash = u64;
        // our wrappers compute key hashes themselves. we just forward hashes to the
        // underlying map
        const Bucket = std.HashMapUnmanaged(Hash, V, IdentityContext, max_load_percentage);
        const Shard = struct {
            bucket: Bucket = .{},
            lock: RwLock = .{},
            inline fn unlock(self: *@This()) void {
                self.lock.unlock();
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
            assert(util.num.isPowerOfTwo(shard_amount));

            const shift = @as(u32, util.num.ptrSizeBits) - @ctz(shard_amount);
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
                .shift = shift,
                .allocator = allocator,
            };
        }

        pub fn entry(self: *Self, key: K) ?Bucket.Entry {
            const hash, var shard = self.lockMut(key);
            return shard.bucket.getEntry(hash) orelse empty: {
                shard.unlock();
                break :empty null;
            };
        }

        /// add a new entry. Asserts no entry exists under `key`.
        pub fn insert(self: *Self, key: K, value: V) Allocator.Error!void {
            const hash, var shard = self.lockMut(key);
            defer shard.unlock();
            try shard.bucket.putNoClobber(self.allocator, hash, value);
        }

        pub fn delete(self: *Self, key: K) bool {
            const hash, var shard = self.lockMut(key);
            defer shard.lock.unlock();
            const ent = shard.bucket.getEntry(hash) orelse return false;
            if (@hasDecl(Context, "deinit")) {
                Context.deinit(ent.value);
            }
            shard.bucket.removeByPtr(ent.key_ptr);
            return true;
        }

        /// Hash a key and lock the related shard for read-only access.
        /// You must unlock the shard after you are done with it.
        fn lock(self: *Self, key: K) struct { Hash, *Shard } {
            const hash = Context.hash(key);
            if (@TypeOf(hash) != Hash) {
                @compileError("Context " ++ @typeName(Context) ++ " has a generic hash function that returns the wrong type! " ++ @typeName(Hash) ++ " was expected, but found " ++ @typeName(@TypeOf(hash)));
            }
            const shard_idx = self.determineShard(hash);
            var shard = &self.shards[shard_idx];
            shard.lock.lockShared();
            return .{ hash, shard };
        }

        /// Hash a key and lock the related shard for read-write access.
        /// You must unlock the shard after you are done with it.
        fn lockMut(self: *Self, key: K) struct { Hash, *Shard } {
            const hash = Context.hash(key);
            if (@TypeOf(hash) != Hash) {
                @compileError("Context " ++ @typeName(Context) ++ " has a generic hash function that returns the wrong type! " ++ @typeName(Hash) ++ " was expected, but found " ++ @typeName(@TypeOf(hash)));
            }
            const shard_idx = self.determineShard(hash);
            var shard = &self.shards[shard_idx];
            shard.lock.lock();
            return .{ hash, shard };
        }

        fn determineShard(self: *const Self, hash: Hash) usize {
            // Leave the high 7 bits for the HashBrown SIMD tag.
            return (hash << 7) >> self.shift;
        }

        pub fn deinit(self: *Self) void {
            const c = self.shard_count;
            var shards = self.shards[0..c];
            _ = &shards;
            for (shards) |*shard| {
                shard.lock.lock();
                shard.bucket.deinit(self.allocator);
            }
            self.allocator.free(shards);
        }

        const Ref = struct {
            value: *const V,
            lock: *RwLock,
            pub fn release(self: *Ref) void {
                self.lock.unlock();
            }
        };

        const RefMut = struct {
            value: *V,
            lock: *RwLock,
            pub fn release(self: *RefMut) void {
                self.lock.unlock();
            }
        };

        const Entry = struct {
            key: *const K,
            value: *const V,
            lock: *RwLock,
            pub fn release(self: *Entry) void {
                self.lock.unlock();
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
        fn doCalculateDefaultShardAmount() void {
            const nthreads = std.Thread.getCpuCount() catch 1;
            amount = util.num.nextPowerOfTwo(u32, @truncate(nthreads * 4));
        }
        var amount: u32 = 0;
        var calculateDefaultShardAmount = std.once(doCalculateDefaultShardAmount);
    };

    Static.calculateDefaultShardAmount.call();
    std.debug.assert(Static.amount > 0);
    return Static.amount;
}

const std = @import("std");
const util = @import("util");

const Allocator = std.mem.Allocator;
const RwLock = std.Thread.RwLock;

const assert = std.debug.assert;
const cache_line = std.atomic.cache_line;

const t = std.testing;
test Dora {
    const Map = Dora(u32, u32, std.hash_map.AutoContext(u32), 75);
    var map = try Map.initCapacity(t.allocator, 16);
    defer map.deinit();
}
