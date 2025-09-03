const std = @import("std");

const ulib = @import("ulib");
const syscall = ulib.syscall;

const stderr = &ulib.io.stderr;

pub fn main() !void {
    const argv = std.os.argv;
    if (argv.len != 3) {
        stderr.println("Usage: ln old new", .{});
        syscall.exit(1);
    }

    syscall.link(argv[1], argv[2]) catch {
        stderr.println("link {s} {s} failed", .{ argv[1], argv[2] });
        syscall.exit(1);
    };
}
