//! Shell.

const std = @import("std");

const file = @import("shared").file;
const ulib = @import("ulib");
const io = ulib.io;
const syscall = ulib.syscall;

pub fn main() !void {
    var buf: [100]u8 = undefined;

    // Read and run input commands.
    while (getCmd(&buf)) |cmd| {
        var parts = std.mem.tokenizeAny(u8, cmd, " \t\n");
        if (parts.next()) |first| {
            switch (try syscall.fork()) {
                .child => {
                    // TODO: more elaborate running of commands
                    var args = try std.ArrayList([]const u8).initCapacity(
                        ulib.mem.allocator,
                        8,
                    );
                    try args.append(ulib.mem.allocator, first);
                    while (parts.next()) |part| {
                        try args.append(ulib.mem.allocator, part);
                    }
                    _ = try syscall.exec(first, try args.toOwnedSlice(ulib.mem.allocator));
                },
                .parent => _ = try syscall.wait(null),
            }
        } else {
            continue;
        }
    }
}

fn getCmd(buf: []u8) ?[]const u8 {
    io.stderr.print("$ ", .{});
    const str = io.getStr(buf);

    if (str.len == 0)
        return null
    else
        return str;
}
