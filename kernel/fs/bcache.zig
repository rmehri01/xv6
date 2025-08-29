//! Buffer cache.
//!
//! The buffer cache is a linked list of buf structures holding
//! cached copies of disk block contents. Caching disk blocks
//! in memory reduces the number of disk reads and also provides
//! a synchronization point for disk blocks used by multiple processes.
//!
//! Interface:
//! * To get a buffer for a particular disk block, call read.
//! * After changing buffer data, call write to write it to disk.
//! * When done with the buffer, call release.
//! * Do not use the buffer after calling release.
//! * Only one process at a time can use a buffer,
//!     so do not keep them longer than necessary.

const std = @import("std");
const assert = std.debug.assert;
const DoublyLinkedList = std.DoublyLinkedList;

const defs = @import("shared").fs;
const params = @import("shared").params;

const SleepLock = @import("../sync/SleepLock.zig");
const SpinLock = @import("../sync/SpinLock.zig");
const virtio = @import("virtio.zig");

/// Backing storage for the doubly linked `head` buffer cache.
var bufs: [params.NUM_BUF]Buf = undefined;
/// Protects the buffer cache.
var mutex: SpinLock = .{};
/// Linked list of all buffers, through prev/next.
/// Sorted by how recently the buffer was used.
/// head.next is most recent, head.prev is least.
var head: DoublyLinkedList = .{};

pub fn init() void {
    // Create linked list of buffers
    for (&bufs) |*buf| {
        head.append(&buf.node);
    }
}

/// Return a locked Buf with the contents of the indicated block.
pub fn read(dev: u32, block_num: u32) *Buf {
    const buf = get(dev, block_num);
    if (!buf.valid) {
        virtio.read(buf);
        buf.valid = true;
    }

    return buf;
}

/// Look through buffer cache for block on device dev.
/// If not found, allocate a buffer.
/// In either case, return locked buffer.
fn get(dev: u32, block_num: u32) *Buf {
    mutex.lock();

    // Is the block already cached?
    var it = head.first;
    while (it) |node| : (it = node.next) {
        const buf: *Buf = @fieldParentPtr("node", node);
        if (buf.dev == dev and buf.block_num == block_num) {
            buf.ref_count += 1;
            mutex.unlock();
            buf.mutex.lock();
            return buf;
        }
    }

    // Not cached.
    // Recycle the least recently used (LRU) unused buffer.
    it = head.last;
    while (it) |node| : (it = node.prev) {
        const buf: *Buf = @fieldParentPtr("node", node);
        if (buf.ref_count == 0) {
            buf.dev = dev;
            buf.block_num = block_num;
            buf.valid = false;
            buf.ref_count = 1;

            mutex.unlock();
            buf.mutex.lock();
            return buf;
        }
    } else {
        @panic("bcache out of buffers!");
    }
}

/// A single buffer, which is a copy of a disk block that can be
/// read or written in memory and then flushed back to disk.
pub const Buf = struct {
    mutex: SleepLock,
    /// Has data been read from disk?
    valid: bool,
    /// Does disk "own" buf?
    disk_owned: bool,
    dev: u32,
    block_num: u32,
    ref_count: u32,
    data: [defs.BLOCK_SIZE]u8 align(8),
    node: DoublyLinkedList.Node,

    /// Write buf's contents to disk. Must be locked.
    pub fn flush(self: *Buf) void {
        assert(self.mutex.holding());
        virtio.write(self);
    }

    /// Release a locked buffer.
    /// Move to the head of the most-recently-used list.
    pub fn release(self: *Buf) void {
        assert(self.mutex.holding());
        self.mutex.unlock();

        mutex.lock();
        defer mutex.unlock();

        self.ref_count -= 1;
        if (self.ref_count == 0) {
            // no one is waiting for it.
            head.remove(&self.node);
            head.prepend(&self.node);
        }
    }

    /// Pin the buf in the block cache to prevent it from being evicted.
    pub fn pin(self: *Buf) void {
        mutex.lock();
        defer mutex.unlock();

        self.ref_count += 1;
    }

    /// Unpins a previously pinned buf, allowing it to be evicted again.
    pub fn unpin(self: *Buf) void {
        mutex.lock();
        defer mutex.unlock();

        self.ref_count -= 1;
    }
};
