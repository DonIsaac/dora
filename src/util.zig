const std = @import("std");
const builtin = @import("builtin");

pub const RW = enum { read, write };

pub const IS_DEBUG = builtin.mode == .Debug;

pub inline fn debugAssert(cond: bool, message: []const u8) void {
    if (comptime IS_DEBUG) {
        if (!cond) {
            std.debug.panic(message);
        }
    }
}

pub const ptrSizeBits: comptime_int = builtin.target.ptrBitWidth();

/// TODO: compare to `std.math.isPowerOfTwo`. This uses an intrinsic instead
/// of calculating manually.
pub inline fn isPowerOfTwo(x: anytype) bool {
    return @popCount(reifyInt(x)) == 1;
}

pub inline fn nextPowerOfTwo(I: type, x: I) @TypeOf(x) {
    comptime assertInt(@TypeOf(x));
    return oneLessThanNextPowerOfTwo(I, x) + 1;
}

pub inline fn oneLessThanNextPowerOfTwo(I: type, x: I) @TypeOf(x) {
    if (x <= 1) return 0;
    const p = x - 1;
    if (I == comptime_int) {
        return std.math.maxInt(I) >> @clz(p);
    } else {
        const max: I = std.math.maxInt(I);
        return max >> @intCast(@clz(p));
    }
}

fn Reified(I: type) type {
    return if (I == comptime_int) usize else I;
}
fn reifyInt(x: anytype) Reified(@TypeOf(x)) {
    return reifyIntT(@TypeOf(x), x);
}
fn reifyIntT(I: type, x: I) Reified(I) {
    return switch (@typeInfo(I)) {
        .int => x,
        .comptime_int => @as(usize, @intCast(x)),
        else => @compileError("This function only works with integers, received " ++ @typeName(I)),
    };
}
fn assertInt(T: type) void {
    if (!@inComptime()) @compileError("This function should only be called at comptime");

    switch (@typeInfo(T)) {
        .int, .comptime_int => {},
        else => @compileError("isPowerOfTwo only works with integers, received " ++ @typeName(T)),
    }
}

// =============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test ptrSizeBits {
    try expectEqual(builtin.target.ptrBitWidth(), ptrSizeBits);
    try expectEqual(@sizeOf(usize) * 8, ptrSizeBits);
}
test isPowerOfTwo {
    try expect(isPowerOfTwo(1));
    try expect(isPowerOfTwo(2));
    try expect(isPowerOfTwo(4));
    try expect(isPowerOfTwo(8));
    try expect(isPowerOfTwo(16));

    try expect(!isPowerOfTwo(0));
    try expect(!isPowerOfTwo(3));
    try expect(!isPowerOfTwo(5));
    try expect(!isPowerOfTwo(6));
    try expect(!isPowerOfTwo(7));
}

test nextPowerOfTwo {
    inline for (.{ usize, u64, u32, u16, u8, u20 }) |T| {
        try expectEqual(1, nextPowerOfTwo(T, 0));
        try expectEqual(1, nextPowerOfTwo(T, 1));
        try expectEqual(2, nextPowerOfTwo(T, 2));
        try expectEqual(4, nextPowerOfTwo(T, 3));
        try expectEqual(4, nextPowerOfTwo(T, 4));
        try expectEqual(8, nextPowerOfTwo(T, 5));
        try expectEqual(8, nextPowerOfTwo(T, 6));
        try expectEqual(8, nextPowerOfTwo(T, 7));
        try expectEqual(8, nextPowerOfTwo(T, 8));
    }
}
