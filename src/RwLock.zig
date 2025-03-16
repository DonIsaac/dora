const std = @import("std");
const builtin = @import("builtin");
// const util = @import("util.zig");
const atomic = std.atomic;
const Thread = std.Thread;
const AtomicOrder = std.builtin.AtomicOrder;

const assert = std.debug.assert;

// std.Thread.Semaphore()
var debug_allocator = std.heap.DebugAllocator(.{}){};

pub const Options = struct {
    /// force 4-byte state even on 64-bit platforms.
    small_state: bool = false,
    safe: bool = switch (builtin.mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseFast, .ReleaseSmall => false,
    },
};

// pub fn RwLock(comptime options: Options) type {
//     const State = enum(if (options.small_state) i32 else isize) {
//         unlocked = 0,
//         write_locked = -1,
//         read_locked = 1,
//         _,
//     };

//     const Debug = struct {
//         const allocator = if (builtin.is_test)
//             std.testing.allocator
//         else if (builtin.link_libc)
//             std.heap.c_allocator
//         else
//             debug_allocator.allocator();

//         lock: Thread.Mutex = .{},
//         state: State = .unlocked,

//         const State = union(enum) {
//             unlocked: void,
//             write_locked: Owner,
//             read_locked: struct {
//                 // lock: std.Thread.Mutex = .{},
//                 owners: std.ArrayList(Owner) = .init(allocator)
//             },

//         };

//         const Owner = struct {
//             owner: Thread.Id,
//             stack_trace: std.builtin.StackTrace,

//             pub fn init() Owner {
//                 var trace = std.builtin.StackTrace{
//                     .index = 0,
//                     .instruction_addresses = allocator.alloc(usize, 32) catch unreachable,
//                 };
//                 std.debug.captureStackTrace(null, &trace);
//                 return .{
//                     .owner = std.Thread.getCurrentId(),
//                     .locked_at = trace,
//                 };
//             }

//             fn deinit(self: *Owner) void {
//                 self.stack_trace.instruction_addresses.deinit();
//                 self.* = undefined;
//             }
//         };
//     };
//     const DebugState = union(enum) {
//         // unlocked: void,
//         // write_locked: Owner,
//         // read_locked: Owner,
//         lock: std.Thread.Mutex,

//         const Owner = struct {
//             thread_id: usize,
//         };
//         pub const Ref = if (options.safe) atomic.Value(*DebugState);
//     };

//     return struct {
//         state: atomic.Value(State) = .init(.unlocked),
//         debug_state: if (options.safe) Debug else void = if (options.safe) .{},
//     };
// }
pub fn RwLock(comptime options: Options) type {
    const Repr = if (options.small_state) i32 else isize;
    const State = enum(Repr) {
        unlocked = 0,
        write_locked = -1,
        read_locked = 1,
        _,

        fn isRead(self: @This()) bool {
            return @as(Repr, @intFromEnum(self)) > 0;
        }
        fn canReadLock(self: @This()) bool {
            return @as(Repr, @intFromEnum(self)) >= 0;
        }

        fn nextRead(self: @This()) @This() {
            if (comptime builtin.mode == .Debug) assert(self.canReadLock());
            return @enumFromInt(@intFromEnum(self) +| 1);
        }

        fn prevRead(self: @This()) @This() {
            if (comptime builtin.mode == .Debug) assert(self.isRead());
            return @enumFromInt(@intFromEnum(self) -| 1);
        }

        fn asDesiredNextRead(self: @This()) @This() {
            return from(@max(0, @intFromEnum(self)));
        }

        fn from(repr: Repr) @This() {
            assert(repr >= -1);
            return @enumFromInt(repr);
        }

        fn into(state: @This()) Repr {
            const repr: Repr = @intFromEnum(state);
            assert(repr >= -1);
            return repr;
        }
    };

    return struct {
        state: atomic.Value(State) = .init(.unlocked),

        const Self = @This();

        pub fn tryLock(self: *Self) bool {
            return self.state.cmpxchgStrong(
                .unlocked,
                .write_locked,
                AtomicOrder.acquire,
                AtomicOrder.monotonic,
            ) == null;
        }

        pub fn lock(self: *Self) void {
            while (self.state.cmpxchgWeak(
                .unlocked,
                .write_locked,
                AtomicOrder.acquire,
                AtomicOrder.monotonic,
            ) == null) : (atomic.spinLoopHint()) {}
        }

        pub fn unlock(self: *Self) void {
            if (comptime options.safe) {
                const curr = self.state.load(AtomicOrder.acquire);
                assert(curr == .write_locked);
            }

            while (self.state.cmpxchgWeak(
                .write_locked,
                .unlocked,
                AtomicOrder.release,
                AtomicOrder.monotonic,
            )) |curr_state| : (atomic.spinLoopHint()) {
                if (comptime options.safe) {
                    assert(curr_state == .write_locked);
                }
            }
        }

        pub fn lockShared(self: *Self) void {
            var curr_state = self.state.load(AtomicOrder.monotonic);
            var next = curr_state.nextRead();
            while (self.state.cmpxchgWeak(curr_state.asDesiredNextRead(), next, .acquire, .monotonic)) |new_curr| {
                curr_state = new_curr;
                next = curr_state.nextRead();
                atomic.spinLoopHint();
            }
        }

        pub fn unlockShared(self: *Self) void {
            if (comptime options.safe) {
                const curr = self.state.load(AtomicOrder.acquire);
                assert(curr.canReadLock());
            }
            var curr_state = self.state.load(AtomicOrder.monotonic);
            while (self.state.cmpxchgWeak(curr_state, curr_state.prevRead(), .release, .monotonic)) |new_curr| : (atomic.spinLoopHint()) {
                if (comptime options.safe) assert(new_curr.isRead());
                curr_state = new_curr;
            }
        }
    };
}

const t = std.testing;
test {
    std.testing.refAllDecls(RwLock(.{}));
}

test "smoke test" {
    var lock = RwLock(.{}){};
    try t.expectEqual(.unlocked, lock.state.raw);

    try t.expect(lock.tryLock());
    lock.unlock();
    try t.expectEqual(.unlocked, lock.state.raw);

    {
        lock.lockShared();
        lock.lockShared();
        defer {
            lock.unlockShared();
            lock.unlockShared();
        }
        try t.expectEqual(2, lock.state.raw.into());
    }
}

test "multiple readers" {
    const Reader = struct {
        l: *RwLock(.{}),
        fn doRead(self: *@This()) void {
            self.l.lockShared();
        }
    };

    var lock = RwLock(.{}){};
    var readers: [10]Reader = undefined;
    {
        var pool: Thread.Pool = undefined;
        try pool.init(.{ .allocator = t.allocator });
        defer pool.deinit();
        for (0..10) |i| {
            readers[i] = .{ .l = &lock };
            try pool.spawn(Reader.doRead, .{&readers[i]});
        }
    }

    try t.expectEqual(10, lock.state.load(AtomicOrder.monotonic).into());
}
