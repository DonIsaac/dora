const std = @import("std");
const dora = @import("dora.zig");

pub const Dora = dora.Dora;
pub const AutoDora = dora.AutoDora;

test {
    _ = Dora;
    std.testing.refAllDecls(@import("iter.zig"));
}
