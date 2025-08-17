//! The main functionality of the kernel after the basic setup from start.zig
//! is completed.

const std = @import("std");
const atomic = std.atomic;

const fmt = @import("fmt.zig");
const riscv = @import("riscv.zig");
const uart = @import("uart.zig");

var started = atomic.Value(bool).init(false);

/// start() jumps here in supervisor mode on all CPUs.
pub fn kmain() noreturn {
    const cpu_id = riscv.cpu_id();
    if (cpu_id == 0) {
        uart.init();
        fmt.println("xv6 kernel is booting", .{});
        started.store(true, .release);
    } else {
        while (!started.load(.acquire)) {}
        fmt.println("hart {d} starting", .{cpu_id});
    }

    while (true) {}
}
