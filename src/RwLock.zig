//! A small reader-writer spin lock.
//!
//! The entire lock is a single atomic integer, so it is one word (or 4 bytes
//! with `small_state`) instead of the several words used by
//! `std.Thread.RwLock`. This keeps Dora's shards small enough to fit in a
//! cache line.
//!
//! The lock word is described by the `State` packed struct:
//! - `writer`: a writer holds the lock
//! - `writer_waiting`: a writer is waiting. New readers back off until it
//!   gets in, so a steady stream of readers cannot starve writers.
//! - `readers`: number of readers holding the lock
//!
//! Waiters spin for a short while and then yield to the OS scheduler, so this
//! lock is intended for short critical sections with low contention.
//!
//! Because waiting writers block new readers, taking a read lock on a lock
//! you already hold for reading can deadlock if a writer is waiting in
//! between (the same is true for `std.Thread.RwLock`).
//!
//! ## Misuse
//! Unlocking a lock you do not hold, or unlocking it in the wrong mode,
//! corrupts the lock. Safe builds (`Options.safe`) check for this and panic
//! before touching the state. Unsafe builds do not check.
//!
//! The API mirrors `std.Thread.RwLock`, so it can be used as a drop-in
//! replacement.
const std = @import("std");
const builtin = @import("builtin");
const atomic = std.atomic;
const Thread = std.Thread;
const Io = std.Io;

const assert = std.debug.assert;

pub const Options = struct {
    /// Force 4-byte state even on 64-bit platforms.
    small_state: bool = false,
    /// Check for misuse (e.g. unlocking a lock that is not held).
    safe: bool = switch (builtin.mode) {
        .debug, .safe => true,
        .fast, .small => false,
    },
};

pub fn RwLock(comptime options: Options) type {
    return struct {
        state: atomic.Value(State),

        const Self = @This();
        pub const init: Self = .{ .state = .init(.unlocked) };

        pub const Repr = if (options.small_state) u32 else usize;

        /// A snapshot of who holds the lock and who is waiting for it.
        const State = packed struct(Repr) {
            // Field order is load-bearing: `readers` must occupy the low bits
            // so that `fetchSub(.one_reader)` only changes the reader count.
            /// Number of readers holding a shared lock
            readers: Readers = 0,
            /// Whether a consumer is waiting on an exclusive lock
            writer_waiting: bool = false,
            /// Whether a consumer is holding an exclusive lock
            writer: bool = false,

            const Readers = @Int(.unsigned, @bitSizeOf(Repr) - 2);
            pub const max_readers = std.math.maxInt(Readers);

            pub const unlocked: State = .{};
            pub const write_locked: State = .{ .writer = true };

            // Operands for atomic read-modify-write ops on the lock word.
            /// Only the `writer_waiting` bit, for setting it with `fetchOr`.
            const waiting_bit: State = .{ .writer_waiting = true };
            /// One reader, for adding/removing a reader with `fetchSub`.
            const one_reader: State = .{ .readers = 1 };
            /// Every bit except `writer`, for clearing it with `fetchAnd`.
            const not_writer: State = .{ .readers = max_readers, .writer_waiting = true };

            /// Returns `true` if nobody holds the lock, so a writer could take
            /// it. Writers may still be waiting.
            inline fn isFree(s: State) bool {
                return !s.writer and s.readers == 0;
            }

            /// Returns `true` if a new reader could take a shared lock right
            /// now: no writer holds the lock or is waiting for it, and the
            /// reader count has not hit `max_readers`.
            inline fn canAddReader(s: State) bool {
                return !s.writer and !s.writer_waiting and s.readers < max_readers;
            }

            /// Returns a copy of `s` with one more reader. `s` must allow a
            /// new reader; see `canAddReader`.
            inline fn withReader(s: State) State {
                assert(s.canAddReader());
                var next = s;
                next.readers += 1;
                return next;
            }
        };

        /// Try to acquire an exclusive (write) lock without blocking.
        /// Returns `true` if the lock was acquired.
        pub fn tryLock(self: *Self) bool {
            var curr = self.state.load(.monotonic);
            while (curr.isFree()) {
                curr = self.state.cmpxchgWeak(curr, .write_locked, .acquire, .monotonic) orelse return true;
            }
            return false;
        }

        /// Acquire an exclusive (write) lock, blocking until it is available.
        pub fn lock(self: *Self) void {
            var backoff: Backoff = .init;
            var curr = self.state.load(.monotonic);
            while (true) {
                if (curr.isFree()) {
                    // Nobody holds the lock. Taking it also clears
                    // `writer_waiting`; other waiting writers set it again.
                    curr = self.state.cmpxchgWeak(curr, .write_locked, .acquire, .monotonic) orelse return;
                    continue;
                }
                if (!curr.writer_waiting) {
                    // Stop new readers from getting in ahead of us.
                    _ = self.state.fetchOr(.waiting_bit, .monotonic);
                }
                backoff.snooze();
                curr = self.state.load(.monotonic);
            }
        }

        /// Release an exclusive (write) lock held by the caller.
        pub fn unlock(self: *Self) void {
            if (comptime options.safe) {
                const curr = self.state.load(.monotonic);
                if (!curr.writer) @panic("RwLock.unlock() called without holding a write lock");
                assert(curr.readers == 0);
            }
            // Keep `writer_waiting` so readers keep waiting for the next writer.
            _ = self.state.fetchAnd(.not_writer, .release);
        }

        /// Try to acquire a shared (read) lock without blocking.
        /// Returns `true` if the lock was acquired.
        pub fn tryLockShared(self: *Self) bool {
            var curr = self.state.load(.monotonic);
            while (curr.canAddReader()) {
                curr = self.state.cmpxchgWeak(curr, curr.withReader(), .acquire, .monotonic) orelse return true;
            }
            return false;
        }

        /// Acquire a shared (read) lock, blocking while a writer holds the
        /// lock or is waiting for it.
        pub fn lockShared(self: *Self) void {
            var backoff: Backoff = .init;
            var curr = self.state.load(.monotonic);
            while (true) {
                if (curr.canAddReader()) {
                    // On failure, another reader probably raced us. Retry with
                    // the fresh value.
                    curr = self.state.cmpxchgWeak(curr, curr.withReader(), .acquire, .monotonic) orelse return;
                } else {
                    backoff.snooze();
                    curr = self.state.load(.monotonic);
                }
            }
        }

        /// Release a shared (read) lock held by the caller.
        pub fn unlockShared(self: *Self) void {
            if (comptime options.safe) {
                const curr = self.state.load(.monotonic);
                if (curr.writer or curr.readers == 0) {
                    @panic("RwLock.unlockShared() called without holding a read lock");
                }
            }
            _ = self.state.fetchSub(.one_reader, .release);
        }
    };
}

/// Spin a few times, then start yielding the thread so that whoever holds the
/// lock gets a chance to run when there are more threads than cores.
const Backoff = struct {
    spins: u32,

    const spin_limit = 64;

    pub const init: Backoff = .{ .spins = 0 };

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
    try t.expectEqual(@sizeOf(u32), @sizeOf(RwLock(.{ .small_state = true })));
}

test "State layout matches the lock word" {
    inline for (.{ RwLock(.{}), RwLock(.{ .small_state = true }) }) |Rw| {
        const bits = @bitSizeOf(Rw.Repr);
        try t.expectEqual(bits, @bitSizeOf(Rw.State));
        try t.expectEqual(0, @as(Rw.Repr, @bitCast(Rw.State.unlocked)));
        try t.expectEqual(1, @as(Rw.Repr, @bitCast(Rw.State.one_reader)));
        try t.expectEqual(1 << (bits - 1), @as(Rw.Repr, @bitCast(Rw.State.write_locked)));
        try t.expectEqual(1 << (bits - 2), @as(Rw.Repr, @bitCast(Rw.State.waiting_bit)));
        try t.expectEqual(~@as(Rw.Repr, @bitCast(Rw.State.write_locked)), @as(Rw.Repr, @bitCast(Rw.State.not_writer)));
    }
}

test "smoke test" {
    var rw: RwLock(.{}) = .init;
    try t.expectEqual(@TypeOf(rw).State.unlocked, rw.state.raw);

    // write lock excludes everyone
    try t.expect(rw.tryLock());
    try t.expectEqual(@TypeOf(rw).State.write_locked, rw.state.load(.monotonic));
    try t.expect(!rw.tryLock());
    try t.expect(!rw.tryLockShared());
    rw.unlock();
    try t.expectEqual(@TypeOf(rw).State.unlocked, rw.state.raw);

    // read locks are shared, but exclude writers
    rw.lockShared();
    try t.expect(rw.tryLockShared());
    try t.expectEqual(@TypeOf(rw).State{ .readers = 2, .writer_waiting = false, .writer = false }, rw.state.load(.monotonic));
    try t.expect(!rw.tryLock());
    rw.unlockShared();
    rw.unlockShared();
    try t.expectEqual(@TypeOf(rw).State.unlocked, rw.state.raw);

    rw.lock();
    rw.unlock();
    try t.expectEqual(@TypeOf(rw).State.unlocked, rw.state.raw);
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

    var rw: Rw = .init;
    var acquired = atomic.Value(bool).init(false);

    switch (held) {
        .read => rw.lockShared(),
        .write => rw.lock(),
    }
    const thread = try Thread.spawn(.{}, Waiter.run, .{ &rw, &acquired });

    try t.io.sleep(.fromMilliseconds(20), .awake);
    const got_in_early = acquired.load(.acquire);

    switch (held) {
        .read => rw.unlockShared(),
        .write => rw.unlock(),
    }
    thread.join();

    try t.expect(!got_in_early);
    try t.expect(acquired.load(.acquire));
    try t.expectEqual(@TypeOf(rw).State.unlocked, rw.state.raw);
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

test "waiting writer blocks new readers" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const Rw = RwLock(.{});
    const Writer = struct {
        fn run(rw: *Rw) void {
            rw.lock();
            rw.unlock();
        }
    };

    var rw: Rw = .init;
    rw.lockShared();
    const thread = try Thread.spawn(.{}, Writer.run, .{&rw});

    // Wait for the writer to announce itself.
    const start = Io.Timestamp.now(t.io, .awake);
    while (!rw.state.load(.monotonic).writer_waiting) {
        if (start.untilNow(t.io, .awake).toSeconds() >= 1) {
            rw.unlockShared();
            thread.join();
            return error.WriterNeverWaited;
        }
        Thread.yield() catch {};
    }

    // A new reader must not get in ahead of the writer.
    const reader_got_in = rw.tryLockShared();
    if (reader_got_in) rw.unlockShared();
    rw.unlockShared();
    thread.join();

    try t.expect(!reader_got_in);
    try t.expectEqual(@TypeOf(rw).State.unlocked, rw.state.raw);
}

test "overlapping readers do not starve a writer" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const Rw = RwLock(.{});
    const reader_count = 4;

    const Shared = struct {
        rw: Rw = .init,
        stop: atomic.Value(bool) = .init(false),

        fn read(self: *@This()) void {
            while (!self.stop.load(.acquire)) {
                self.rw.lockShared();
                // Hold long enough that readers always overlap.
                t.io.sleep(.fromMicroseconds(100), .awake) catch {};
                self.rw.unlockShared();
            }
        }
    };

    var shared = Shared{};
    var threads: [reader_count]Thread = undefined;
    for (&threads) |*th| th.* = try Thread.spawn(.{}, Shared.read, .{&shared});
    defer {
        shared.stop.store(true, .release);
        for (threads) |th| th.join();
    }

    // Let the readers get going so the lock is (almost) always read-held.
    try t.io.sleep(.fromMilliseconds(10), .awake);

    const start = Io.Timestamp.now(t.io, .awake);
    for (0..10) |_| {
        shared.rw.lock();
        shared.rw.unlock();
    }
    // Without writer priority this can take forever. Be generous to avoid
    // flaking on slow CI machines.
    try t.expect(start.untilNow(t.io, .awake).toSeconds() < 5);
}

test "readers and writers under contention" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const Rw = RwLock(.{});
    const writer_count = 4;
    const reader_count = 4;
    const iterations = 20_000;

    const Shared = struct {
        rw: Rw = .init,
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
    try t.expectEqual(Rw.State.unlocked, shared.rw.state.raw);
}

test "Lock state representation" {
    const S = RwLock(.{}).State;
    try t.expectEqual(0, @as(usize, @bitCast(S.unlocked)));
    try t.expectEqual(1, @as(usize, @bitCast(S.one_reader)));
}

test "Adding readers" {
    const S = RwLock(.{}).State;
    try t.expect(S.unlocked.canAddReader());
    try t.expect(S.one_reader.canAddReader());
    try t.expect(!(S{ .writer = true }).canAddReader());
    try t.expect(!(S{ .writer_waiting = true }).canAddReader());
}
