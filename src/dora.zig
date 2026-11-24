const Hash = u64;

pub fn AutoDora(
    comptime K: type,
    comptime V: type,
) type {
    return Dora(
        K,
        V,
        std.hash_map.AutoContext(K),
        .{
            .max_load_percentage = std.hash_map.default_max_load_percentage,
            .store_hash = defaultStoreHash(K),
        },
    );
}

const Options = struct {
    max_load_percentage: u64,
    /// Store each key's hash next to it. Growing a shard then reuses stored
    /// hashes instead of calling `Context.hash` on every entry, at the cost
    /// of 8 bytes (plus padding) per entry. Lookups never rehash either way:
    /// the hash used to pick a shard is reused within it.
    /// See `defaultStoreHash` for a reasonable default.
    store_hash: bool,
};

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
    /// be copied frequently and each entry stores a copy.
    ///
    /// Keys are stored, so any memory a key refers to (e.g. a slice's bytes)
    /// must stay valid and unchanged until its entry is removed.
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime options: Options,
) type {
    if (!@hasDecl(Context, "hash") or !@hasDecl(Context, "eql")) {
        @compileError("Context must have hash and eql functions");
    }
    if (@hasDecl(Context, "deinit")) {
        switch (@typeInfo(@TypeOf(Context.deinit))) {
            .@"fn" => |signature| if (signature.param_types.len != 2) {
                @compileError("Context.deinit must match signature `fn (self: @This(), value: V) void, found " ++ @typeName(@TypeOf(Context.deinit)));
            },
            else => @compileError("Context.deinit must be a function"),
        }
    }
    if (options.max_load_percentage <= 0 or options.max_load_percentage >= 100)
        @compileError("max_load_percentage must be between 0 and 100.");

    return struct {
        // not using slice to save a word
        shards: [*]align(cache_line) Shard,
        shard_count: u32,
        shift: u6,
        allocator: Allocator,

        const Self = @This();
        /// Create an empty `Dora` map with the default shard amount.
        pub fn init(allocator: Allocator) Allocator.Error!Self {
            return initCapacity(allocator, 0);
        }

        /// Create an empty `Dora` map with enough memory allocated to store
        /// at least `capacity` new entries.
        pub fn initCapacity(allocator: Allocator, capacity: usize) Allocator.Error!Self {
            return initCapacityAndShardAmount(allocator, capacity, defaultShardAmount());
        }

        pub fn initCapacityAndShardAmount(
            allocator: Allocator,
            capacity: usize,
            shard_amount: u32,
        ) Allocator.Error!Self {
            assert(shard_amount > 0);
            assert(util.isPowerOfTwo(shard_amount));

            // One less than the full shift, so a single shard does not need
            // a shift of 64. `determineShard` shifts right by 1 first.
            const shift = @as(u32, @bitSizeOf(Hash) - 1) - @ctz(shard_amount);

            const actual_capacity = if (capacity != 0)
                (capacity + (shard_amount - 1)) & ~(shard_amount - 1)
            else
                capacity;

            const cps: u32 = @intCast(actual_capacity / shard_amount);

            var shards = try allocator.alignedAlloc(Shard, .fromByteUnits(cache_line), shard_amount);
            errdefer allocator.free(shards);
            @memset(shards, Shard{});

            if (capacity > 0) {
                for (0..shard_amount) |i| {
                    var shard = &shards[i];
                    try shard.bucket.ensureTotalCapacity(allocator, cps);
                }
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
            if (shard.bucket.getPtrAdapted(key, Adapter{ .key_hash = hash })) |value| {
                return Ref{ .value = value, .shard = shard };
            } else {
                shard.unlock(.read);
                return null;
            }
        }

        pub fn getCopy(self: *Self, key: K) ?V {
            const hash, var shard = self.lock(key, .read);
            defer shard.unlock(.read);
            return shard.bucket.getAdapted(key, Adapter{ .key_hash = hash });
        }

        /// Get a mutable reference to the entry stored under `key`, if any.
        ///
        /// The shard containing `key` stays write-locked until you call
        /// `.release()` on the returned entry.
        pub fn entry(self: *Self, key: K) ?EntryMut {
            const hash, var shard = self.lock(key, .write);
            if (shard.bucket.getPtrAdapted(key, Adapter{ .key_hash = hash })) |value| {
                return EntryMut{ .key = key, .value = value, .shard = shard };
            } else {
                shard.unlock(.write);
                return null;
            }
        }

        pub fn sizeSlow(self: *Self) usize {
            var size: usize = 0;
            for (self.getShards()) |*shard| {
                shard.lock(.read);
                defer shard.unlock(.read);
                size += shard.bucket.size;
            }
            return size;
        }

        /// add a new entry. Asserts no entry exists under `key`.
        pub fn insert(self: *Self, key: K, value: V) Allocator.Error!void {
            const hash, var shard = self.lock(key, .write);
            shard.assertCurrentThreadWritable();
            defer shard.unlock(.write);
            const gop = try shard.bucket.getOrPutAdapted(self.allocator, key, Adapter{ .key_hash = hash });
            assert(!gop.found_existing);
            gop.key_ptr.* = StoredKey.init(hash, key);
            gop.value_ptr.* = value;
        }

        /// Insert an entry under `key` if no entry exists, otherwise update the existing
        /// entry.
        ///
        /// Returns the previous value stored under `key` if there was one.
        pub fn put(self: *Self, key: K, value: V) Allocator.Error!?V {
            const hash, var shard = self.lock(key, .write);
            defer shard.unlock(.write);
            const gop = try shard.bucket.getOrPutAdapted(self.allocator, key, Adapter{ .key_hash = hash });
            // Like `std.HashMap.put`, an existing entry keeps its stored key.
            const old: ?V = if (gop.found_existing) gop.value_ptr.* else null;
            if (!gop.found_existing) gop.key_ptr.* = StoredKey.init(hash, key);
            gop.value_ptr.* = value;
            return old;
        }

        pub fn delete(self: *Self, key: K) bool {
            const hash, var shard = self.lock(key, .write);
            defer shard.unlock(.write);
            const ent = shard.bucket.getEntryAdapted(key, Adapter{ .key_hash = hash }) orelse return false;
            deinitValue(ent.value_ptr);

            shard.bucket.removeByPtr(ent.key_ptr);
            return true;
        }

        /// Iterate over every value in the map, visiting shards in parallel
        /// as tasks spawned on `io`.
        ///
        /// `io` must run tasks on separate OS threads (e.g. `std.Io.Threaded`).
        /// Shard locks block the OS thread rather than yielding to `io`, so an
        /// evented `Io` that multiplexes tasks onto one thread can deadlock
        /// when a task waits on a shard held by another task on that thread.
        pub fn parIter(
            self: *Self,
            comptime IterContext: type,
            context: IterContext,
            io: std.Io,
        ) iters.ParIter(Self, IterContext, util.RW.read) {
            return .init(self, context, io);
        }

        inline fn deinitValue(value: *V) void {
            if (comptime @hasDecl(Context, "deinit")) {
                // Like `hash` and `eql`, contexts are assumed to be stateless.
                Context.deinit(undefined, value.*);
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
                        deinitValue(value);
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
            return @intCast(((hash << 7) >> 1) >> self.shift);
        }

        inline fn getShards(self: *Self) []Shard {
            return self.shards[0..self.shard_count];
        }

        /// What each shard's map stores as its key. Without `store_hash`,
        /// `hash` is zero-sized and this is laid out exactly like `K`.
        const StoredKey = struct {
            hash: if (options.store_hash) Hash else void,
            key: K,

            inline fn init(hash: Hash, key: K) StoredKey {
                return .{ .hash = if (options.store_hash) hash else {}, .key = key };
            }

            comptime {
                if (!options.store_hash) assert(@sizeOf(StoredKey) == @sizeOf(K));
            }

            /// With `store_hash`, differing hashes skip calling `Context.eql`.
            inline fn eql(a: StoredKey, b: StoredKey) bool {
                // Like `hash`, contexts are assumed to be stateless.
                return (!options.store_hash or a.hash == b.hash) and Context.eql(undefined, a.key, b.key);
            }
        };

        /// Context the shard maps use on their own, i.e. when growing. With
        /// `store_hash` it reuses the stored hash. Otherwise it rehashes the
        /// key, which gives the same hash `lock` computed for it.
        const BucketContext = struct {
            pub fn hash(_: BucketContext, s: StoredKey) Hash {
                return if (options.store_hash) s.hash else Context.hash(undefined, s.key);
            }
            pub fn eql(_: BucketContext, a: StoredKey, b: StoredKey) bool {
                return a.eql(b);
            }
        };

        /// Context for lookups and inserts: carries the hash `lock` already
        /// computed to pick the shard, so the key is hashed once per call.
        const Adapter = struct {
            key_hash: Hash,
            pub fn hash(self: Adapter, _: K) Hash {
                return self.key_hash;
            }
            pub fn eql(self: Adapter, key: K, stored: StoredKey) bool {
                return StoredKey.init(self.key_hash, key).eql(stored);
            }
        };

        const Bucket = std.HashMapUnmanaged(
            StoredKey,
            V,
            BucketContext,
            options.max_load_percentage,
        );

        /// Shards are a hash map protected by a rw lock.
        ///
        /// A key's hash determines which shard it belongs to. Operations on
        /// keys that belong to different shards can be done concurrently.
        const Shard = struct {
            bucket: Bucket = .empty,
            _lock: RwLock = .init,
            /// Is this shard write-locked, and by whom? Only writers record
            /// themselves here. Many readers can hold the lock at once, and
            /// having them all write to this field would be a data race.
            _state: DebugState = if (is_safe) .unlocked else {},
            const is_safe = std.debug.runtime_safety or builtin.is_test;

            /// This is a ZST in fast/smol release builds.
            const DebugState = if (!is_safe) void else union(enum) {
                unlocked: void,
                write_locked: struct { owner: std.Thread.Id },
            };

            pub inline fn lock(self: *Shard, comptime ty: util.RW) void {
                switch (ty) {
                    .write => {
                        self._lock.lock();
                        if (is_safe) {
                            assert(self._state == .unlocked);
                            self._state = .{ .write_locked = .{ .owner = std.Thread.getCurrentId() } };
                        }
                    },
                    .read => {
                        self._lock.lockShared();
                        if (is_safe) assert(self._state == .unlocked);
                    },
                }
            }

            pub inline fn unlock(self: *@This(), comptime ty: util.RW) void {
                switch (ty) {
                    .write => {
                        self.assertCurrentThreadWritable();
                        if (is_safe) self._state = .unlocked;
                        self._lock.unlock();
                    },
                    .read => {
                        if (is_safe) assert(self._state == .unlocked);
                        self._lock.unlockShared();
                    },
                }
            }

            inline fn assertCurrentThreadWritable(self: *Shard) void {
                if (is_safe) {
                    assert(self._state == .write_locked);
                    assert(self._state.write_locked.owner == std.Thread.getCurrentId());
                }
            }

            /// Readers are not tracked individually, so this can only check
            /// that no writer holds the shard.
            inline fn assertCurrentThreadReadable(self: *Shard) void {
                if (is_safe) assert(self._state == .unlocked);
            }
        };

        // Dora pads shards to fit in a cache line so that reading/writing
        // buckets does not evict other shards from the cache. If shards are to
        // thicc it defeats that purposes.
        // Also, HashMap is _gigantic_ in test builds. Doesn't really matter, so
        // we just skip the check.
        comptime {
            if (!builtin.is_test and builtin.mode != .debug and @sizeOf(Shard) > cache_line) {
                @compileError(
                    std.fmt.comptimePrint(
                        \\Shard is too large to fit in a cache line.
                        \\- Cache line size: {}
                        \\- Shard size: {}
                        \\- Bucket size: {}
                        \\- Lock size: {}
                        \\- Lock kind: {s}
                        \\
                    ,
                        .{
                            cache_line,
                            @sizeOf(Shard),
                            @sizeOf(Bucket),
                            @sizeOf(RwLock),
                            @typeName(RwLock),
                        },
                    ),
                );
            }
        }

        /// Read-only reference to a value in the map.
        ///
        /// ## Safety
        /// Failure to call `.release()` _will_ result in a deadlock.
        const Ref = struct {
            value: *const V,
            shard: *Shard,
            pub fn release(self: *Ref) void {
                self.shard.unlock(.read);
                self.* = undefined;
            }
        };

        /// A mutable reference to a value in the map.
        ///
        /// ## Safety
        /// Failure to call `.release()` _will_ result in a deadlock.
        const RefMut = struct {
            value: *V,
            shard: *Shard,
            pub fn release(self: *RefMut) void {
                self.shard.unlock(.write);
                self.* = undefined;
            }
        };

        /// A read-only reference to a key-value pair in the map.
        ///
        /// ## Safety
        /// Failure to call `.release()` _will_ result in a deadlock.
        const Entry = struct {
            key: K,
            value: *const V,
            shard: *Shard,
            pub fn release(self: *Entry) void {
                self.shard.unlock(.read);
                self.* = undefined;
            }
        };

        /// A mutable reference to a key-value pair in the map.
        ///
        /// ## Safety
        /// Failure to call `.release()` _will_ result in a deadlock.
        const EntryMut = struct {
            key: K,
            value: *V,
            shard: *Shard,
            pub fn release(self: *EntryMut) void {
                self.shard.unlock(.write);
                self.* = undefined;
            }
        };
    };
}

/// Picks a default `store_hash` for `K`. Returns `true` for slices and keys
/// larger than 8 bytes, which are slow to rehash.
pub fn defaultStoreHash(comptime K: type) bool {
    return switch (@typeInfo(K)) {
        .pointer => |p| p.size == .slice,
        else => @sizeOf(K) > @sizeOf(Hash),
    };
}

fn defaultShardAmount() u32 {
    if (comptime builtin.single_threaded) return 1;

    const Static = struct {
        /// 0 means "not computed yet". Computing it is idempotent, so racing
        /// threads at worst do the work twice and store the same value.
        var amount: std.atomic.Value(u32) = .init(0);
    };

    const cached = Static.amount.load(.monotonic);
    if (cached != 0) return cached;

    const nthreads = std.Thread.getCpuCount() catch 1;
    const amount = util.nextPowerOfTwo(u32, @truncate(nthreads * 4));
    std.debug.assert(amount > 0);
    Static.amount.store(amount, .monotonic);

    return amount;
}

const std = @import("std");
const builtin = @import("builtin");
const util = @import("util.zig");
const iters = @import("iter.zig");

const Allocator = std.mem.Allocator;
const RwLock = @import("RwLock.zig").RwLock(.{});

const assert = std.debug.assert;
const cache_line = std.atomic.cache_line;

const t = std.testing;
const expectEqual = t.expectEqual;

test {
    t.refAllDecls(AutoDora(u32, u32));
    _ = @import("test/dora_spec.zig");
    _ = @import("test/threading_test.zig");
}

test Dora {
    const Map = Dora(
        u32,
        u32,
        std.hash_map.AutoContext(u32),
        .{ .max_load_percentage = std.hash_map.default_max_load_percentage, .store_hash = false },
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

test "Dora.determineShard" {
    const Map = Dora(u32, u32, std.hash_map.AutoContext(u32), .{
        .max_load_percentage = std.hash_map.default_max_load_percentage,
        .store_hash = false,
    });
    var map = try Map.initCapacityAndShardAmount(t.allocator, 0, 64);
    defer map.deinit();
    try expectEqual(0, map.determineShard(0));
    try expectEqual(63, map.determineShard(std.math.maxInt(Hash)));
    // Only bits 51-56 select the shard.
    try expectEqual(63, map.determineShard(0x3F << 51));
    try expectEqual(0, map.determineShard((1 << 57) | 0xFFFF));
}

test "Dora with one shard" {
    const Map = Dora(u32, u32, std.hash_map.AutoContext(u32), .{
        .max_load_percentage = std.hash_map.default_max_load_percentage,
        .store_hash = false,
    });
    var map = try Map.initCapacityAndShardAmount(t.allocator, 16, 1);
    defer map.deinit();
    try expectEqual(0, map.determineShard(0));
    try expectEqual(0, map.determineShard(std.math.maxInt(Hash)));

    for (0..100) |i| try map.insert(@intCast(i), @intCast(i * 2));
    try expectEqual(100, map.sizeSlow());
    try expectEqual(84, map.getCopy(42));
}
