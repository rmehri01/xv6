//! init: The initial user-level program

const std = @import("std");

const syscall = @import("syscall.zig");
const file = @import("shared").file;

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
    _ = try syscall.write(fd, "hello from userspace!\n");

    while (true) {}
}
