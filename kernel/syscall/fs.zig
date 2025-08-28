//! File-system related syscall implementations.
//! Mostly argument checking, since we don't trust
//! user code, and calls into fs/file.zig and fs.zig.

const std = @import("std");

const fs = @import("../fs.zig");
const defs = @import("../fs/defs.zig");
const log = @import("../fs/log.zig");
const params = @import("../params.zig");
const syscall = @import("../syscall.zig");

pub fn mknod() u64 {
    log.beginOp();
    defer log.endOp();

    var path: [params.MAX_PATH:0]u8 = undefined;
    const path_len = syscall.strArg(0, &path) catch
        return std.math.maxInt(u64);
    const major = syscall.intArg(1);
    const minor = syscall.intArg(2);

    const inode = create(
        path[0..path_len],
        .{ .dev = .{ .major = @intCast(major), .minor = @intCast(minor) } },
    ) catch return std.math.maxInt(u64);
    inode.unlockPut();

    return 0;
}

fn create(
    path: []const u8,
    ty: union(defs.FileType) {
        dir,
        file,
        dev: struct { major: u16, minor: u16 },
    },
) !*fs.Inode {
    const parent, const name = try fs.lookupParent(path);
    parent.lock();

    if (fs.lookupDir(parent, name)) |_| {
        @panic("todo");
    }

    defer parent.unlockPut();

    const inode = try fs.allocInode(parent.dev, ty);
    inode.lock();
    errdefer {
        // something went wrong. de-allocate inode.
        inode.dinode.num_link = 0;
        inode.update();
        inode.unlockPut();
    }

    switch (ty) {
        .dev => |d| {
            inode.dinode.major = d.major;
            inode.dinode.minor = d.minor;
        },
        else => {},
    }
    inode.dinode.num_link = 1;
    inode.update();

    // TODO: handle if ty == .dir

    try fs.linkDir(parent, name, @intCast(inode.inum));

    // TODO: handle if ty == .dir

    return inode;
}
