const std = @import("std");

const ulib = @import("ulib");
const syscall = ulib.syscall;

const stderr = &ulib.io.stderr;

pub fn main() !void {
    const argv = std.os.argv;
    if (argv.len == 1) {
        stderr.println("usage: rm files...", .{});
        syscall.exit(1);
    } else {
        var err = false;
        for (argv[1..]) |path| {
            syscall.unlink(path) catch {
                stderr.println("rm: {s} failed to delete", .{path});
                err = true;
                continue;
            };
        }

        if (err) {
            syscall.exit(1);
        }
    }
}
