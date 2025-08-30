//! Process related syscall implementations.

const heap = @import("../heap.zig");
const proc = @import("../proc.zig");
const syscall = @import("../syscall.zig");

pub fn fork() !u64 {
    return try proc.fork(heap.page_allocator);
}

pub fn exit() noreturn {
    const status = syscall.intArg(0);
    proc.exit(@bitCast(status));
}

pub fn wait() !u64 {
    const addr = syscall.rawArg(0);
    return try proc.wait(heap.page_allocator, if (addr == 0) null else addr);
}

pub fn kill() !u64 {
    const pid = syscall.intArg(0);
    try proc.kill(pid);
    return 0;
}
