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
const heap = @import("../heap.zig");
const proc = @import("../proc.zig");
const riscv = @import("../riscv.zig");
const syscall = @import("../syscall.zig");

pub fn mknod() !u64 {
    log.beginOp();
    defer log.endOp();

    var buf: [params.MAX_PATH:0]u8 = undefined;
    const path = try syscall.strArg(0, &buf);
    const major = syscall.intArg(1);
    const minor = syscall.intArg(2);

    const inode = try create(
        path,
        .{ .dev = .{ .major = @intCast(major), .minor = @intCast(minor) } },
    );
    inode.unlockPut();

    return 0;
}

pub fn open() !u64 {
    const allocator = heap.page_allocator;

    var buf: [params.MAX_PATH:0]u8 = undefined;
    const path = try syscall.strArg(0, &buf);
    const mode = syscall.intArg(1);

    log.beginOp();
    defer log.endOp();

    const inode = value: {
        if (mode & OpenMode.CREATE != 0) {
            @panic("todo create");
        } else {
            const inode = try fs.lookupPath(allocator, path);
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
        f.ty = .{
            .inode = .{
                .inode = inode,
                .off = 0,
            },
        };
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

pub fn link() !u64 {
    const allocator = heap.page_allocator;

    var old_buf: [params.MAX_PATH:0]u8 = undefined;
    const old = try syscall.strArg(0, &old_buf);

    var new_buf: [params.MAX_PATH:0]u8 = undefined;
    const new = try syscall.strArg(1, &new_buf);

    log.beginOp();
    defer log.endOp();

    const inode = try fs.lookupPath(allocator, old);
    inode.lock();
    errdefer inode.unlockPut();

    if (inode.dinode.type == @intFromEnum(defs.FileType.dir)) {
        return error.LinkDir;
    }

    inode.dinode.num_link += 1;
    inode.update();
    inode.unlock();
    errdefer {
        inode.lock();
        inode.dinode.num_link -= 1;
        inode.update();
    }

    const parent, const name = try fs.lookupParent(allocator, new);
    parent.lock();
    errdefer parent.unlockPut();

    if (parent.dev != inode.dev) {
        return error.LinkDifferentDevice;
    }
    try fs.linkInDir(allocator, parent, name, @intCast(inode.inum));

    parent.unlockPut();
    inode.put();
    return 0;
}

pub fn read() !u64 {
    _, const f = try fdArg(0);
    const addr = syscall.rawArg(1);
    const len = syscall.intArg(2);

    return try f.read(heap.page_allocator, addr, len);
}

pub fn write() !u64 {
    _, const f = try fdArg(0);
    const addr = syscall.rawArg(1);
    const len = syscall.intArg(2);

    return try f.write(addr, len);
}

pub fn fstat() !u64 {
    _, const f = try fdArg(0);
    const addr = syscall.rawArg(1);

    try f.stat(heap.page_allocator, addr);
    return 0;
}

pub fn close() !u64 {
    const fd, const f = try fdArg(0);

    const p = proc.myProc().?;
    p.private.open_files[fd] = null;

    f.close();
    return 0;
}

pub fn exec() !u64 {
    const allocator = heap.page_allocator;

    var buf: [params.MAX_PATH:0]u8 = undefined;
    const path = try syscall.strArg(0, &buf);
    const uargv = syscall.rawArg(1);

    var argv: [params.MAX_ARGS]?[:0]u8 = undefined;
    var i: u64 = 0;
    defer {
        for (0..i) |idx| {
            allocator.free(argv[idx].?);
        }
    }

    while (i < params.MAX_PATH) : (i += 1) {
        const uarg = try syscall.fetchAddr(uargv + @sizeOf(u64) * i);
        if (uarg == 0) {
            argv[i] = null;
            break;
        }

        // TODO: don't use the whole page for a small string
        argv[i] = try allocator.create([riscv.PAGE_SIZE - 1:0]u8);
        argv[i] = try syscall.fetchStr(argv[i].?, uarg);
    } else {
        return error.TooManyArgs;
    }

    return try syscall.kexec(path, &argv);
}

/// Common implementation for open with the create flag, mkdir, and mknod
/// since they all create files.
fn create(
    path: []const u8,
    ty: union(defs.FileType) {
        dir,
        file,
        dev: struct { major: u16, minor: u16 },
    },
) !*fs.Inode {
    const allocator = heap.page_allocator;
    const parent, const name = try fs.lookupParent(allocator, path);
    parent.lock();

    if (fs.lookupInDir(allocator, parent, name)) |i| {
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

    try fs.linkInDir(allocator, parent, name, @intCast(inode.inum));

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
fn fdArg(n: u3) !struct { u32, *file.File } {
    const fd = syscall.intArg(n);
    if (fd >= params.NUM_FILE_PER_PROC)
        return error.InvalidFd;

    const f = proc.myProc().?.private.open_files[fd] orelse
        return error.InvalidFd;
    return .{ fd, f };
}
