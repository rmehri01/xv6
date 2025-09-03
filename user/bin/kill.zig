const std = @import("std");

const ulib = @import("ulib");
const syscall = ulib.syscall;

const stderr = &ulib.io.stderr;

pub fn main() !void {
    const argv = std.os.argv;
    if (argv.len < 2) {
        stderr.println("usage: kill pid...", .{});
        syscall.exit(1);
    }

    var err = false;
    for (argv[1..]) |pid_str| {
        const pid = std.fmt.parseInt(u32, std.mem.span(pid_str), 10) catch {
            stderr.println("kill: invalid pid", .{});
            err = true;
            continue;
        };
        syscall.kill(pid) catch {
            stderr.println("kill: failed", .{});
            err = true;
            continue;
        };
    }

    if (err) {
        syscall.exit(1);
    }
}
