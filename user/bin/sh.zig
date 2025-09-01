const std = @import("std");

const ulib = @import("ulib");
const fmt = ulib.fmt;
const syscall = ulib.syscall;

pub fn main() !void {
    fmt.println("hello from exec! {x} {any}", .{ std.os.argv.len, std.os.argv.ptr });
    syscall.exit(0);
}
