const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const shared = @import("shared");
const params = shared.params;
const defs = shared.fs;

const console = @import("../console.zig");
const fs = @import("../fs.zig");
const log = @import("../fs/log.zig");
const proc = @import("../proc.zig");
const SpinLock = @import("../sync/SpinLock.zig");
const Pipe = @import("Pipe.zig");

const ReadError = error{ReadFailed};
const WriteError = error{ReadFailed};

const DevVTable = struct {
    read: *const fn (proc.EitherMem) ReadError!u64,
    write: *const fn (proc.EitherMem) WriteError!u64,
};

/// Map major device number to device functions.
var dev_vtables: [params.NUM_DEV]?DevVTable = undefined;

var ftable: struct {
    mutex: SpinLock,
    files: [params.NUM_FILE]File,
} = .{
    .mutex = .{},
    .files = .{std.mem.zeroInit(File, .{
        .ty = .none,
    })} ** params.NUM_FILE,
};

pub fn init() void {
    // connect read and write system calls
    // to console.read and console.write.
    dev_vtables[shared.file.CONSOLE] = .{
        .read = console.read,
        .write = console.write,
    };
}

/// Allocate a file structure.
pub fn alloc() !*File {
    ftable.mutex.lock();
    defer ftable.mutex.unlock();

    for (&ftable.files) |*file| {
        if (file.ref_count == 0) {
            file.ref_count = 1;
            return file;
        }
    } else {
        return error.OutOfFiles;
    }
}

pub const File = struct {
    ref_count: u32,
    readable: bool,
    writable: bool,
    ty: union(enum) {
        none,
        pipe: *Pipe,
        inode: struct {
            inode: *fs.Inode,
            off: u32,
        },
        device: struct {
            inode: *fs.Inode,
            major: u16,
        },
    },

    /// Increment ref count for this file.
    pub fn dup(self: *File) *File {
        ftable.mutex.lock();
        defer ftable.mutex.unlock();

        assert(self.ref_count != 0);
        self.ref_count += 1;
        return self;
    }

    /// Read from this file.
    /// addr is a user virtual address.
    pub fn read(self: *File, allocator: Allocator, addr: u64, len: u32) !u64 {
        if (!self.readable)
            return error.NotReadable;

        switch (self.ty) {
            .device => |dev| {
                if (dev.major >= params.NUM_DEV)
                    return error.InvalidDevice;
                const vtable = dev_vtables[dev.major] orelse
                    return error.InvalidDevice;
                return try vtable.read(
                    .{ .user = .{ .addr = addr, .len = len } },
                );
            },
            .inode => |*inode| {
                inode.inode.lock();
                defer inode.inode.unlock();

                const bytes_read = try inode.inode.read(
                    allocator,
                    .{ .user = .{ .addr = addr, .len = len } },
                    inode.off,
                );
                inode.off += bytes_read;
                return bytes_read;
            },
            else => @panic("file read"),
        }
    }

    /// Write to this file.
    /// addr is a user virtual address.
    pub fn write(self: *File, allocator: Allocator, addr: u64, len: u32) !u64 {
        if (!self.writable)
            return error.NotWritable;

        switch (self.ty) {
            .device => |dev| {
                if (dev.major >= params.NUM_DEV)
                    return error.InvalidDevice;
                const vtable = dev_vtables[dev.major] orelse
                    return error.InvalidDevice;
                return try vtable.write(
                    .{ .user = .{ .addr = addr, .len = len } },
                );
            },
            .inode => |*inode| {
                // write a few blocks at a time to avoid exceeding
                // the maximum log transaction size, including
                // i-node, indirect block, allocation blocks,
                // and 2 blocks of slop for non-aligned writes.
                const max = ((params.MAX_OP_BLOCKS - 1 - 1 - 2) / 2) * defs.BLOCK_SIZE;

                var written: u64 = 0;
                while (written < len) {
                    var bytes_to_write = len - written;
                    if (bytes_to_write > max)
                        bytes_to_write = max;

                    log.beginOp();
                    defer log.endOp();

                    inode.inode.lock();
                    defer inode.inode.unlock();

                    const wrote = try inode.inode.write(
                        allocator,
                        .{
                            .user = .{
                                .addr = addr + written,
                                .len = bytes_to_write,
                            },
                        },
                        inode.off,
                    );
                    inode.off += wrote;
                    written += wrote;

                    if (wrote != bytes_to_write) {
                        return error.WriteFailed;
                    }
                } else {
                    assert(written == len);
                    return written;
                }
            },
            else => @panic("file write"),
        }
    }

    /// Get metadata about this file.
    /// addr is a user virtual address, pointing to a struct Stat.
    pub fn stat(self: *File, allocator: Allocator, addr: u64) !void {
        const p = proc.myProc().?;
        switch (self.ty) {
            inline .inode, .device => |data| {
                const inode = data.inode;

                inode.lock();
                const st = inode.stat();
                inode.unlock();

                try p.private.page_table.?.copyOut(
                    allocator,
                    addr,
                    std.mem.asBytes(&st),
                );
            },
            else => return error.StatFailed,
        }
    }

    /// Close this file. (Decrement ref count, close when reaches 0.)
    pub fn close(self: *File) void {
        const file = value: {
            ftable.mutex.lock();
            defer ftable.mutex.unlock();

            assert(self.ref_count != 0);
            self.ref_count -= 1;
            if (self.ref_count != 0) {
                return;
            }

            const copy = self.*;
            self.ty = .none;
            break :value copy;
        };

        switch (file.ty) {
            .pipe => |pipe| pipe.close(),
            inline .inode, .device => |data| {
                log.beginOp();
                defer log.endOp();

                data.inode.put();
            },
            else => unreachable,
        }
    }
};
