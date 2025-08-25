//! Simple logging that allows concurrent FS system calls.
//!
//! A log transaction contains the updates of multiple FS system
//! calls. The logging system only commits when there are
//! no FS system calls active. Thus there is never
//! any reasoning required about whether a commit might
//! write an uncommitted system call's updates to disk.
//!
//! A system call should call beginOp()/endOp() to mark
//! its start and end. Usually beginOp() just increments
//! the count of in-progress FS system calls and returns.
//! But if it thinks the log is close to running out, it
//! sleeps until the last outstanding endOp() commits.
//!
//! The log is a physical re-do log containing disk blocks.
//! The on-disk log format:
//!   header block, containing block #s for block A, B, C, ...
//!   block A
//!   block B
//!   block C
//!   ...
//! Log appends are synchronous.

const std = @import("std");
const assert = std.debug.assert;

const fmt = @import("../fmt.zig");
const params = @import("../params.zig");
const proc = @import("../proc.zig");
const SpinLock = @import("../sync/SpinLock.zig");
const bcache = @import("bcache.zig");
const defs = @import("defs.zig");

/// Contents of the header block, used for both the on-disk header block
/// and to keep track in memory of logged block# before commit.
const Header = extern struct {
    n: u32,
    blocks: [params.LOG_BLOCKS]u32,

    comptime {
        assert(@sizeOf(Header) < defs.BLOCK_SIZE);
    }
};

/// State of the log.
const Log = struct {
    mutex: SpinLock,
    start: u32,
    /// How many FS sys calls are executing.
    outstanding: u32,
    /// In commit(), please wait.
    committing: bool,
    dev: u32,
    header: Header,
};

var log: Log = undefined;

pub fn init(dev: u32, sb: *defs.SuperBlock) void {
    log = .{
        .mutex = .{},
        .start = sb.log_start,
        .outstanding = 0,
        .committing = false,
        .dev = dev,
        .header = .{ .n = 0, .blocks = undefined },
    };
    recoverFromLog();
}

/// Called at the start of each FS system call.
pub fn beginOp() void {
    log.mutex.lock();
    defer log.mutex.unlock();

    while (true) {
        if (log.committing or
            // this op might exhaust log space; wait for commit.
            log.header.n + (log.outstanding + 1) * params.MAX_OP_BLOCKS > params.LOG_BLOCKS)
        {
            proc.sleep(@intFromPtr(&log), &log.mutex);
        } else {
            log.outstanding += 1;
            break;
        }
    }
}

/// Caller has modified buf.data and is done with the buffer.
/// Record the block number and pin in the cache by increasing ref_count.
/// commit()/flushLog() will do the disk write.
///
/// log.write() replaces bcache.write(); a typical use is:
///
/// ```zig
///   const buf = bcache.read(...);
///   defer bcache.release(buf);
///   // modify buf.data[];
///   log.write(buf);
/// ```
pub fn write(buf: *bcache.Buf) void {
    log.mutex.lock();
    defer log.mutex.unlock();

    assert(log.header.n < params.LOG_BLOCKS);
    assert(log.outstanding != 0);

    const idx = for (0..log.header.n) |idx| {
        // log absorption
        if (log.header.blocks[idx] == buf.block_num) {
            break idx;
        }
    } else value: {
        // Add new block to log
        defer log.header.n += 1;
        bcache.pin(buf);
        break :value log.header.n;
    };
    log.header.blocks[idx] = buf.block_num;
}

/// Called at the end of each FS system call.
/// Commits if this was the last outstanding operation.
pub fn endOp() void {
    const do_commit = value: {
        log.mutex.lock();
        defer log.mutex.unlock();

        assert(!log.committing);
        log.outstanding -= 1;
        if (log.outstanding == 0) {
            log.committing = true;
            break :value true;
        } else {
            // beginOp() may be waiting for log space,
            // and decrementing log.outstanding has decreased
            // the amount of reserved space.
            proc.wakeUp(@intFromPtr(&log));
            break :value false;
        }
    };
    if (do_commit) {
        // call commit w/o holding locks, since not allowed
        // to sleep with locks.
        commit();

        log.mutex.lock();
        defer log.mutex.unlock();

        log.committing = false;
        proc.wakeUp(@intFromPtr(&log));
    }
}

/// Finish the current transaction by flushing the log and data blocks
/// back to disk and clearing the log.
fn commit() void {
    if (log.header.n > 0) {
        // Write modified blocks from cache to log
        flushLog();
        // Write header to disk -- the real commit
        flushHead();
        // Now install writes to home locations
        flushTransaction(false);
        // Erase the transaction from the log
        log.header.n = 0;
        flushHead();
    }
}

/// Copy modified blocks from cache to log.
fn flushLog() void {
    for (0..log.header.n) |idx| {
        // log block
        const to = bcache.read(log.dev, @intCast(log.start + idx + 1));
        defer bcache.release(to);

        // cache block
        const from = bcache.read(log.dev, log.header.blocks[idx]);
        defer bcache.release(from);

        // write the log
        @memcpy(&to.data, &from.data);
        bcache.write(to);
    }
}

/// Recovers the file system state in the case of a crash.
fn recoverFromLog() void {
    readHead();

    // if committed, copy from log to disk
    flushTransaction(true);
    log.header.n = 0;

    flushHead();
}

/// Read the log header from disk into the in-memory log header.
fn readHead() void {
    const buf = bcache.read(log.dev, log.start);
    defer bcache.release(buf);

    log.header = std.mem.bytesToValue(Header, &buf.data);
}

/// Copy committed blocks from log to their home location.
fn flushTransaction(comptime recovering: bool) void {
    for (0..log.header.n) |idx| {
        const block_num = log.header.blocks[idx];
        if (recovering) {
            fmt.println("recovering idx {d} dst block num {d}\n", .{ idx, block_num });
        }

        // read log block
        const data_buf = bcache.read(log.dev, @intCast(log.start + idx + 1));
        defer bcache.release(data_buf);

        // read dst
        const dst_buf = bcache.read(log.dev, block_num);
        defer bcache.release(dst_buf);

        @memcpy(&dst_buf.data, &data_buf.data);
        bcache.write(dst_buf);
        if (!recovering) {
            bcache.unpin(dst_buf);
        }
    }
}

/// Write in-memory log header to disk.
/// This is the true point at which the current transaction commits.
fn flushHead() void {
    const buf = bcache.read(log.dev, log.start);
    defer bcache.release(buf);

    const logBytes = std.mem.asBytes(&log.header);
    @memcpy(buf.data[0..logBytes.len], logBytes);
    bcache.write(buf);
}
