const std = @import("std");
const assert = std.debug.assert;

const file = @import("shared").file;
const fs = @import("shared").fs;
const ulib = @import("ulib");
const syscall = ulib.syscall;

const stdout = &ulib.io.stdout;
const stderr = &ulib.io.stderr;
var buf: [512]u8 = undefined;

pub fn main() !void {
    const argv = std.os.argv;
    if (argv.len == 1) {
        try ls(".");
    } else {
        var err = false;
        for (argv[1..]) |name| {
            ls(name) catch {
                err = true;
                continue;
            };
        }

        if (err) {
            syscall.exit(1);
        }
    }
}

fn ls(path: [*:0]const u8) !void {
    const fd = syscall.open(path, file.OpenMode.READ_ONLY) catch |err| {
        stderr.println("ls: cannot open {s}", .{path});
        return err;
    };
    defer syscall.close(fd) catch {};

    const meta = try syscall.fstat(fd);
    switch (@as(fs.FileType, @enumFromInt(meta.type))) {
        .file, .dev => stdout.println(
            "{s: <14} {d} {d} {d}",
            .{ path, meta.type, meta.inum, meta.size },
        ),
        .dir => while (true) {
            var dirent: fs.DirEnt = undefined;
            const read = try syscall.read(fd, std.mem.asBytes(&dirent));
            if (read == 0) {
                break;
            }
            assert(read == @sizeOf(fs.DirEnt));

            const name = std.mem.sliceTo(&dirent.name, 0);
            const stat = try syscall.stat(name);
            stdout.println(
                "{s: <14} {d} {d} {d}",
                .{ name, stat.type, stat.inum, stat.size },
            );
        },
    }
}
