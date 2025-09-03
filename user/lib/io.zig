//! Input/Output.

const std = @import("std");

const syscall = @import("syscall.zig");

pub const Output = enum(u2) {
    stdout = 1,
    stderr = 2,
};

pub var stdout: Writer(.stdout) = .{};
pub var stderr: Writer(.stderr) = .{};

fn Writer(output: Output) type {
    return struct {
        var buffer: [1024]u8 = undefined;
        interface: std.Io.Writer = .{
            .buffer = &buffer,
            .vtable = &.{
                .drain = drain,
            },
        },

        fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
            var written: usize = 0;

            written += try writeStr(io_w.buffered());
            io_w.end = 0;

            for (data[0 .. data.len - 1]) |chunk| {
                written += try writeStr(chunk);
            }
            for (0..splat) |_| {
                written += try writeStr(data[data.len - 1]);
            }

            return written;
        }

        pub fn println(self: *@This(), comptime fmt: []const u8, args: anytype) void {
            self.print(fmt ++ "\n", args);
        }

        pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) void {
            self.interface.print(fmt, args) catch {};
            self.interface.flush() catch {};
        }

        fn writeStr(str: []const u8) std.Io.Writer.Error!usize {
            return syscall.write(@intFromEnum(output), str) catch
                return std.Io.Writer.Error.WriteFailed;
        }
    };
}

pub fn getStr(buf: []u8) []const u8 {
    @memset(buf, 0);

    var read: usize = 0;
    while (read < buf.len) {
        const num_read = syscall.read(0, buf[read..][0..1]) catch
            break;
        if (num_read == 0)
            break;

        defer read += num_read;
        if (buf[read] == '\n' or buf[read] == '\r')
            break;
    }
    return buf[0..read];
}
