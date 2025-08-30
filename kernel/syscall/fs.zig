//! File-system related syscall implementations.
//! Mostly argument checking, since we don't trust
//! user code, and calls into fs/file.zig and fs.zig.

const shared = @import("shared");
const defs = shared.fs;
const params = shared.params;
const OpenMode = shared.file.OpenMode;

const fs = @import("../fs.zig");
const file = @import("../fs/file.zig");
const log = @import("../fs/log.zig");
const proc = @import("../proc.zig");
const syscall = @import("../syscall.zig");

pub fn mknod() !u64 {
    log.beginOp();
    defer log.endOp();

    var path: [params.MAX_PATH:0]u8 = undefined;
    const path_len = try syscall.strArg(0, &path);
    const major = syscall.intArg(1);
    const minor = syscall.intArg(2);

    const inode = try create(
        path[0..path_len],
        .{ .dev = .{ .major = @intCast(major), .minor = @intCast(minor) } },
    );
    inode.unlockPut();

    return 0;
}

pub fn open() !u64 {
    var path: [params.MAX_PATH:0]u8 = undefined;
    const path_len = try syscall.strArg(0, &path);
    const mode = syscall.intArg(1);

    log.beginOp();
    defer log.endOp();

    const inode = value: {
        if (mode & OpenMode.CREATE != 0) {
            @panic("todo create");
        } else {
            const inode = try fs.lookupPath(path[0..path_len]);
            inode.lock();

            if (inode.dinode.type == @intFromEnum(defs.FileType.dir) and
                mode != OpenMode.READ_ONLY)
            {
                inode.unlockPut();
                return error.InvalidMode;
            }

            break :value inode;
        }
    };
    errdefer inode.unlockPut();

    if (inode.dinode.type == @intFromEnum(defs.FileType.dev) and
        (inode.dinode.major < 0 or inode.dinode.major >= params.NUM_DEV))
    {
        return error.InvalidDevice;
    }

    const f = try file.alloc();
    errdefer f.close();

    const fd = try allocFd(f);
    if (inode.dinode.type == @intFromEnum(defs.FileType.dev)) {
        f.ty = .{
            .device = .{
                .inode = inode,
                .major = inode.dinode.major,
            },
        };
    } else {
        @panic("todo open file");
    }
    f.readable = mode & OpenMode.WRITE_ONLY == 0;
    f.writable = (mode & OpenMode.WRITE_ONLY != 0) or
        (mode & OpenMode.READ_WRITE != 0);

    // TODO: handle trunc

    inode.unlock();
    return fd;
}

pub fn dup() !u64 {
    _, const f = try fdArg(0);
    const fd = try allocFd(f);
    _ = f.dup();
    return fd;
}

pub fn write() !u64 {
    _, const f = try fdArg(0);
    const addr = syscall.rawArg(1);
    const len = syscall.intArg(2);

    return try f.write(addr, len);
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

    if (fs.lookupInDir(parent, name)) |i| {
        parent.unlockPut();

        const inode = i.@"0";
        inode.lock();

        if (ty == .file and
            (inode.dinode.type == @intFromEnum(defs.FileType.file) or
                inode.dinode.type == @intFromEnum(defs.FileType.dev)))
        {
            return inode;
        } else {
            inode.unlockPut();
            return error.CreateExistingFile;
        }
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

    try fs.linkInDir(parent, name, @intCast(inode.inum));

    // TODO: handle if ty == .dir

    return inode;
}

/// Allocate a file descriptor for the given file.
/// Takes over file reference from caller on success.
fn allocFd(f: *file.File) !u32 {
    const p = proc.myProc().?;
    for (0.., p.private.open_files) |fd, maybe_file| {
        if (maybe_file == null) {
            p.private.open_files[fd] = f;
            return @intCast(fd);
        }
    } else {
        return error.OutOfFiles;
    }
}

/// Fetch the nth word-sized system call argument as a file descriptor
/// and return both the descriptor and the corresponding struct file.
fn fdArg(n: u32) !struct { u32, *file.File } {
    const fd = syscall.intArg(n);
    if (fd >= params.NUM_FILE_PER_PROC)
        return error.InvalidFd;

    const f = proc.myProc().?.private.open_files[fd] orelse
        return error.InvalidFd;
    return .{ fd, f };
}
