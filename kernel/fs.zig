//! File system implementation.  Five layers:
//!   + Blocks: allocator for raw disk blocks.
//!   + Log: crash recovery for multi-step updates.
//!   + Files: inode allocator, reading, writing, metadata.
//!   + Directories: inode with special contents (list of other inodes!)
//!   + Names: paths like /usr/rtm/xv6/fs.c for convenient naming.
//!
//! This file contains the low-level file system manipulation
//! routines.  The (higher-level) system call implementations
//! are in sysfile.c.

const std = @import("std");
const assert = std.debug.assert;

const fmt = @import("fmt.zig");
const bcache = @import("fs/bcache.zig");
const defs = @import("fs/defs.zig");
const log = @import("fs/log.zig");

/// There should be one superblock per disk device, but we run with only one device.
var sb: defs.SuperBlock = undefined;

/// Initialize the file system.
pub fn init(dev: u32) void {
    initSuperBlock(dev);
    log.init(dev, &sb);
    // TODO: reclaim
}

/// Read the super block.
fn initSuperBlock(dev: u32) void {
    const buf = bcache.read(dev, 1);
    defer bcache.release(buf);

    sb = std.mem.bytesToValue(defs.SuperBlock, &buf.data);
    assert(sb.magic == defs.FS_MAGIC);
}

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

            bcache.release(buf);
            zeroBlock(dev, idx);
            return idx;
        }
        bcache.release(buf);
    }
    return error.OutOfBlocks;
}

/// Free a disk block.
fn freeBlock(dev: u32, block_num: u32) void {
    const buf = bcache.read(dev, sb.bitmapBlock(block_num));
    defer bcache.release(buf);

    var bit_set = std.mem.bytesAsValue(std.StaticBitSet(defs.BPB), &buf.data);
    assert(bit_set.isSet(block_num));
    bit_set.unset(block_num);

    log.write(buf);
}

/// Zero a block.
fn zeroBlock(dev: u32, block_num: u32) void {
    const buf = bcache.read(dev, block_num);
    defer bcache.release(buf);

    @memset(&buf.data, 0);
    log.write(buf);
}
