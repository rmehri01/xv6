//! Create an orphaned file and check if the next run recovers it.

const std = @import("std");

const OpenMode = @import("shared").file.OpenMode;
const ulib = @import("ulib");
const syscall = ulib.syscall;

const stderr = &ulib.io.stderr;

pub fn main() !void {
    const name = "file0";

    _ = try syscall.open(name, OpenMode.CREATE | OpenMode.WRITE_ONLY);
    _ = try syscall.stat(name);

    try syscall.unlink(name);
    if (syscall.open(name, OpenMode.READ_ONLY)) |_| {
        stderr.println("open should have failed", .{});
        syscall.exit(1);
    } else |_| {}

    stderr.println("wait for kill and reclaim", .{});
    while (true) {
        try syscall.pause(1000);
    }
}
