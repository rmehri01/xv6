//! Console input and output, to the uart.
//! Reads are line at a time.
//! Implements special input characters:
//!   newline -- end of line
//!   control-h -- backspace
//!   control-u -- kill line
//!   control-d -- end of file
//!   control-p -- print process list

const heap = @import("heap.zig");
const proc = @import("proc.zig");
const uart = @import("uart.zig");

/// User write()s to the console go here.
pub fn write(source: proc.EitherMem) u64 {
    const len = switch (source) {
        .user => |dst| dst.len,
        .kernel => |dst| dst.len,
    };
    var buf: [32]u8 = undefined;
    var written: u64 = 0;

    while (written < len) {
        var bytes_to_write = buf.len;
        if (bytes_to_write > len - written)
            bytes_to_write = len - written;

        const src: proc.EitherMem = switch (source) {
            .user => |src| .{
                .user = .{ .addr = src.addr + written, .len = bytes_to_write },
            },
            .kernel => |src| .{ .kernel = src[written..][0..bytes_to_write] },
        };
        proc.eitherCopyIn(
            heap.page_allocator,
            buf[0..bytes_to_write],
            src,
        ) catch break;
        uart.write(buf[0..bytes_to_write]);

        written += bytes_to_write;
    }

    return written;
}

pub fn read(dest: proc.EitherMem) u64 {
    _ = dest; // autofix
    @panic("todo console read");
}
