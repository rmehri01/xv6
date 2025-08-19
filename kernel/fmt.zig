//! Formatted console output.

const uart = @import("uart.zig");

/// Prints a formatted string to the UART.
pub fn println(comptime fmt: []const u8, args: anytype) void {
    uart.sync_writer.mutex.lock();
    defer uart.sync_writer.mutex.unlock();

    uart.sync_writer.interface.print(fmt ++ "\n", args) catch {};
    uart.sync_writer.interface.flush() catch {};
}
