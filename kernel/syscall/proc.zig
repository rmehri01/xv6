//! Process related syscall implementations.

const std = @import("std");

const proc = @import("../proc.zig");
const syscall = @import("../syscall.zig");

pub fn kill() u64 {
    const pid = syscall.intArg(0);
    proc.kill(pid) catch return std.math.maxInt(u64);
    return 0;
}
