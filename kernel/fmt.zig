//! Formatted console output.

const std = @import("std");

const uart = @import("uart.zig");

/// Prints a formatted string to the UART.
pub fn println(comptime fmt: []const u8, args: anytype) void {
    uart_writer.print(fmt ++ "\n", args) catch {};
}

const Writer = std.Io.GenericWriter(void, error{}, uart_put_str);
const uart_writer = Writer{ .context = {} };

/// Prints a string one character at a time to the UART.
fn uart_put_str(_: void, str: []const u8) !usize {
    for (str) |ch| {
        uart.put_char_sync(ch);
    }
    return str.len;
}
