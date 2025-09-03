//! File system implementation. Five layers:
//!   + Blocks: allocator for raw disk blocks.
//!   + Log: crash recovery for multi-step updates.
//!   + Files: inode allocator, reading, writing, metadata.
//!   + Directories: inode with special contents (list of other inodes!)
//!   + Names: paths like /usr/foo/xv6/fs.zig for convenient naming.
//!
//! This file contains the low-level file system manipulation
//! routines. The (higher-level) system call implementations
//! are in syscall/fs.zig.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const defs = @import("shared").fs;
const params = @import("shared").params;

const fmt = @import("fmt.zig");
const bcache = @import("fs/bcache.zig");
const log = @import("fs/log.zig");
const proc = @import("proc.zig");
const SleepLock = @import("sync/SleepLock.zig");
const SpinLock = @import("sync/SpinLock.zig");

/// There should be one superblock per disk device, but we run with only one device.
var sb: defs.SuperBlock = undefined;

/// Initialize the file system.
pub fn init(dev: u32) void {
    initSuperBlock(dev);
    log.init(dev, &sb);
    reclaimInodes(dev);
}

/// Read the super block.
fn initSuperBlock(dev: u32) void {
    const buf = bcache.read(dev, 1);
    defer buf.release();

    sb = std.mem.bytesToValue(defs.SuperBlock, &buf.data);
    assert(sb.magic == defs.FS_MAGIC);
}

// Paths.

/// Look up and return the inode for a path name.
/// Must be called inside a transaction since it calls put().
pub fn lookupPath(allocator: Allocator, path: []const u8) !*Inode {
    const inode, _ = try lookupPathImpl(allocator, path, false);
    return inode;
}

/// Look up and return the parent inode and last path name for a path name.
/// Must be called inside a transaction since it calls put().
pub fn lookupParent(
    allocator: Allocator,
    path: []const u8,
) !struct { *Inode, []const u8 } {
    return try lookupPathImpl(allocator, path, true);
}

fn lookupPathImpl(
    allocator: Allocator,
    path: []const u8,
    parent: bool,
) !struct { *Inode, []const u8 } {
    var inode = if (std.mem.startsWith(u8, path, "/"))
        getInode(params.ROOT_DEV, defs.ROOT_INUM)
    else
        proc.myProc().?.private.cwd.?.dup();

    // iterate over the path components from the root
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |component| {
        inode.lock();
        errdefer inode.unlockPut();

        if (inode.dinode.type != @intFromEnum(defs.FileType.dir))
            return error.NotADir;

        if (parent and it.peek() == null) {
            // Stop one level early.
            inode.unlock();
            return .{ inode, component };
        }

        const next, _ = lookupInDir(allocator, inode, component) orelse
            return error.InvalidDirectory;
        inode.unlockPut();
        inode = next;
    }

    if (parent) {
        inode.put();
        return error.NoParent;
    }

    return .{ inode, undefined };
}

// Directories.

/// Look for a directory entry in a directory.
/// If found, return the corresponding inode and it's byte offset.
pub fn lookupInDir(
    allocator: Allocator,
    dir_inode: *Inode,
    name: []const u8,
) ?struct { *Inode, u32 } {
    assert(dir_inode.dinode.type == @intFromEnum(defs.FileType.dir));

    var off: u32 = 0;
    while (off < dir_inode.dinode.size) : (off += @sizeOf(defs.DirEnt)) {
        var dirent: defs.DirEnt = undefined;
        const read = dir_inode.read(
            allocator,
            .{ .kernel = std.mem.asBytes(&dirent) },
            off,
        ) catch |err| std.debug.panic("failed to read directory entry: {}", .{err});
        assert(read == @sizeOf(defs.DirEnt));

        if (dirent.inum == 0)
            continue;

        if (std.mem.eql(
            u8,
            std.mem.span(@as([*:0]const u8, @ptrCast(&dirent.name))),
            name,
        )) {
            // entry matches path element
            return .{ getInode(dir_inode.dev, dirent.inum), off };
        }
    } else {
        return null;
    }
}

/// Write a new directory entry (name, inum) into the directory.
pub fn linkInDir(
    allocator: Allocator,
    dir_inode: *Inode,
    name: []const u8,
    inum: u16,
) !void {
    assert(dir_inode.dinode.type == @intFromEnum(defs.FileType.dir));

    // Check that name is not present.
    if (lookupInDir(allocator, dir_inode, name)) |inode| {
        inode.@"0".put();
        return error.DirEntAlreadyExists;
    }

    // Look for an empty dirent.
    var off: u32 = 0;
    while (off < dir_inode.dinode.size) : (off += @sizeOf(defs.DirEnt)) {
        var dirent: defs.DirEnt = undefined;
        const read = dir_inode.read(
            allocator,
            .{ .kernel = std.mem.asBytes(&dirent) },
            off,
        ) catch |err| std.debug.panic("failed to read directory entry: {}", .{err});
        assert(read == @sizeOf(defs.DirEnt));

        if (dirent.inum == 0) {
            break;
        }
    }

    var new_dirent: defs.DirEnt = .{
        .inum = inum,
        .name = [_]u8{0} ** defs.DIR_NAME_SIZE,
    };
    @memcpy(new_dirent.name[0..name.len], name);
    const written = try dir_inode.write(
        allocator,
        .{ .kernel = std.mem.asBytes(&new_dirent) },
        off,
    );
    assert(written == @sizeOf(defs.DirEnt));
}

// Inodes.
//
// An inode describes a single unnamed file.
// The inode disk structure holds metadata: the file's type,
// its size, the number of links referring to it, and the
// list of blocks holding the file's content.
//
// The inodes are laid out sequentially on disk at block
// sb.inode_start. Each inode has a number, indicating its
// position on the disk.
//
// The kernel keeps a table of in-use inodes in memory
// to provide a place for synchronizing access
// to inodes used by multiple processes. The in-memory
// inodes include book-keeping information that is
// not stored on disk: inode.ref_count and inode.valid.
//
// An inode and its in-memory representation go through a
// sequence of states before they can be used by the
// rest of the file system code.
//
// * Allocation: an inode is allocated if its type (on disk)
//   is non-zero. allocInode() allocates, and inode.put() frees if
//   the reference and link counts have fallen to zero.
//
// * Referencing in table: an entry in the inode table is free if
//   inode.ref_count is zero. Otherwise inode.ref_count tracks
//   the number of in-memory pointers to the entry (open
//   files and current directories). getInode() finds or
//   creates a table entry and increments its ref; inode.put()
//   decrements ref.
//
// * Valid: the information (type, size, &c) in an inode
//   table entry is only correct when inode.valid is true.
//   inode.lock() reads the inode from
//   the disk and sets inode.valid, while inode.put() clears
//   inode.valid if inode.ref_count has fallen to zero.
//
// * Locked: file system code may only examine and modify
//   the information in an inode and its content if it
//   has first locked the inode.
//
// Thus a typical sequence is:
//
// ```zig
//   const inode = getInode(dev, inum);
//   inode.lock();
//   defer inode.unlockPut();
//
//   // ... examine and modify inode ...
// ```
//
// inode.lock() is separate from getInode() so that system calls can
// get a long-term reference to an inode (as for an open file)
// and only lock it for short periods (e.g., in read()).
// The separation also helps avoid deadlock and races during
// pathname lookup. getInode() increments inode.ref_count so that the inode
// stays in the table and pointers to it remain valid.
//
// Many internal file system functions expect the caller to
// have locked the inodes involved; this lets callers create
// multi-step atomic operations.
//
// The itable.mutex spin-lock protects the allocation of itable
// entries. Since inode.ref_count indicates whether an entry is free,
// and inode.dev and inode.inum indicate which i-node an entry
// holds, one must hold itable.mutex while using any of those fields.
//
// An inode.mutex sleep-lock protects all fields other than ref_count,
// dev, and inum. One must hold inode.mutex in order to read or write
// that inode's inode.valid, inode.dinode.size, inode.dinode.type, &c.
//
// Inode content
//
// The content (data) associated with each inode is stored
// in blocks on the disk. The first NUM_DIRECT block numbers
// are listed in inode.dinode.addrs. The next NUM_INDIRECT blocks are
// listed in block inode.dinoe.addrs[NDIRECT].

var itable: struct {
    /// Protects the inodes array, ensuring that an inode is present at most once and
    /// that it's reference count is the number of in-memory pointers to the inode.
    mutex: SpinLock,
    inodes: [params.NUM_INODE]Inode,
} = .{
    .mutex = .{},
    .inodes = .{std.mem.zeroInit(Inode, .{
        .mutex = .{},
    })} ** params.NUM_INODE,
};

/// Allocate an inode on device dev.
/// Mark it as allocated by giving it type ty.
/// Returns an unlocked but allocated and referenced inode,
/// or an error if there is no free inode.
pub fn allocInode(dev: u32, ty: defs.FileType) !*Inode {
    for (defs.ROOT_INUM..sb.num_inodes) |idx| {
        const inum: u32 = @intCast(idx);
        const buf = bcache.read(dev, sb.inodeBlock(inum));
        const disk_inode =
            &std.mem.bytesAsSlice(defs.DiskInode, &buf.data)[inum % defs.IPB];

        // a free inode
        if (disk_inode.type == 0) {
            disk_inode.* = std.mem.zeroInit(defs.DiskInode, .{});
            disk_inode.type = @intFromEnum(ty);

            // mark it allocated on the disk
            log.write(buf);
            buf.release();

            return getInode(dev, inum);
        }

        buf.release();
    } else {
        return error.OutOfInodes;
    }
}

/// Find the inode with number inum on device dev
/// and return the in-memory copy. Does not lock
/// the inode and does not read it from disk.
fn getInode(dev: u32, inum: u32) *Inode {
    itable.mutex.lock();
    defer itable.mutex.unlock();

    // Is the inode already in the table?
    var empty: ?*Inode = null;
    for (&itable.inodes) |*inode| {
        if (inode.ref_count > 0 and inode.dev == dev and inode.inum == inum) {
            inode.ref_count += 1;
            return inode;
        }

        // Remember empty slot.
        if (empty == null and inode.ref_count == 0) {
            empty = inode;
        }
    }

    // Recycle an inode entry.
    const inode = empty orelse @panic("no more inodes left on disk");
    inode.dev = dev;
    inode.inum = inum;
    inode.ref_count = 1;
    inode.valid = false;
    return inode;
}

/// Reclaims any inodes on disk that have no links but have a non-zero type.
fn reclaimInodes(dev: u32) void {
    for (defs.ROOT_INUM..sb.num_inodes) |idx| {
        const inum: u32 = @intCast(idx);

        const buf = bcache.read(dev, sb.inodeBlock(inum));
        const disk_inode =
            std.mem.bytesAsSlice(defs.DiskInode, &buf.data)[inum % defs.IPB];

        // is an orphaned inode
        if (disk_inode.type != 0 and disk_inode.num_link == 0) {
            fmt.println("found orphan inode when reclaiming inodes: {d}", .{inum});

            const inode = getInode(dev, inum);
            buf.release();

            log.beginOp();
            defer log.endOp();

            inode.lock();
            inode.unlockPut();
        } else {
            buf.release();
        }
    }
}

/// In-memory copy of an inode.
pub const Inode = struct {
    /// Device number
    dev: u32,
    /// Inode number
    inum: u32,
    /// Reference count
    ref_count: u32,
    /// Protects the disk state (valid and dinode)
    mutex: SleepLock,
    /// Inode has been read from disk?
    valid: bool,
    /// Copy of disk inode
    dinode: defs.DiskInode,

    /// Lock the given inode.
    /// Reads the inode from disk if necessary.
    pub fn lock(self: *Inode) void {
        assert(self.ref_count >= 1);

        self.mutex.lock();
        if (!self.valid) {
            const buf = bcache.read(self.dev, sb.inodeBlock(self.inum));

            const disk_inode =
                std.mem.bytesAsSlice(defs.DiskInode, &buf.data)[self.inum % defs.IPB];
            self.dinode = disk_inode;

            buf.release();
            self.valid = true;
            assert(self.dinode.type != 0);
        }
    }

    /// Common idiom: unlock, then put.
    pub fn unlockPut(self: *Inode) void {
        self.unlock();
        self.put();
    }

    /// Unlock the given inode.
    pub fn unlock(self: *Inode) void {
        assert(self.mutex.holding());
        assert(self.ref_count >= 1);

        self.mutex.unlock();
    }

    /// Increment reference count for inode.
    /// Returns a pointer to enable const inode = other.dup(); idiom.
    pub fn dup(self: *Inode) *Inode {
        itable.mutex.lock();
        defer itable.mutex.unlock();

        self.ref_count += 1;
        return self;
    }

    /// Drop a reference to an in-memory inode.
    /// If that was the last reference, the inode table entry can be recycled.
    /// If that was the last reference and the inode has no links
    /// to it, free the inode (and its content) on disk.
    /// All calls to put() must be inside a transaction in
    /// case it has to free the inode.
    pub fn put(self: *Inode) void {
        itable.mutex.lock();
        defer itable.mutex.unlock();

        if (self.ref_count == 1 and self.valid and self.dinode.num_link == 0) {
            // inode has no links and no other references: truncate and free.

            // inode.ref_count == 1 means no other process can have ip locked,
            // so this lock() won't block (or deadlock).
            self.mutex.lock();
            itable.mutex.unlock();
            defer {
                self.mutex.unlock();
                itable.mutex.lock();
            }

            self.trunc();
            self.dinode.type = 0;
            self.update();
            self.valid = false;
        }

        self.ref_count -= 1;
    }

    /// Truncate inode (discard contents).
    /// Caller must hold inode.mutex.
    fn trunc(self: *Inode) void {
        for (0..defs.NUM_DIRECT) |idx| {
            const block_num = self.dinode.addrs[idx];
            if (block_num != 0) {
                freeBlock(self.dev, block_num);
                self.dinode.addrs[idx] = 0;
            }
        }

        const indirect_block_num = self.dinode.addrs[defs.NUM_DIRECT];
        if (indirect_block_num != 0) {
            const indirect_block = bcache.read(self.dev, indirect_block_num);
            const addrs =
                std.mem.bytesAsSlice(u32, &indirect_block.data);

            for (addrs) |block_num| {
                if (block_num != 0) {
                    freeBlock(self.dev, block_num);
                }
            }
            indirect_block.release();

            freeBlock(self.dev, indirect_block_num);
            self.dinode.addrs[defs.NUM_DIRECT] = 0;
        }

        self.dinode.size = 0;
        self.update();
    }

    /// Copy a modified in-memory inode to disk.
    /// Must be called after every change to an inode field that lives on disk.
    /// Caller must hold inode.mutex.
    pub fn update(self: *Inode) void {
        const buf = bcache.read(self.dev, sb.inodeBlock(self.inum));
        defer buf.release();

        const disk_inode =
            &std.mem.bytesAsSlice(defs.DiskInode, &buf.data)[self.inum % defs.IPB];
        disk_inode.* = self.dinode;

        log.write(buf);
    }

    /// Read data from inode.
    /// Caller must hold inode.mutex.
    pub fn read(
        self: *Inode,
        allocator: Allocator,
        dest: proc.EitherMem,
        offset: u32,
    ) !u32 {
        const num = switch (dest) {
            .user => |dst| dst.len,
            .kernel => |dst| dst.len,
        };
        if (offset > self.dinode.size or offset + num < offset)
            return error.InvalidReadRange;
        const n = if (offset + num > self.dinode.size)
            self.dinode.size - offset
        else
            num;

        var bytes_read: u32 = 0;
        while (bytes_read < n) {
            const off = offset + bytes_read;
            const block_num = try self.mapLogicalBlock(off / defs.BLOCK_SIZE);
            const buf = bcache.read(self.dev, block_num);
            defer buf.release();

            const bytes_to_read =
                @min(n - bytes_read, defs.BLOCK_SIZE - off % defs.BLOCK_SIZE);
            const dst: proc.EitherMem = switch (dest) {
                .user => |dst| .{
                    .user = .{ .addr = dst.addr + bytes_read, .len = bytes_to_read },
                },
                .kernel => |dst| .{ .kernel = dst[bytes_read..][0..bytes_to_read] },
            };
            try proc.eitherCopyOut(
                allocator,
                dst,
                buf.data[off % defs.BLOCK_SIZE ..][0..bytes_to_read],
            );
            bytes_read += bytes_to_read;
        }

        return bytes_read;
    }

    /// Write data to inode.
    /// Caller must hold inode.mutex.
    /// Returns the number of bytes successfully written.
    fn write(
        self: *Inode,
        allocator: Allocator,
        source: proc.EitherMem,
        offset: u32,
    ) !u32 {
        const num = switch (source) {
            .user => |src| src.len,
            .kernel => |src| src.len,
        };
        if (offset > self.dinode.size or offset + num < offset)
            return error.InvalidWriteRange;
        if (offset + num > defs.MAX_FILE_BLOCKS * defs.BLOCK_SIZE)
            return error.ExceedsMaxFileSize;

        var bytes_written: u32 = 0;
        while (bytes_written < num) {
            const off = offset + bytes_written;
            const block_num = try self.mapLogicalBlock(off / defs.BLOCK_SIZE);
            const buf = bcache.read(self.dev, block_num);
            defer buf.release();

            const bytes_to_write =
                @min(num - bytes_written, defs.BLOCK_SIZE - off % defs.BLOCK_SIZE);
            const src: proc.EitherMem = switch (source) {
                .user => |src| .{
                    .user = .{ .addr = src.addr + bytes_written, .len = bytes_to_write },
                },
                .kernel => |src| .{ .kernel = src[bytes_written..][0..bytes_to_write] },
            };
            try proc.eitherCopyIn(
                allocator,
                buf.data[off % defs.BLOCK_SIZE ..][0..bytes_to_write],
                src,
            );
            log.write(buf);
            bytes_written += bytes_to_write;
        }

        const new_off = offset + bytes_written;
        if (new_off > self.dinode.size) {
            self.dinode.size = new_off;
        }

        // write the i-node back to disk even if the size didn't change
        // because the loop above might have called mapLogicalBlock() and added a new
        // block to ip.dinode.addrs.
        self.update();

        return bytes_written;
    }

    /// Return the disk block address of the nth block in inode.
    /// If there is no such block, bmap allocates one.
    /// Returns an error if out of disk space.
    fn mapLogicalBlock(self: *Inode, logical_block_num: u32) !u32 {
        var lbn = logical_block_num;

        if (lbn < defs.NUM_DIRECT) {
            var block_num = self.dinode.addrs[lbn];
            if (block_num == 0) {
                block_num = try allocBlock(self.dev);
                self.dinode.addrs[lbn] = block_num;
            }
            return block_num;
        }
        lbn -= defs.NUM_DIRECT;

        if (lbn < defs.NUM_INDIRECT) {
            // Load indirect block, allocating if necessary.
            var indirect_block_num = self.dinode.addrs[defs.NUM_DIRECT];
            if (indirect_block_num == 0) {
                indirect_block_num = try allocBlock(self.dev);
                self.dinode.addrs[defs.NUM_DIRECT] = indirect_block_num;
            }

            const indirect_block = bcache.read(self.dev, indirect_block_num);
            defer indirect_block.release();

            const addrs =
                std.mem.bytesAsSlice(u32, &indirect_block.data);
            var block_num = addrs[lbn];
            if (block_num == 0) {
                block_num = try allocBlock(self.dev);
                addrs[lbn] = block_num;
                log.write(indirect_block);
            }

            return block_num;
        }

        std.debug.panic("logical block out of range: {}", .{logical_block_num});
    }
};

// Blocks.

// Try to allocate a zeroed disk block.
fn allocBlock(dev: u32) !u32 {
    var block_num: u32 = 0;
    while (block_num < sb.size) : (block_num += defs.BPB) {
        const buf = bcache.read(dev, sb.bitmapBlock(block_num));

        // Get first free block.
        var bit_set = std.mem.bytesAsValue(std.StaticBitSet(defs.BPB), &buf.data);
        var it = bit_set.iterator(.{ .kind = .unset, .direction = .forward });
        if (it.next()) |index| {
            // Mark block in use.
            const idx: u32 = @intCast(index);
            bit_set.set(idx);
            log.write(buf);

            buf.release();
            zeroBlock(dev, idx);
            return idx;
        }
        buf.release();
    } else {
        return error.OutOfBlocks;
    }
}

/// Free a disk block.
fn freeBlock(dev: u32, block_num: u32) void {
    const buf = bcache.read(dev, sb.bitmapBlock(block_num));
    defer buf.release();

    var bit_set = std.mem.bytesAsValue(std.StaticBitSet(defs.BPB), &buf.data);
    assert(bit_set.isSet(block_num));
    bit_set.unset(block_num);

    log.write(buf);
}

/// Zero a block.
fn zeroBlock(dev: u32, block_num: u32) void {
    const buf = bcache.read(dev, block_num);
    defer buf.release();

    @memset(&buf.data, 0);
    log.write(buf);
}
