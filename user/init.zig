//! init: The initial user-level program

const std = @import("std");

const file = @import("shared").file;

const fmt = @import("fmt.zig");
const syscall = @import("syscall.zig");

export fn _start() void {
    // TODO: printf error?
    main() catch @panic("init panic");
}

fn main() !void {
    const fd = syscall.open("console", file.OpenMode.READ_WRITE) catch value: {
        try syscall.mknod("console", file.CONSOLE, 0);
        break :value syscall.open("console", file.OpenMode.READ_WRITE) catch
            @panic("failed to open console node");
    };

    // stdout
    try syscall.dup(fd);
    // stderr
    try syscall.dup(fd);

    fmt.println("hello from userspace!", .{});

    while (true) {}
}
