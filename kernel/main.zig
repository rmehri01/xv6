//! The main functionality of the kernel after the basic setup from start.zig
//! is completed.

const std = @import("std");

const fmt = @import("fmt.zig");
const riscv = @import("riscv.zig");
const uart = @import("uart.zig");

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);

    const cpu_id = riscv.cpu_id();
    fmt.println("hart {d}: KERNEL PANIC! {s} addr={?x}", .{ cpu_id, msg, first_trace_addr });

    while (true) {}
}

var started = std.atomic.Value(bool).init(false);

/// start() jumps here in supervisor mode on all CPUs.
pub fn kmain() noreturn {
    const cpu_id = riscv.cpu_id();
    if (cpu_id == 0) {
        uart.init();
        fmt.println("xv6 kernel is booting", .{});
        started.store(true, .release);
    } else {
        while (!started.load(.acquire)) {
            std.atomic.spinLoopHint();
        }
        fmt.println("hart {d}: starting", .{cpu_id});
    }

    while (true) {}
}
