//! Shell.

const std = @import("std");

const file = @import("shared").file;
const ulib = @import("ulib");
const fmt = ulib.fmt;
const io = ulib.io;
const syscall = ulib.syscall;

pub fn main() !void {
    var buf: [100]u8 = undefined;

    // Read and run input commands.
    while (getCmd(&buf)) |cmd| {
        fmt.println("got cmd: {s}", .{cmd});
    }
}

fn getCmd(buf: []u8) ?[]const u8 {
    fmt.print("$ ", .{});
    const str = io.getStr(buf);

    if (str.len == 0)
        return null
    else
        return str;
}
