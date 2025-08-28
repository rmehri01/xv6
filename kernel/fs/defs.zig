//! On-disk file system format.
//! Both the kernel and user programs use this header file.

const std = @import("std");
const assert = std.debug.assert;

/// Root i-number.
pub const ROOT_INUM = 1;
/// Block size for the file system.
pub const BLOCK_SIZE = 1024;

/// Magic constant for identifying the file system.
pub const FS_MAGIC = 0x10203040;

/// Number of direct blocks a file can contain.
pub const NUM_DIRECT = 12;
/// Number of blocks in an indirect block.
pub const NUM_INDIRECT = BLOCK_SIZE / @sizeOf(u32);
/// Maximum number of blocks a file can have.
pub const MAX_FILE_BLOCKS = NUM_DIRECT + NUM_INDIRECT;

/// Inodes per block.
pub const IPB = BLOCK_SIZE / @sizeOf(DiskInode);
/// Bitmap bits per block.
pub const BPB = BLOCK_SIZE * 8;

/// Directory is a file containing a sequence of dirent structures.
pub const DIR_NAME_SIZE = 14;

/// Super block describes the disk layout of the file system.
///
/// Disk layout:
/// [ boot block | super block | log | inode blocks | free bit map | data blocks]
pub const SuperBlock = extern struct {
    /// Must be FS_MAGIC.
    magic: u32,
    /// Size of file system image (blocks).
    size: u32,
    /// Number of data blocks.
    num_blocks: u32,
    /// Number of inodes.
    num_inodes: u32,
    /// Number of log blocks.
    num_log: u32,
    /// Block number of first log block.
    log_start: u32,
    /// Block number of first inode block.
    inode_start: u32,
    /// Block number of first free map block.
    bmap_start: u32,

    /// Block containing inode number inum.
    pub fn inodeBlock(self: SuperBlock, inum: u32) u32 {
        return inum / IPB + self.inode_start;
    }

    /// Block of free map containing bit for block_num.
    pub fn bitmapBlock(self: SuperBlock, block_num: u32) u32 {
        return block_num / BPB + self.bmap_start;
    }
};

/// On-disk inode structure.
pub const DiskInode = extern struct {
    /// File type.
    type: u16,
    /// Major device number (T_DEVICE only).
    major: u16,
    /// Minor device number (T_DEVICE only).
    minor: u16,
    /// Number of links to inode in file system.
    num_link: u16,
    /// Size of file (bytes).
    size: u32,
    /// Data block addresses.
    addrs: [NUM_DIRECT + 1]u32,

    comptime {
        assert(BLOCK_SIZE % @sizeOf(DiskInode) == 0);
    }
};

/// Types of files in the file system.
pub const FileType = enum(u16) {
    /// Directory.
    dir = 1,
    /// File.
    file = 2,
    /// Device.
    dev = 3,
};

/// Directory entry.
pub const DirEnt = extern struct {
    inum: u16,
    name: [DIR_NAME_SIZE]u8,

    comptime {
        assert(BLOCK_SIZE % @sizeOf(DirEnt) == 0);
    }
};

/// Options for opening a file.
pub const OpenMode = struct {
    pub const READ_ONLY = 0x000;
    pub const WRITE_ONLY = 0x001;
    pub const READ_WRITE = 0x002;
    pub const CREATE = 0x200;
    pub const TRUNCATE = 0x400;
};
