//! Driver for qemu's virtio disk device.
//! Uses qemu's mmio interface to virtio.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const memlayout = @import("../memlayout.zig");
const proc = @import("../proc.zig");
const SpinLock = @import("../sync/SpinLock.zig");
const bcache = @import("bcache.zig");
const defs = @import("shared").fs;

/// Virtio mmio control registers, mapped starting at 0x10001000.
/// From qemu virtio_mmio.h
const MmioReg = enum(u12) {
    /// 0x74726976
    magic_value = 0x000,
    /// version; should be 2
    version = 0x004,
    /// device type; 1 is net, 2 is disk
    device_id = 0x008,
    /// 0x554d4551
    vendor_id = 0x00c,
    device_features = 0x010,
    driver_features = 0x020,
    /// select queue, write-only
    queue_sel = 0x030,
    /// max size of current queue, read-only
    queue_num_max = 0x034,
    /// size of current queue, write-only
    queue_num = 0x038,
    /// ready bit
    queue_ready = 0x044,
    /// write-only
    queue_notify = 0x050,
    /// read-only
    interrupt_status = 0x060,
    /// write-only
    interrupt_ack = 0x064,
    /// read/write
    status = 0x070,
    /// physical address for descriptor table, write-only
    queue_desc_low = 0x080,
    queue_desc_high = 0x084,
    /// physical address for available ring, write-only
    driver_desc_low = 0x090,
    driver_desc_high = 0x094,
    /// physical address for used ring, write-only
    device_desc_low = 0x0a0,
    device_desc_high = 0x0a4,
};

// Status register bits, from qemu virtio_config.h
const CONFIG_S_ACKNOWLEDGE = 1;
const CONFIG_S_DRIVER = 2;
const CONFIG_S_DRIVER_OK = 4;
const CONFIG_S_FEATURES_OK = 8;

// device feature bits
/// Disk is read-only.
const BLK_F_RO: u32 = (1 << 5);
/// Supports scsi command passthru.
const BLK_F_SCSI: u32 = (1 << 7);
/// Writeback mode available in config.
const BLK_F_CONFIG_WCE: u32 = (1 << 11);
/// Support more than one vq.
const BLK_F_MQ: u32 = (1 << 12);
const F_ANY_LAYOUT: u32 = (1 << 27);
const RING_F_INDIRECT_DESC: u32 = (1 << 28);
const RING_F_EVENT_IDX: u32 = (1 << 29);

/// This many virtio descriptors.
/// Must be a power of two.
const NUM_DESC = 8;
comptime {
    assert(std.math.isPowerOfTwo(NUM_DESC));
}

var disk: Disk = undefined;

/// State of the virtio disk.
const Disk = struct {
    mutex: SpinLock,

    /// A set (not a ring) of DMA descriptors, with which the
    /// driver tells the device where to read and write individual
    /// disk operations.
    /// Most commands consist of a "chain" (a linked list) of a couple of
    /// these descriptors.
    desc: *[NUM_DESC]VirtqDesc,
    /// A ring in which the driver writes descriptor numbers
    /// that the driver would like the device to process. It only
    /// includes the head descriptor of each chain.
    avail: *VirtqAvail,
    /// A ring in which the device writes descriptor numbers that
    /// the device has finished processing (just the head of each chain).
    used: *VirtqUsed,

    free: std.StaticBitSet(NUM_DESC) = .initEmpty(),
    /// we've looked this far in used[2..NUM_DESC].
    used_idx: u16 = 0,
    /// Track info about in-flight operations,
    /// for use when completion interrupt arrives.
    /// indexed by first descriptor index of chain.
    info: [NUM_DESC]struct { b: *bcache.Buf, status: u8 },
    /// Disk command headers.
    /// One-for-one with descriptors, for convenience.
    ops: [NUM_DESC]BlkReq,
};

/// A single descriptor, from the spec.
const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

/// chained with another descriptor
const VRING_DESC_F_NEXT = 1;
/// device writes (vs read)
const VRING_DESC_F_WRITE = 2;

/// The (entire) avail ring, from the spec.
/// Descriptors that the driver would like the device to process.
const VirtqAvail = extern struct {
    /// always zero
    flags: u16,
    /// driver will write ring[idx] next
    idx: u16,
    /// descriptor numbers of chain heads
    ring: [NUM_DESC]u16,
    unused: u16,
};

/// Descriptors that the device has finished processing.
const VirtqUsed = extern struct {
    /// always zero
    flags: u16,
    /// device increments when it adds a ring[] entry
    idx: u16,
    ring: [NUM_DESC]VirtqUsedElem,
};

/// One entry in the "used" ring, with which the
/// device tells the driver about completed requests.
const VirtqUsedElem = extern struct {
    /// index of start of completed descriptor chain
    id: u32,
    len: u32,
};

// these are specific to virtio block devices, e.g. disks,
// described in Section 5.2 of the spec.

/// Read the disk.
const BLK_T_IN = 0;
/// Write the disk.
const BLK_T_OUT = 1;

/// The format of the first descriptor in a disk request.
/// To be followed by two more descriptors containing
/// the block, and a one-byte status.
const BlkReq = extern struct {
    /// BLK_T_IN or ..._OUT
    type: u32,
    reserved: u32,
    sector: u64,
};

pub fn init(allocator: Allocator) !void {
    assert(reg(.magic_value).* == 0x74726976);
    assert(reg(.version).* == 2);
    assert(reg(.device_id).* == 2);
    assert(reg(.vendor_id).* == 0x554d4551);

    // reset device
    var status: u32 = 0;
    reg(.status).* = status;

    // set ACKNOWLEDGE status bit
    status |= CONFIG_S_ACKNOWLEDGE;
    reg(.status).* = status;

    // set DRIVER status bit
    status |= CONFIG_S_DRIVER;
    reg(.status).* = status;

    // negotiate features
    var features = reg(.device_features).*;
    features &= ~BLK_F_RO;
    features &= ~BLK_F_SCSI;
    features &= ~BLK_F_CONFIG_WCE;
    features &= ~BLK_F_MQ;
    features &= ~F_ANY_LAYOUT;
    features &= ~RING_F_EVENT_IDX;
    features &= ~RING_F_INDIRECT_DESC;
    reg(.device_features).* = features;

    // tell device that feature negotiation is complete.
    status |= CONFIG_S_FEATURES_OK;
    reg(.status).* = status;

    // re-read status to ensure FEATURES_OK is set.
    status = reg(.status).*;
    assert(status & CONFIG_S_FEATURES_OK != 0);

    // initialize queue 0.
    reg(.queue_sel).* = 0;
    // ensure queue 0 is not in use.
    assert(reg(.queue_ready).* == 0);

    // check maximum queue size.
    const max = reg(.queue_num_max).*;
    assert(max != 0);
    assert(max >= NUM_DESC);

    // allocate and zero queue memory.
    disk = .{
        .mutex = .{},
        .desc = try allocator.create([NUM_DESC]VirtqDesc),
        .avail = try allocator.create(VirtqAvail),
        .used = try allocator.create(VirtqUsed),
        .info = undefined,
        .ops = undefined,
    };
    @memset(disk.desc, std.mem.zeroInit(VirtqDesc, .{}));
    disk.avail.* = std.mem.zeroInit(VirtqAvail, .{});
    disk.used.* = std.mem.zeroInit(VirtqUsed, .{});

    // set queue size.
    reg(.queue_num).* = NUM_DESC;

    // write physical addresses.
    reg(.queue_desc_low).* = @truncate(@intFromPtr(disk.desc));
    reg(.queue_desc_high).* = @truncate(@intFromPtr(disk.desc) >> 32);
    reg(.driver_desc_low).* = @truncate(@intFromPtr(disk.avail));
    reg(.driver_desc_high).* = @truncate(@intFromPtr(disk.avail) >> 32);
    reg(.device_desc_low).* = @truncate(@intFromPtr(disk.used));
    reg(.device_desc_high).* = @truncate(@intFromPtr(disk.used) >> 32);

    // queue is ready.
    reg(.queue_ready).* = 1;

    // tell device we're completely ready.
    status |= CONFIG_S_DRIVER_OK;
    reg(.status).* = status;

    // plic.zig and trap.zig arrange for interrupts from Irq.virtio.
}

/// Reads the contents of disk at b.block_num into b.data.
pub fn read(b: *bcache.Buf) void {
    rwImpl(b, .read);
}

/// Writes the contents of b.data to disk at b.block_num.
pub fn write(b: *bcache.Buf) void {
    rwImpl(b, .write);
}

fn rwImpl(b: *bcache.Buf, comptime mode: enum { read, write }) void {
    const sector = b.block_num * (defs.BLOCK_SIZE / 512);

    disk.mutex.lock();
    defer disk.mutex.unlock();

    // the spec's Section 5.2 says that legacy block operations use
    // three descriptors: one for type/reserved/sector, one for the
    // data, one for a 1-byte status result.

    // allocate the three descriptors.
    const first, const second, const third = while (true) {
        break alloc3Desc() catch {
            proc.sleep(@intFromPtr(&disk.free), &disk.mutex);
            continue;
        };
    };
    defer {
        freeDesc(first);
        freeDesc(second);
        freeDesc(third);
    }

    // format the three descriptors.
    // qemu's virtio-blk.c reads them.

    const buf0 = &disk.ops[first];
    buf0.* = .{
        .type = switch (mode) {
            .read => BLK_T_IN,
            .write => BLK_T_OUT,
        },
        .reserved = 0,
        .sector = sector,
    };

    disk.desc[first] = .{
        .addr = @intFromPtr(buf0),
        .len = @sizeOf(BlkReq),
        .flags = VRING_DESC_F_NEXT,
        .next = second,
    };
    disk.desc[second] = .{
        .addr = @intFromPtr(&b.data),
        .len = b.data.len,
        .flags = switch (mode) {
            // device writes b->data
            .read => VRING_DESC_F_WRITE,
            // device reads b->data
            .write => 0,
        } | VRING_DESC_F_NEXT,
        .next = third,
    };
    // device writes 0 on success
    disk.info[first].status = 0xff;
    disk.desc[third] = .{
        .addr = @intFromPtr(&disk.info[first].status),
        .len = 1,
        .flags = VRING_DESC_F_WRITE,
        .next = 0,
    };

    // record struct buf for handleIntr().
    b.disk_owned = true;
    disk.info[first].b = b;

    // tell the device the first index in our chain of descriptors.
    disk.avail.ring[disk.avail.idx % NUM_DESC] = first;
    // tell the device another avail ring entry is available.
    _ = @atomicRmw(u16, &disk.avail.idx, .Add, 1, .acq_rel);

    // value is queue number
    reg(.queue_notify).* = 0;

    // Wait for handleIntr() to say request has finished.
    while (b.disk_owned) {
        proc.sleep(@intFromPtr(b), &disk.mutex);
    }

    disk.info[first] = undefined;
}

// Try to allocate three descriptors (they need not be contiguous).
// Disk transfers always use three descriptors.
fn alloc3Desc() ![3]u16 {
    const first = try allocDesc();
    errdefer freeDesc(first);
    const second = try allocDesc();
    errdefer freeDesc(second);
    const third = try allocDesc();
    errdefer freeDesc(third);

    return .{ first, second, third };
}

/// Try to find a free descriptor, mark it non-free, return its index.
fn allocDesc() !u16 {
    var it = disk.free.iterator(.{ .kind = .unset, .direction = .forward });
    const desc = it.next() orelse return error.OutOfDescriptors;
    disk.free.set(desc);
    return @intCast(desc);
}

/// Mark a descriptor as free.
fn freeDesc(desc: u32) void {
    assert(desc < NUM_DESC);
    assert(disk.free.isSet(desc));

    disk.free.unset(desc);
    disk.desc[desc] = std.mem.zeroInit(VirtqDesc, .{});
    proc.wakeUp(@intFromPtr(&disk.free));
}

/// Handles a VIRTIO interrupt for reading or writing a block.
pub fn handleIntr() void {
    disk.mutex.lock();
    defer disk.mutex.unlock();

    // the device won't raise another interrupt until we tell it
    // we've seen this interrupt, which the following line does.
    // this may race with the device writing new entries to
    // the "used" ring, in which case we may process the new
    // completion entries in this interrupt, and have nothing to do
    // in the next interrupt, which is harmless.
    reg(.interrupt_ack).* = reg(.interrupt_status).* & 0x3;

    // TODO: synchronization?

    // the device increments disk.used.idx when it
    // adds an entry to the used ring.
    while (disk.used_idx != disk.used.idx) : (disk.used_idx += 1) {
        const id = disk.used.ring[disk.used_idx % NUM_DESC].id;
        assert(disk.info[id].status == 0);
        const b = disk.info[id].b;
        b.disk_owned = false;
        proc.wakeUp(@intFromPtr(b));
    }
}

// The address of virtio mmio register.
fn reg(r: MmioReg) *u32 {
    return @ptrFromInt(memlayout.VIRTIO0 + @as(usize, @intFromEnum(r)));
}
