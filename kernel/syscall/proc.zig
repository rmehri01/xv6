//! Process related syscall implementations.

const std = @import("std");

const defs = @import("shared").syscall;

const heap = @import("../heap.zig");
const proc = @import("../proc.zig");
const syscall = @import("../syscall.zig");

const ticks = &@import("../trap.zig").ticks;

pub fn fork() !u64 {
    return try proc.fork(heap.page_allocator);
}

pub fn exit() noreturn {
    const status = syscall.intArg(0);
    proc.exit(@bitCast(status));
}

pub fn getpid() u64 {
    return proc.myProc().?.public.pid;
}

pub fn wait() !u64 {
    const addr = syscall.rawArg(0);
    return try proc.wait(heap.page_allocator, if (addr == 0) null else addr);
}

pub fn sbrk() !u64 {
    const p = proc.myProc().?;

    const bytes: i32 = @bitCast(syscall.intArg(0));
    const ty = std.enums.fromInt(
        defs.SbrkType,
        syscall.intArg(1),
    ) orelse return error.UnknownSbrkType;
    const addr = p.private.size;

    switch (ty) {
        .eager => try proc.resize(heap.page_allocator, bytes),
        .lazy => {
            // Lazily allocate memory for this process: increase its memory
            // size but don't allocate memory. If the processes uses the
            // memory, vm.handleFault() will allocate it.
            if (bytes < 0)
                return error.SbrkOutOfRange;

            p.private.size += @abs(bytes);
        },
    }

    return addr;
}

pub fn kill() !u64 {
    const pid = syscall.intArg(0);
    try proc.kill(pid);
    return 0;
}

pub fn pause() !u64 {
    const n = syscall.intArg(0);

    ticks.mutex.lock();
    defer ticks.mutex.unlock();

    const ticks0 = ticks.value;
    while (ticks.value - ticks0 < n) {
        if (proc.myProc().?.isKilled()) {
            return error.Killed;
        }

        proc.sleep(@intFromPtr(ticks), &ticks.mutex);
    }

    return 0;
}

pub fn uptime() !u64 {
    ticks.mutex.lock();
    defer ticks.mutex.unlock();

    return ticks.value;
}
