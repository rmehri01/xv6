//! Create an orphaned directory and check if the next run recovers it.

const std = @import("std");

const ulib = @import("ulib");
const syscall = ulib.syscall;

const stderr = &ulib.io.stderr;

pub fn main() !void {
    try syscall.mkdir("dd");
    try syscall.chdir("dd");
    try syscall.unlink("../dd");

    stderr.println("wait for kill and reclaim", .{});
    while (true) {
        try syscall.pause(1000);
    }
}
