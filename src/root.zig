const std = @import("std");
const dora = @import("dora.zig");

pub const Dora = dora.Dora;
pub const AutoDora = dora.AutoDora;

test {
    _ = Dora;
    std.testing.refAllDecls(@import("iter.zig"));
}
// export fn add(a: i32, b: i32) i32 {
//     return a + b;
// }

// test "basic add functionality" {
//     try testing.expect(add(3, 7) == 10);
// }
