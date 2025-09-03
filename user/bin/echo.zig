const std = @import("std");

const ulib = @import("ulib");

const stdout = &ulib.io.stdout;

pub fn main() !void {
    for (1.., std.os.argv[1..]) |i, arg| {
        stdout.print("{s}", .{arg});
        if (i == std.os.argv.len - 1) {
            stdout.println("", .{});
        } else {
            stdout.print(" ", .{});
        }
    }
}
