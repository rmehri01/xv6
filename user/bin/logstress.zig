//! Stress xv6 logging system by having several processes writing
//! concurrently to their own file (e.g., logstress f1 f2 f3 f4)

const std = @import("std");
const assert = std.debug.assert;

const OpenMode = @import("shared").file.OpenMode;
const ulib = @import("ulib");
const syscall = ulib.syscall;

const stderr = &ulib.io.stderr;

const N = 250;
var buf: [500]u8 = undefined;

pub fn main() !void {
    for (1.., std.os.argv[1..]) |i, path| {
        if (try syscall.fork() == .child) {
            const fd = try syscall.open(
                path,
                OpenMode.CREATE | OpenMode.READ_WRITE,
            );

            @memset(&buf, '0' + @as(u8, @intCast(i)));
            for (0..N) |_| {
                const written = try syscall.write(fd, &buf);
                assert(written == buf.len);
            }

            syscall.exit(0);
        }
    }

    for (1..std.os.argv.len) |_| {
        var status: i32 = undefined;
        _ = try syscall.wait(&status);

        if (status != 0) {
            stderr.println("non-zero exit code from child: {d}", .{status});
            syscall.exit(status);
        }
    }
}
