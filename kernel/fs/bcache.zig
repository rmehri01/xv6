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
const DoublyLinkedList = std.DoublyLinkedList;

const params = @import("../params.zig");
const SleepLock = @import("../sync/SleepLock.zig");
const SpinLock = @import("../sync/SpinLock.zig");
const defs = @import("defs.zig");

/// Backing storage for the doubly linked `head` buffer cache.
var bufs: [params.NUM_BUF]Buf = undefined;
/// Protects the buffer cache.
var mutex: SpinLock = .{};
/// Linked list of all buffers, through prev/next.
/// Sorted by how recently the buffer was used.
/// head.next is most recent, head.prev is least.
var head: DoublyLinkedList = init: {
    var buf_list: DoublyLinkedList = .{};
    for (&bufs) |*buf| {
        buf_list.append(buf.node);
    }
    break :init buf_list;
};

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
    data: [defs.BLOCK_SIZE]u8,
    node: DoublyLinkedList.Node,
};

pub fn read() void {}

pub fn write() void {}

pub fn release() void {}
