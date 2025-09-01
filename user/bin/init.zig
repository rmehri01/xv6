//! init: The initial user-level program

const std = @import("std");

const file = @import("shared").file;
const ulib = @import("ulib");
const fmt = ulib.fmt;
const syscall = ulib.syscall;

pub fn main() !noreturn {
    const fd = syscall.open("console", file.OpenMode.READ_WRITE) catch value: {
        try syscall.mknod("console", file.CONSOLE, 0);
        break :value syscall.open("console", file.OpenMode.READ_WRITE) catch
            @panic("failed to open console node");
    };

    // stdout
    try syscall.dup(fd);
    // stderr
    try syscall.dup(fd);

    while (true) {
        fmt.println("init: starting sh", .{});
        switch (try syscall.fork()) {
            .child => {
                fmt.println("hello from child!", .{});
                try syscall.exec("/sh", &.{ "/sh", null });
            },
            .parent => |child_pid| while (true) {
                // this call to wait() returns if the shell exits,
                // or if a parentless process exits.
                const wait_pid = try syscall.wait(null);
                if (wait_pid == child_pid) {
                    // the shell exited; restart it.
                    break;
                } else {
                    // it was a parentless process; do nothing.
                }
            },
        }
    }
}
