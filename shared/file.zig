//! Shared constants related to files.

/// Major device number of the console.
pub const CONSOLE = 1;

/// Options for opening a file.
pub const OpenMode = struct {
    pub const READ_ONLY = 0x000;
    pub const WRITE_ONLY = 0x001;
    pub const READ_WRITE = 0x002;
    pub const CREATE = 0x200;
    pub const TRUNCATE = 0x400;
};

/// Metadata about a file.
pub const Stat = extern struct {
    /// File system's disk device.
    dev: u32,
    /// Inode number.
    inum: u32,
    /// Type of file.
    type: u16,
    /// Number of links to file.
    num_link: u16,
    /// Size of file in bytes.
    size: u64,
};
