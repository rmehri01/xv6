//! A nicer, more zig-style interface to raw system calls.

const std = @import("std");

const syscall = @import("shared").syscall;

const ERR_VALUE = std.math.maxInt(u64);

extern fn mknodSys([*:0]const u8, u32, u32) u64;
extern fn openSys([*:0]const u8, u32) u64;
extern fn dupSys(u32) u64;
extern fn forkSys() u64;
extern fn exitSys(i32) noreturn;
extern fn waitSys(u64) u64;
extern fn writeSys(u32, [*]const u8, u64) u64;

comptime {
    for (@typeInfo(syscall.Num).@"enum".fields) |field| {
        asm (std.fmt.comptimePrint(
                \\ .global {s}Sys
                \\ {s}Sys:
                \\ li a7, {d}
                \\ ecall
                \\ ret
            , .{ field.name, field.name, field.value }));
    }
}

pub fn mknod(name: [:0]const u8, major: u32, minor: u32) !void {
    const ret = mknodSys(name.ptr, major, minor);
    if (ret == ERR_VALUE) {
        return error.SyscallFailed;
    }
}

pub fn open(name: [:0]const u8, mode: u32) !u32 {
    const ret = openSys(name.ptr, mode);
    if (ret == ERR_VALUE) {
        return error.SyscallFailed;
    }
    return @intCast(ret);
}

pub fn dup(fd: u32) !void {
    const ret = dupSys(fd);
    if (ret == ERR_VALUE) {
        return error.SyscallFailed;
    }
}

pub fn fork() !union(enum) { child, parent: u32 } {
    const ret = forkSys();
    if (ret == ERR_VALUE) {
        return error.SyscallFailed;
    }

    if (ret == 0) {
        return .child;
    } else {
        return .{ .parent = @intCast(ret) };
    }
}

pub fn exit(status: i32) noreturn {
    exitSys(status);
}

pub fn wait(status: ?*i32) !u32 {
    const ret = waitSys(if (status) |ptr| @intFromPtr(ptr) else 0);
    if (ret == ERR_VALUE) {
        return error.SyscallFailed;
    }

    return @intCast(ret);
}

pub fn write(fd: u32, buf: []const u8) !u64 {
    const ret = writeSys(fd, buf.ptr, buf.len);
    if (ret == ERR_VALUE) {
        return error.SyscallFailed;
    }
    return ret;
}
