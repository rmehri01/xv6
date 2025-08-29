//! Process related syscall implementations.

const heap = @import("../heap.zig");
const proc = @import("../proc.zig");
const syscall = @import("../syscall.zig");

pub fn fork() !u64 {
    return try proc.fork(heap.page_allocator);
}

pub fn kill() !u64 {
    const pid = syscall.intArg(0);
    try proc.kill(pid);
    return 0;
}
