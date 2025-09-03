const std = @import("std");

const file = @import("shared").file;
const ulib = @import("ulib");
const syscall = ulib.syscall;

const stderr = &ulib.io.stderr;
var buf: [512]u8 = undefined;

pub fn main() !void {
    const argv = std.os.argv;

    if (argv.len == 1) {
        try cat(0);
    } else {
        for (argv[1..]) |name| {
            const fd = syscall.open(std.mem.span(name), file.OpenMode.READ_ONLY) catch {
                stderr.println("cat: cannot open {s}", .{name});
                continue;
            };
            defer syscall.close(fd) catch {};

            try cat(fd);
        }
    }
}

fn cat(fd: u32) !void {
    while (true) {
        const read = try syscall.read(fd, &buf);
        if (read == 0) {
            break;
        }

        const written = try syscall.write(1, buf[0..read]);
        if (written != read) {
            return error.CatWriteError;
        }
    }
}
