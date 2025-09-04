const std = @import("std");

const ulib = @import("ulib");
const syscall = ulib.syscall;

const stderr = &ulib.io.stderr;

pub fn main() !void {
    const argv = std.os.argv;
    if (argv.len == 1) {
        stderr.println("usage: mkdir files...", .{});
        syscall.exit(1);
    }

    var err = false;
    for (argv[1..]) |path| {
        syscall.mkdir(path) catch {
            stderr.println("mkdir: {s} failed to create", .{path});
            err = true;
            continue;
        };
    }

    if (err) {
        syscall.exit(1);
    }
}
