//! A small reader-writer spin lock.
//!
//! The entire lock is a single atomic integer, so it is one word (or 4 bytes
//! with `small_state`) instead of the several words used by
//! `std.Thread.RwLock`. This keeps Dora's shards small enough to fit in a
//! cache line.
//!
//! State encoding:
//! - `0`: unlocked
//! - `-1`: locked by a single writer
//! - `n > 0`: locked by `n` readers
//!
//! Waiters spin for a short while and then yield to the OS scheduler. There
//! is no fairness: a steady stream of readers can starve a writer. This lock
//! is intended for short critical sections with low contention.
//!
//! The API mirrors `std.Thread.RwLock`, so it can be used as a drop-in
//! replacement.
const std = @import("std");
const builtin = @import("builtin");
const atomic = std.atomic;
const Thread = std.Thread;

const assert = std.debug.assert;

pub const Options = struct {
    /// Force 4-byte state even on 64-bit platforms.
    small_state: bool = false,
    /// Check for misuse (e.g. unlocking a lock that is not held).
    safe: bool = switch (builtin.mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseFast, .ReleaseSmall => false,
    },
};

pub fn RwLock(comptime options: Options) type {
    return struct {
        state: atomic.Value(State) = .init(unlocked),

        const Self = @This();

        pub const State = if (options.small_state) i32 else isize;
        const unlocked: State = 0;
        const write_locked: State = -1;
        const max_readers: State = std.math.maxInt(State);

        /// Try to acquire an exclusive (write) lock without blocking.
        /// Returns `true` if the lock was acquired.
        pub fn tryLock(self: *Self) bool {
            return self.state.cmpxchgStrong(unlocked, write_locked, .acquire, .monotonic) == null;
        }

        /// Acquire an exclusive (write) lock, blocking until it is available.
        pub fn lock(self: *Self) void {
            var backoff: Backoff = .{};
            while (true) {
                // Only attempt the (cache-line-invalidating) CAS when the lock
                // looks free.
                if (self.state.load(.monotonic) == unlocked and
                    self.state.cmpxchgWeak(unlocked, write_locked, .acquire, .monotonic) == null)
                {
                    return;
                }
                backoff.snooze();
            }
        }

        /// Release an exclusive (write) lock held by the caller.
        pub fn unlock(self: *Self) void {
            if (comptime options.safe) {
                const prev = self.state.swap(unlocked, .release);
                assert(prev == write_locked);
            } else {
                self.state.store(unlocked, .release);
            }
        }

        /// Try to acquire a shared (read) lock without blocking.
        /// Returns `true` if the lock was acquired.
        pub fn tryLockShared(self: *Self) bool {
            var curr = self.state.load(.monotonic);
            while (curr >= 0) {
                if (comptime options.safe) assert(curr < max_readers);
                curr = self.state.cmpxchgWeak(curr, curr + 1, .acquire, .monotonic) orelse return true;
            }
            return false;
        }

        /// Acquire a shared (read) lock, blocking while a writer holds the lock.
        pub fn lockShared(self: *Self) void {
            var backoff: Backoff = .{};
            var curr = self.state.load(.monotonic);
            while (true) {
                if (curr >= 0) {
                    if (comptime options.safe) assert(curr < max_readers);
                    // On failure, another reader probably raced us. Retry with
                    // the fresh value.
                    curr = self.state.cmpxchgWeak(curr, curr + 1, .acquire, .monotonic) orelse return;
                } else {
                    backoff.snooze();
                    curr = self.state.load(.monotonic);
                }
            }
        }

        /// Release a shared (read) lock held by the caller.
        pub fn unlockShared(self: *Self) void {
            const prev = self.state.fetchSub(1, .release);
            if (comptime options.safe) assert(prev > 0);
        }
    };
}

/// Spin a few times, then start yielding the thread so that whoever holds the
/// lock gets a chance to run when there are more threads than cores.
const Backoff = struct {
    spins: u32 = 0,

    const spin_limit = 64;

    fn snooze(self: *Backoff) void {
        if (self.spins < spin_limit) {
            self.spins += 1;
            atomic.spinLoopHint();
        } else {
            Thread.yield() catch atomic.spinLoopHint();
        }
    }
};

const t = std.testing;

test {
    t.refAllDecls(RwLock(.{}));
    t.refAllDecls(RwLock(.{ .small_state = true }));
}

test "size" {
    try t.expectEqual(@sizeOf(usize), @sizeOf(RwLock(.{})));
    try t.expectEqual(4, @sizeOf(RwLock(.{ .small_state = true })));
}

test "smoke test" {
    var rw = RwLock(.{}){};
    try t.expectEqual(0, rw.state.raw);

    // write lock excludes everyone
    try t.expect(rw.tryLock());
    try t.expectEqual(-1, rw.state.raw);
    try t.expect(!rw.tryLock());
    try t.expect(!rw.tryLockShared());
    rw.unlock();
    try t.expectEqual(0, rw.state.raw);

    // read locks are shared, but exclude writers
    rw.lockShared();
    try t.expect(rw.tryLockShared());
    try t.expectEqual(2, rw.state.raw);
    try t.expect(!rw.tryLock());
    rw.unlockShared();
    rw.unlockShared();
    try t.expectEqual(0, rw.state.raw);

    rw.lock();
    rw.unlock();
    try t.expectEqual(0, rw.state.raw);
}

/// Hold `rw` in `held` mode, then check that another thread trying to take
/// it in `wanted` mode blocks until we release it.
fn expectBlocks(comptime held: enum { read, write }, comptime wanted: enum { read, write }) !void {
    if (builtin.single_threaded) return error.SkipZigTest;

    const Rw = RwLock(.{});
    const Waiter = struct {
        fn run(rw: *Rw, acquired: *atomic.Value(bool)) void {
            switch (wanted) {
                .read => rw.lockShared(),
                .write => rw.lock(),
            }
            acquired.store(true, .release);
            switch (wanted) {
                .read => rw.unlockShared(),
                .write => rw.unlock(),
            }
        }
    };

    var rw = Rw{};
    var acquired = atomic.Value(bool).init(false);

    switch (held) {
        .read => rw.lockShared(),
        .write => rw.lock(),
    }
    const thread = try Thread.spawn(.{}, Waiter.run, .{ &rw, &acquired });

    Thread.sleep(20 * std.time.ns_per_ms);
    const got_in_early = acquired.load(.acquire);

    switch (held) {
        .read => rw.unlockShared(),
        .write => rw.unlock(),
    }
    thread.join();

    try t.expect(!got_in_early);
    try t.expect(acquired.load(.acquire));
    try t.expectEqual(0, rw.state.raw);
}

test "lock() blocks while write-locked" {
    try expectBlocks(.write, .write);
}

test "lock() blocks while read-locked" {
    try expectBlocks(.read, .write);
}

test "lockShared() blocks while write-locked" {
    try expectBlocks(.write, .read);
}

test "readers and writers under contention" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const Rw = RwLock(.{});
    const writer_count = 4;
    const reader_count = 4;
    const iterations = 20_000;

    const Shared = struct {
        rw: Rw = .{},
        // Writers keep these equal. Readers check that they never see a
        // half-finished write. Deliberately not atomic.
        a: u64 = 0,
        b: u64 = 0,
        torn_reads: atomic.Value(u32) = .init(0),

        fn write(self: *@This()) void {
            for (0..iterations) |_| {
                self.rw.lock();
                defer self.rw.unlock();
                const next = self.a + 1;
                self.a = next;
                atomic.spinLoopHint();
                self.b = next;
            }
        }

        fn read(self: *@This()) void {
            for (0..iterations) |_| {
                self.rw.lockShared();
                defer self.rw.unlockShared();
                const a = @as(*volatile u64, &self.a).*;
                atomic.spinLoopHint();
                const b = @as(*volatile u64, &self.b).*;
                if (a != b) _ = self.torn_reads.fetchAdd(1, .monotonic);
            }
        }
    };

    var shared = Shared{};
    var threads: [writer_count + reader_count]Thread = undefined;
    for (threads[0..writer_count]) |*th| th.* = try Thread.spawn(.{}, Shared.write, .{&shared});
    for (threads[writer_count..]) |*th| th.* = try Thread.spawn(.{}, Shared.read, .{&shared});
    for (threads) |th| th.join();

    try t.expectEqual(0, shared.torn_reads.load(.monotonic));
    try t.expectEqual(writer_count * iterations, shared.a);
    try t.expectEqual(shared.a, shared.b);
    try t.expectEqual(0, shared.rw.state.raw);
}
