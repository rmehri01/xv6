const std = @import("std");

const ulib = @import("ulib");
const fmt = ulib.fmt;

pub fn main() !void {
    for (1.., std.os.argv[1..]) |i, arg| {
        fmt.print("{s}", .{arg});
        if (i == std.os.argv.len - 1) {
            fmt.println("", .{});
        } else {
            fmt.print(" ", .{});
        }
    }
}
