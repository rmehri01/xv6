//! Formatted console output from userspace.

const std = @import("std");
const Writer = std.Io.Writer;

const syscall = @import("syscall.zig");

var buffer: [1024]u8 = undefined;

// TODO: temporary hack to print
pub fn println(comptime fmt: []const u8, args: anytype) void {
    const str = std.fmt.bufPrint(&buffer, fmt ++ "\n", args) catch
        return;
    _ = writeStr(str) catch return;
}

// TODO: for some reason this doesn't work

// var writer: Writer = .{
//     .buffer = &buffer,
//     .vtable = &.{
//         .drain = drain,
//     },
// };

// pub fn println(comptime fmt: []const u8, args: anytype) void {
//     writer.print(fmt ++ "\n", args) catch {};
//     writer.flush() catch {};
// }

// fn drain(io_w: *Writer, data: []const []const u8, splat: usize) !usize {
//     var written: usize = 0;

//     written += try writeStr(io_w.buffered());
//     io_w.end = 0;

//     for (data[0 .. data.len - 1]) |chunk| {
//         written += try writeStr(chunk);
//     }
//     for (0..splat) |_| {
//         written += try writeStr(data[data.len - 1]);
//     }

//     return written;
// }

fn writeStr(str: []const u8) Writer.Error!usize {
    return syscall.write(2, str) catch
        return Writer.Error.WriteFailed;
}
