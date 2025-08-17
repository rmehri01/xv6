//! The main functionality of the kernel after the basic setup from start.zig
//! is completed.

const fmt = @import("fmt.zig");
const uart = @import("uart.zig");

/// start() jumps here in supervisor mode on all CPUs.
pub fn kmain() noreturn {
    uart.init();
    fmt.println("booted!", .{});
    while (true) {}
}
