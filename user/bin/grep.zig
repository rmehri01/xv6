//! Simple grep. Only supports ^ . * $ operators.

const std = @import("std");

const file = @import("shared").file;
const ulib = @import("ulib");
const syscall = ulib.syscall;

const stdout = &ulib.io.stdout;
const stderr = &ulib.io.stderr;

pub fn main() !void {
    const argv = std.os.argv;
    if (argv.len == 1) {
        stderr.println("usage: grep pattern [file ...]", .{});
        syscall.exit(1);
    }

    const pattern = argv[1];
    if (argv.len == 2) {
        try grep(pattern, 0);
    } else {
        var err = false;
        for (argv[2..]) |path| {
            const fd = syscall.open(path, file.OpenMode.READ_ONLY) catch {
                stderr.println("grep: cannot open {s}", .{path});
                err = true;
                continue;
            };
            defer syscall.close(fd) catch {};

            try grep(pattern, fd);
        }

        if (err) {
            syscall.exit(1);
        }
    }
}

fn grep(pattern: [*:0]const u8, fd: u32) !void {
    const allocator = ulib.mem.allocator;
    var buf = try std.ArrayList(u8).initCapacity(allocator, 1024);
    defer buf.deinit(allocator);

    while (true) {
        const read = try syscall.read(fd, buf.unusedCapacitySlice());
        if (read == 0) {
            if (buf.items.len != 0 and match(pattern, buf.items)) {
                stdout.println("{s}", .{buf.items});
            }
            break;
        }
        buf.items.len += read;

        var consumed: u64 = 0;
        while (std.mem.indexOfScalar(u8, buf.items[consumed..], '\n')) |idx| {
            const line = buf.items[consumed..][0..idx];
            if (match(pattern, line)) {
                stdout.println("{s}", .{line});
            }
            consumed += idx + 1;
        }

        if (consumed == 0) {
            try buf.ensureTotalCapacity(allocator, buf.capacity * 2);
        } else {
            @memmove(buf.items.ptr, buf.items[consumed..buf.items.len]);
            buf.items.len -= consumed;
        }
    }
}

/// Regexp matcher from Kernighan & Pike,
/// The Practice of Programming, Chapter 9, or
/// https://www.cs.princeton.edu/courses/archive/spr09/cos333/beautiful.html
fn match(re: [*:0]const u8, text: []const u8) bool {
    if (re[0] == '^')
        return matchHere(re[1..], text);

    // must look at empty string
    var t = text;
    while (true) : (t = t[1..]) {
        if (matchHere(re, t)) {
            return true;
        }
        if (t.len == 0) {
            break;
        }
    }

    return false;
}

/// Search for re at beginning of text.
fn matchHere(re: [*:0]const u8, text: []const u8) bool {
    if (re[0] == 0)
        return true;
    if (re[1] == '*')
        return matchStar(re[0], re[2..], text);
    if (re[0] == '$' and re[1] == 0)
        return text.len == 0;
    if (text.len != 0 and (re[0] == '.' or re[0] == text[0]))
        return matchHere(re[1..], text[1..]);
    return false;
}

// Search for c*re at beginning of text.
fn matchStar(c: u8, re: [*:0]const u8, text: []const u8) bool {
    var t = text;
    while (true) : (t = t[1..]) {
        // a * matches zero or more instances
        if (matchHere(re, t))
            return true;
        if (t.len == 0 or (t[0] != c and c != '.')) {
            break;
        }
    }

    return false;
}
