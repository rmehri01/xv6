const std = @import("std");
const assert = std.debug.assert;

const shared = @import("shared");
const params = shared.params;

const console = @import("../console.zig");
const fs = @import("../fs.zig");
const log = @import("../fs/log.zig");
const proc = @import("../proc.zig");
const SpinLock = @import("../sync/SpinLock.zig");
const Pipe = @import("Pipe.zig");

const DevVTable = struct {
    read: *const fn (proc.EitherMem) u64,
    write: *const fn (proc.EitherMem) u64,
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
            off: usize,
        },
        device: struct {
            inode: *fs.Inode,
            major: u16,
        },
    },

    /// Write to this file.
    /// addr is a user virtual address.
    pub fn write(self: *@This(), addr: u64, len: u32) !u64 {
        if (!self.writable)
            return error.NotWritable;

        switch (self.ty) {
            .device => |dev| {
                if (dev.major >= params.NUM_DEV)
                    return error.InvalidDevice;
                const vtable = dev_vtables[dev.major] orelse
                    return error.InvalidDevice;
                return vtable.write(.{ .user = .{ .addr = addr, .len = len } });
            },
            else => @panic("file write"),
        }
    }

    /// Close this file. (Decrement ref count, close when reaches 0.)
    pub fn close(self: *@This()) void {
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
