//! Process related syscall implementations.

const proc = @import("../proc.zig");
const syscall = @import("../syscall.zig");

pub fn kill() !u64 {
    const pid = syscall.intArg(0);
    try proc.kill(pid);
    return 0;
}
