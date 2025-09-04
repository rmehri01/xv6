const std = @import("std");

const file = @import("shared").file;
const ulib = @import("ulib");
const syscall = ulib.syscall;

const stdout = &ulib.io.stdout;
const stderr = &ulib.io.stderr;
var buf: [512]u8 = undefined;

pub fn main() !void {
    const argv = std.os.argv;
    if (argv.len == 1) {
        try wc(0, "");
    } else {
        var err = false;
        for (argv[1..]) |name| {
            const fd = syscall.open(name, file.OpenMode.READ_ONLY) catch {
                stderr.println("wc: cannot open {s}", .{name});
                err = true;
                continue;
            };
            defer syscall.close(fd) catch {};

            try wc(fd, name);
        }

        if (err) {
            syscall.exit(1);
        }
    }
}

fn wc(fd: u32, name: [*:0]const u8) !void {
    var lines: usize = 0;
    var words: usize = 0;
    var chars: usize = 0;

    var in_word = false;

    while (true) {
        const read = try syscall.read(fd, &buf);
        if (read == 0) {
            break;
        }

        for (buf[0..read]) |char| {
            chars += 1;

            if (char == '\n') {
                lines += 1;
            }

            if (std.ascii.isWhitespace(char)) {
                in_word = false;
            } else if (!in_word) {
                words += 1;
                in_word = true;
            }
        }
    }

    stdout.println("{d} {d} {d} {s}", .{ lines, words, chars, name });
}
