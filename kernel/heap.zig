//! Memory allocation based on physical pages.

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const SinglyLinkedList = std.SinglyLinkedList;

const memlayout = @import("memlayout.zig");
const riscv = @import("riscv.zig");
const SpinLock = @import("sync/SpinLock.zig");

/// First address after kernel.
/// Defined by kernel.ld.
extern const end: opaque {};

/// Physical memory allocator, for user processes, kernel stacks, page-table pages,
/// and pipe buffers. Allocates whole 4096-byte pages.
pub var page_allocator: Allocator = undefined;
var page_allocator_impl: PageAllocator = undefined;

/// Initialize the `page_allocator` with all available physical memory.
pub fn init() void {
    page_allocator_impl = .init();
    page_allocator = page_allocator_impl.allocator();
}

const PageAllocator = struct {
    mutex: SpinLock = .{},
    free_list: SinglyLinkedList = .{},

    /// Initialize with all available physical memory.
    fn init() PageAllocator {
        var pg_alloc: PageAllocator = .{};
        pg_alloc.freeRange(@intFromPtr(&end), memlayout.PHYS_STOP);
        return pg_alloc;
    }

    /// Free a range of physical memory from `pa_start` to `pa_end`.
    fn freeRange(self: *PageAllocator, pa_start: usize, pa_end: usize) void {
        var p = riscv.pageRoundUp(pa_start);
        while (p + riscv.PAGE_SIZE <= pa_end) : (p += riscv.PAGE_SIZE) {
            free(
                self,
                @as([*]u8, @ptrFromInt(p))[0..riscv.PAGE_SIZE],
                .fromByteUnits(riscv.PAGE_SIZE),
                0,
            );
        }
    }

    /// Produces an implementation of the `Allocator` interface using this allocator.
    fn allocator(self: *PageAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }
};

/// Allocate one 4096-byte page of physical memory.
fn alloc(
    ctx: *anyopaque,
    n: usize,
    alignment: mem.Alignment,
    return_address: usize,
) ?[*]u8 {
    const self: *PageAllocator = @ptrCast(@alignCast(ctx));
    assert(n <= riscv.PAGE_SIZE);
    assert(riscv.PAGE_SIZE % alignment.toByteUnits() == 0);
    _ = return_address;

    self.mutex.lock();
    defer self.mutex.unlock();

    const node = self.free_list.popFirst() orelse return null;
    const ptr: [*]u8 = @ptrCast(node);

    // Fill with junk to catch dangling refs.
    @memset(ptr[0..riscv.PAGE_SIZE], 5);

    return ptr;
}

/// Free a page of physical memory, which should have been returned by a
/// call to alloc().
///
/// (The exception is when initializing the allocator; see init() above.)
fn free(
    ctx: *anyopaque,
    buf: []u8,
    alignment: mem.Alignment,
    return_address: usize,
) void {
    const self: *PageAllocator = @ptrCast(@alignCast(ctx));
    assert(riscv.PAGE_SIZE % alignment.toByteUnits() == 0);
    _ = return_address;

    const addr = @intFromPtr(buf.ptr);
    assert(addr % riscv.PAGE_SIZE == 0);
    assert(addr >= @intFromPtr(&end));
    assert(addr < memlayout.PHYS_STOP);
    assert(buf.len <= riscv.PAGE_SIZE);

    // Fill with junk to catch dangling refs.
    @memset(buf, 1);

    self.mutex.lock();
    defer self.mutex.unlock();

    self.free_list.prepend(@ptrCast(@alignCast(buf)));
}

/// Allow resizing as long as it is within the page.
fn resize(
    ctx: *anyopaque,
    buf: []u8,
    alignment: mem.Alignment,
    new_len: usize,
    return_address: usize,
) bool {
    _ = ctx;
    _ = buf;
    _ = alignment;
    _ = return_address;
    return new_len <= riscv.PAGE_SIZE;
}

/// Remap just wraps resize since extra allocations won't really help us.
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
