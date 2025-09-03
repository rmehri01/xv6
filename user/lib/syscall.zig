//! A nicer, more zig-style interface to raw system calls.

const std = @import("std");

const params = @import("shared").params;
const syscall = @import("shared").syscall;

const mem = @import("mem.zig");

const ERR_VALUE = std.math.maxInt(u64);

extern fn mknodSys([*:0]const u8, u32, u32) u64;
extern fn openSys([*:0]const u8, u32) u64;
extern fn dupSys(u32) u64;
extern fn readSys(u32, [*]const u8, u64) u64;
extern fn writeSys(u32, [*]const u8, u64) u64;
extern fn closeSys(u32) u64;
extern fn forkSys() u64;
extern fn execSys([*:0]const u8, [*]const ?[*:0]const u8) u64;
extern fn sbrkSys(u32, u32) u64;
extern fn exitSys(i32) noreturn;
extern fn waitSys(u64) u64;

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

pub fn mknod(name: []const u8, major: u32, minor: u32) !void {
    var buf: [params.MAX_PATH]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buf);
    const path = try fixed.allocator().dupeZ(u8, name);

    const ret = mknodSys(path.ptr, major, minor);
    if (ret == ERR_VALUE) {
        return error.SyscallFailed;
    }
}

pub fn open(name: []const u8, mode: u32) !u32 {
    var buf: [params.MAX_PATH]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buf);
    const path = try fixed.allocator().dupeZ(u8, name);

    const ret = openSys(path.ptr, mode);
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

pub fn read(fd: u32, buf: []u8) !u64 {
    const ret = readSys(fd, buf.ptr, buf.len);
    if (ret == ERR_VALUE) {
        return error.SyscallFailed;
    }
    return ret;
}

pub fn write(fd: u32, buf: []const u8) !u64 {
    const ret = writeSys(fd, buf.ptr, buf.len);
    if (ret == ERR_VALUE) {
        return error.SyscallFailed;
    }
    return ret;
}

pub fn close(fd: u32) !void {
    const ret = closeSys(fd);
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

pub fn exec(path: []const u8, argv: []const []const u8) !noreturn {
    // most of the time we can just use the stack but we fallback
    // to the heap if the path/args are too large
    var fallback = std.heap.stackFallback(128, mem.allocator);
    var arena = std.heap.ArenaAllocator.init(fallback.get());
    defer arena.deinit();

    const allocator = arena.allocator();
    const pathZ = try allocator.dupeZ(u8, path);
    var argvZ = try allocator.alloc(?[*:0]u8, argv.len + 1);
    for (0.., argv) |i, arg| {
        argvZ[i] = try allocator.dupeZ(u8, arg);
    }
    argvZ[argv.len] = null;

    const ret = execSys(pathZ.ptr, argvZ.ptr);
    if (ret == ERR_VALUE) {
        return error.SyscallFailed;
    } else {
        @panic("returned from exec with non-error value");
    }
}

pub fn sbrk(bytes: u32, ty: syscall.SbrkType) !u64 {
    const ret = sbrkSys(bytes, @intFromEnum(ty));
    if (ret == ERR_VALUE) {
        return error.SyscallFailed;
    }
    return ret;
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
