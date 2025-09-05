//! Test that fork fails gracefully.
//! Tiny executable so that the limit can be filling the proc table.

const std = @import("std");

const ulib = @import("ulib");
const syscall = ulib.syscall;

const stdout = &ulib.io.stdout;

const N = 1000;

pub fn main() !void {
    stdout.println("fork test", .{});

    var n: u64 = 0;
    while (n < N) : (n += 1) {
        const f = syscall.fork() catch break;
        if (f == .child) {
            syscall.exit(0);
        }
    }

    if (n == N) {
        stdout.println("fork claimed to work N times!", .{});
        syscall.exit(1);
    }

    while (n > 0) : (n -= 1) {
        _ = syscall.wait(null) catch {
            stdout.println("wait stopped early", .{});
            syscall.exit(1);
        };
    }

    if (syscall.wait(null)) |_| {
        stdout.println("wait got too many", .{});
        syscall.exit(1);
    } else |_| {}

    stdout.println("fork test OK", .{});
}
