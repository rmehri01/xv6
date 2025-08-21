//! Constant parameters that are used in various places throughout the kernel.

/// Maximum number of CPUs
pub const MAX_CPUS = 8;

/// maximum number of processes
pub const MAX_PROCS = 64;

/// Size of stack per cpu
pub const STACK_SIZE = 4096;

/// Interval at which timer interrupts should occur.
/// 1000000 is about a tenth of a second.
pub const TIMER_INTERVAL = 1000000;
