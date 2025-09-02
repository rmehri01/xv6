//! Memory allocator by Kernighan and Ritchie,
//! The C programming Language, 2nd ed. Section 8.7.

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const SinglyLinkedList = std.SinglyLinkedList;

const syscall = @import("syscall.zig");
const defs = @import("shared").syscall;

const Header = struct {
    node: SinglyLinkedList.Node,
    size: u64,
};
var base: Header = .{
    .node = .{ .next = &base.node },
    .size = 0,
};

/// Circular free list.
var free_ptr: *SinglyLinkedList.Node = &base.node;

/// General purpose storage allocator.
pub var allocator: Allocator = .{
    .ptr = &allocator,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    },
};

fn alloc(
    ctx: *anyopaque,
    n: usize,
    alignment: mem.Alignment,
    return_address: usize,
) ?[*]u8 {
    assert(@sizeOf(Header) % alignment.toByteUnits() == 0);
    _ = ctx;
    _ = return_address;

    // allocate enough for n and one extra header
    const num_units =
        std.mem.alignForward(usize, n, @sizeOf(Header)) / @sizeOf(Header) + 1;

    var prev = free_ptr;
    var current = prev.next.?;
    while (true) : ({
        prev = current;
        current = current.next.?;
    }) {
        // try to fit the allocation in an existing free list node
        const hdr: *Header = @fieldParentPtr("node", current);
        if (hdr.size >= num_units) {
            if (hdr.size == num_units) {
                const p = prev.removeNext();
                assert(p == current);
            } else {
                // put the new header at the end of the current block
                hdr.size -= num_units;

                const new_hdr: *Header = &@as([*]Header, @ptrCast(current))[hdr.size];
                current = &new_hdr.node;
                new_hdr.size = num_units;
            }
            free_ptr = prev;
            return std.mem.asBytes(current).ptr + @sizeOf(Header);
        }

        // if we reached the end, we don't have enough space and call morecore
        // to get more from the OS
        if (current == free_ptr) {
            current = morecore(num_units) orelse return null;
        }
    }
}

fn free(
    ctx: *anyopaque,
    buf: []u8,
    alignment: mem.Alignment,
    return_address: usize,
) void {
    assert(@sizeOf(Header) % alignment.toByteUnits() == 0);
    _ = ctx;
    _ = return_address;

    const hdr: *Header = @ptrCast(@alignCast(buf.ptr - @sizeOf(Header)));
    const free_addr = @intFromPtr(&hdr.node);

    // find the place in the free list for buf based on address
    var current = free_ptr;
    var next = current.next.?;
    while (!(free_addr > @intFromPtr(current) and free_addr < @intFromPtr(next))) : ({
        current = next;
        next = current.next.?;
    }) {
        const current_addr = @intFromPtr(current);
        const next_addr = @intFromPtr(next);

        if (current_addr >= next_addr and
            (free_addr > current_addr or free_addr < next_addr))
        {
            break;
        }
    }

    // try to combine buf and next
    if (free_addr + hdr.size * @sizeOf(Header) == @intFromPtr(next)) {
        const next_hdr: *Header = @fieldParentPtr("node", next);
        hdr.size += next_hdr.size;
        hdr.node.next = next.next;
    } else {
        hdr.node.next = next;
    }

    // try to combine current and buf
    const current_hdr: *Header = @fieldParentPtr("node", current);
    if (@intFromPtr(current) + current_hdr.size * @sizeOf(Header) == free_addr) {
        current_hdr.size += hdr.size;
        current_hdr.node.next = hdr.node.next;
    } else {
        current_hdr.node.next = &hdr.node;
    }

    free_ptr = current;
}

fn resize(
    ctx: *anyopaque,
    buf: []u8,
    alignment: mem.Alignment,
    new_len: usize,
    return_address: usize,
) bool {
    assert(@sizeOf(Header) % alignment.toByteUnits() == 0);
    _ = ctx;
    _ = buf;
    _ = return_address;
    _ = new_len;

    return false;
}

fn remap(
    ctx: *anyopaque,
    buf: []u8,
    alignment: mem.Alignment,
    new_len: usize,
    return_address: usize,
) ?[*]u8 {
    return if (resize(ctx, buf, alignment, new_len, return_address))
        buf.ptr
    else
        null;
}

/// Request more memory from the operating system using sbrk.
/// Returns null if couldn't get more memory.
fn morecore(num_units: u64) ?*SinglyLinkedList.Node {
    var nu = num_units;
    if (nu < 4096)
        nu = 4096;

    const addr = syscall.sbrk(
        @intCast(nu * @sizeOf(Header)),
        defs.SbrkType.eager,
    ) catch return null;
    var header: *Header = @ptrFromInt(addr);
    header.size = nu;

    allocator.free(
        (std.mem.asBytes(header).ptr + @sizeOf(Header))[0 .. (nu - 1) * @sizeOf(Header)],
    );
    return free_ptr;
}
