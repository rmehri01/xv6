//! Constant parameters that are used in various places throughout the kernel.

/// Maximum number of CPUs
pub const MAX_CPUS = 8;

/// maximum number of processes
pub const MAX_PROCS = 64;
/// Max exec arguments
pub const MAX_ARGS = 32;

/// Size of stack per cpu
pub const STACK_SIZE = 4096 * 8;
/// Size of user stack
pub const USER_STACK_SIZE = 4096 * 8;

/// Interval at which timer interrupts should occur.
/// 1000000 is about a tenth of a second.
pub const TIMER_INTERVAL = 1000000;

/// Device number of file system root disk.
pub const ROOT_DEV = 1;
/// Maximum major device number.
pub const NUM_DEV = 10;
/// Open files per system.
pub const NUM_FILE = 100;
/// Open files per process.
pub const NUM_FILE_PER_PROC = 16;
/// Maximum number of active i-nodes.
pub const NUM_INODE = 50;
/// Size of disk block cache.
pub const NUM_BUF = MAX_OP_BLOCKS * 3;
/// Max data blocks in on-disk log.
pub const LOG_BLOCKS = MAX_OP_BLOCKS * 3;
/// Max # of blocks any FS op writes.
pub const MAX_OP_BLOCKS = 10;
/// Size of file system in blocks.
pub const FS_SIZE = 2000;
/// Maximum file path name length.
pub const MAX_PATH = 128;
