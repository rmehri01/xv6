//! init: The initial user-level program

const std = @import("std");

const file = @import("shared").file;

const fmt = @import("fmt.zig");
const syscall = @import("syscall.zig");

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    _ = first_trace_addr;

    // TODO: println doesnt work here
    _ = syscall.write(2, msg) catch {};
    syscall.exit(1);
}

export fn _start() noreturn {
    // TODO: printf error?
    main() catch @panic("init panic");
}

fn main() !noreturn {
    const fd = syscall.open("console", file.OpenMode.READ_WRITE) catch value: {
        try syscall.mknod("console", file.CONSOLE, 0);
        break :value syscall.open("console", file.OpenMode.READ_WRITE) catch
            @panic("failed to open console node");
    };

    // stdout
    try syscall.dup(fd);
    // stderr
    try syscall.dup(fd);

    switch (try syscall.fork()) {
        .child => fmt.println("hello from child!", .{}),
        .parent => |child_pid| fmt.println(
            "hello from parent! child_pid={d}",
            .{child_pid},
        ),
    }

    while (true) {}
}
