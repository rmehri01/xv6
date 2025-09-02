//! Shared constants related to system calls.

/// System call number.
pub const Num = enum(u64) {
    fork = 1,
    exit = 2,
    wait = 3,
    pipe = 4,
    read = 5,
    kill = 6,
    exec = 7,
    fstat = 8,
    chdir = 9,
    dup = 10,
    getpid = 11,
    sbrk = 12,
    pause = 13,
    uptime = 14,
    open = 15,
    write = 16,
    mknod = 17,
    unlink = 18,
    link = 19,
    mkdir = 20,
    close = 21,
};

/// Types of sbrk, either eager or lazy.
pub const SbrkType = enum(u2) {
    eager = 1,
    lazy = 2,
};
