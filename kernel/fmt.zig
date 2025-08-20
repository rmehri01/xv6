//! Formatted console output.

const uart = @import("uart.zig");

/// Prints a formatted string to the UART.
pub fn println(comptime fmt: []const u8, args: anytype) void {
    var w = &uart.sync_writer;
    w.mutex.lock();
    defer w.mutex.unlock();

    w.interface.print(fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
}
