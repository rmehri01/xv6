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
