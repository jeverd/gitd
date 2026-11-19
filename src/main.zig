const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;
    std.debug.print("gitd: not implemented yet\n", .{});
}

test {
    std.testing.refAllDecls(@This());
}
