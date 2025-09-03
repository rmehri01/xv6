const std = @import("std");

const ulib = @import("ulib");
const syscall = ulib.syscall;
const uprog = @import("uprog");

const stderr = &ulib.io.stderr;

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    _ = first_trace_addr;

    stderr.println("user panic: {s}", .{msg});
    syscall.exit(1);
}

export fn _start(argc: usize, argv: [*][*:0]u8) noreturn {
    std.os.argv = argv[0..argc];
    uprog.main() catch |err| stderr.println("user program error: {}", .{err});
    syscall.exit(0);
}
