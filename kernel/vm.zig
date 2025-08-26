//! Virtual memory and page tables.

const std = @import("std");
const atomic = std.atomic;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const fmt = @import("fmt.zig");
const memlayout = @import("memlayout.zig");
const params = @import("params.zig");
const riscv = @import("riscv.zig");
const trampoline = @import("trampoline.zig");

/// kernel.ld sets this to end of kernel code.
extern const etext: opaque {};

/// Number of page table entries.
const PTES = riscv.PAGE_SIZE / @sizeOf(PageTableEntry);
comptime {
    assert(PTES == 512);
}

/// The kernel's page table.
var kernel_pagetable: PageTable(.kernel) = undefined;

/// Initialize the direct-map kernel_pagetable, shared by all CPUs.
pub fn init(allocator: Allocator) !void {
    const entries = try allocator.create([PTES]PageTableEntry);
    @memset(entries, .{});

    const init_pt: PageTable(.kernel) = .{ .entries = entries };

    // uart registers
    try init_pt.kmap(
        allocator,
        memlayout.UART0,
        memlayout.UART0,
        riscv.PAGE_SIZE,
        .{ .readable = true, .writable = true },
    );

    // virtio mmio disk interface
    try init_pt.kmap(
        allocator,
        memlayout.VIRTIO0,
        memlayout.VIRTIO0,
        riscv.PAGE_SIZE,
        .{ .readable = true, .writable = true },
    );

    // PLIC
    try init_pt.kmap(
        allocator,
        memlayout.PLIC,
        memlayout.PLIC,
        0x4000000,
        .{ .readable = true, .writable = true },
    );

    // map kernel text executable and read-only.
    const etext_addr = @intFromPtr(&etext);
    try init_pt.kmap(
        allocator,
        memlayout.KERN_BASE,
        memlayout.KERN_BASE,
        etext_addr - memlayout.KERN_BASE,
        .{ .readable = true, .executable = true },
    );

    // map kernel data and the physical RAM we'll make use of.
    try init_pt.kmap(
        allocator,
        etext_addr,
        etext_addr,
        memlayout.PHYS_STOP - etext_addr,
        .{ .readable = true, .writable = true },
    );

    // map the trampoline for trap entry/exit to
    // the highest virtual address in the kernel.
    try init_pt.kmap(
        allocator,
        memlayout.TRAMPOLINE,
        @intFromPtr(&trampoline.userVec),
        riscv.PAGE_SIZE,
        .{ .readable = true, .executable = true },
    );

    // allocate and map a kernel stack for each process.
    for (0..params.MAX_PROCS) |proc_num| {
        // Allocate a page for each process's kernel stack.
        // Map it high in memory, followed by an invalid
        // guard page.
        const pa = try allocator.alloc(u8, riscv.PAGE_SIZE);
        const va = kStackVAddr(proc_num);
        try init_pt.kmap(
            allocator,
            va,
            @intFromPtr(pa.ptr),
            riscv.PAGE_SIZE,
            .{
                .readable = true,
                .writable = true,
            },
        );
    }

    kernel_pagetable = init_pt;
}

/// Switch the current CPU's h/w page table register to
/// the kernel's page table, and enable paging.
pub fn initHart() void {
    riscv.sfenceVma();
    riscv.csrw(.satp, kernel_pagetable.makeSatp());
    riscv.sfenceVma();
}

/// Returns the virtual address for the given processes' kernel stack, leaving an extra
/// guard page to detect stack overflow.
pub fn kStackVAddr(proc_num: usize) usize {
    return memlayout.TRAMPOLINE - (proc_num + 1) * 2 * riscv.PAGE_SIZE;
}

/// Page tables have different operations depending if they are for the kernel or for users.
const PageTableKind = enum { kernel, user };

/// A way for the OS to provide each process with it's own private address space.
pub fn PageTable(kind: PageTableKind) type {
    return struct {
        entries: *[PTES]PageTableEntry,

        /// Add a mapping to the kernel page table, only used when booting.
        /// Does not flush TLB or enable paging.
        fn kmap(
            self: @This(),
            allocator: Allocator,
            va: u64,
            pa: u64,
            size: u64,
            perms: PtePerms,
        ) !void {
            comptime assert(kind == .kernel);
            try self.mapPages(allocator, va, pa, size, perms);
        }

        /// Create an empty user page table.
        pub fn init(allocator: Allocator) !@This() {
            comptime assert(kind == .user);

            const entries = try allocator.create([PTES]PageTableEntry);
            @memset(entries, .{});

            return .{ .entries = entries };
        }

        /// Free user memory pages, then free page-table pages.
        pub fn free(self: @This(), allocator: Allocator, size: usize) void {
            comptime assert(kind == .user);

            if (size > 0)
                self.unmap(allocator, 0, riscv.pageRoundUp(size) / riscv.PAGE_SIZE);
            self.freeWalk(allocator);
        }

        /// Remove num_pages of mappings starting from va. va must be
        /// page-aligned. It's OK if the mappings don't exist.
        /// Optionally free the physical memory if an allocator is provided.
        pub fn unmap(self: @This(), allocator: ?Allocator, va: u64, num_pages: u64) void {
            comptime assert(kind == .user);
            assert(va % riscv.PAGE_SIZE == 0);

            var a = va;
            while (a < va + num_pages * riscv.PAGE_SIZE) : (a += riscv.PAGE_SIZE) {
                // leaf page table entry allocated?
                const pte = self.walk(null, a) catch |err| {
                    assert(err == error.PteNotFound);
                    continue;
                };
                if (!pte.perms.valid)
                    continue;
                if (allocator) |alloc| {
                    alloc.destroy(@as(*[PTES]PageTableEntry, @ptrFromInt(pte.toPhysAddr())));
                }
                pte.* = .{};
            }
        }

        /// Recursively free page-table pages.
        /// All leaf mappings must already have been removed.
        pub fn freeWalk(self: @This(), allocator: Allocator) void {
            // there are 2^9 = 512 PTEs in a page table.
            for (0..PTES) |idx| {
                const pte = self.entries[idx];
                if (pte.perms.valid) {
                    assert(!pte.perms.readable);
                    assert(!pte.perms.writable);
                    assert(!pte.perms.executable);

                    // this PTE points to a lower-level page table.
                    const child: @This() = .{ .entries = @ptrFromInt(pte.toPhysAddr()) };
                    child.freeWalk(allocator);
                    self.entries[idx] = .{};
                }
            }
            allocator.destroy(self.entries);
        }

        /// Copy from kernel to user.
        /// Copy bytes from src to virtual address dst in a given page table.
        pub fn copyOut(self: @This(), dst: u64, src: []const u8) !void {
            // TODO: implement
            _ = self;
            _ = dst;
            _ = src;
        }

        /// Copy from user to kernel.
        /// Copy len bytes to dst from virtual address srcva in a given page table.
        pub fn copyIn(self: @This(), dst: []u8, src: u64) !void {
            // TODO: implement
            _ = self;
            _ = dst;
            _ = src;
        }

        /// Create PTEs for virtual addresses starting at va that refer to
        /// physical addresses starting at pa.
        /// va and size MUST be page-aligned.
        /// Returns an error if walk() couldn't allocate a needed page-table page.
        pub fn mapPages(
            self: @This(),
            allocator: ?Allocator,
            va: u64,
            pa: u64,
            size: u64,
            perms: PtePerms,
        ) !void {
            assert(va % riscv.PAGE_SIZE == 0);
            assert(size % riscv.PAGE_SIZE == 0);
            assert(size != 0);

            var vaddr = va;
            var paddr = pa;
            const last = va + size - riscv.PAGE_SIZE;
            while (vaddr <= last) : ({
                vaddr += riscv.PAGE_SIZE;
                paddr += riscv.PAGE_SIZE;
            }) {
                const pte = try self.walk(allocator, vaddr);
                assert(!pte.perms.valid);

                pte.* = PageTableEntry.fromPhysAddr(paddr);
                pte.perms = perms;
                pte.perms.valid = true;
            }
        }

        /// Return the address of the PTE in page table that corresponds to
        /// virtual address va. If an allocator is provided, create any
        /// required page-table pages.
        ///
        /// The risc-v Sv39 scheme has three levels of page-table
        /// pages. A page-table page contains 512 64-bit PTEs.
        /// A 64-bit virtual address is split into five fields:
        ///   39..63 -- must be zero.
        ///   30..38 -- 9 bits of level-2 index.
        ///   21..29 -- 9 bits of level-1 index.
        ///   12..20 -- 9 bits of level-0 index.
        ///    0..11 -- 12 bits of byte offset within the page.
        fn walk(self: @This(), allocator: ?Allocator, va: u64) !*PageTableEntry {
            assert(va < riscv.MAX_VA);

            var pt = self;
            var level: u2 = 2;
            while (level > 0) : (level -= 1) {
                const pte = &pt.entries[virtAddrIdxAtLevel(va, level)];
                if (pte.perms.valid) {
                    pt = .{ .entries = @ptrFromInt(pte.toPhysAddr()) };
                } else {
                    const alloc = allocator orelse return error.PteNotFound;
                    const entries = try alloc.create([PTES]PageTableEntry);
                    @memset(entries, .{});

                    pte.* = PageTableEntry.fromPhysAddr(@intFromPtr(entries));
                    pte.perms.valid = true;

                    pt = .{ .entries = entries };
                }
            }

            return &pt.entries[virtAddrIdxAtLevel(va, 0)];
        }

        /// Format the page table for writing to the SATP register.
        fn makeSatp(self: @This()) u64 {
            return riscv.SATP_SV39 | (@intFromPtr(self.entries) >> PAGE_SHIFT);
        }

        /// Prints the page table for debugging purposes.
        fn debugPrint(self: @This()) void {
            fmt.println("page table {*}", .{self.entries});
            self.debugPrintLevel(0, 2);
        }
        fn debugPrintLevel(self: @This(), va: u64, comptime level: u2) void {
            var vaddr = va;
            for (self.entries) |pte| {
                if (pte.perms.valid) {
                    fmt.println(
                        "  " ** (2 - level) ++ "0x{x:0>16}: pte {{ .pa = 0x{x:0>16}, .perms = 0b{b:0>8} }}",
                        .{ vaddr, pte.ppn, @as(u8, @bitCast(pte.perms)) },
                    );
                    if (level != 0) {
                        const next: @This() = .{ .entries = @ptrFromInt(pte.toPhysAddr()) };
                        next.debugPrintLevel(vaddr, level - 1);
                    }
                }
                vaddr += 1 << (@as(u6, level) * 9 + PAGE_SHIFT);
            }
        }
    };
}

/// A single entry in the page table that points to the next level and has permissions
/// for how it can be used.
const PageTableEntry = packed struct(u64) {
    /// Permissions.
    perms: PtePerms = .{},
    /// Reserved for supervisor software.
    rsw: u2 = 0,
    /// Physical Page Number.
    ppn: u44 = 0,
    reserved: u10 = 0,

    /// Produces a PTE with a ppn from the given physical address.
    fn fromPhysAddr(pa: u64) @This() {
        return .{ .ppn = @intCast(pa >> PAGE_SHIFT) };
    }

    /// Produces the physical address associated with this PTE's ppn.
    fn toPhysAddr(self: PageTableEntry) u64 {
        return @as(u64, self.ppn) << PAGE_SHIFT;
    }
};

/// Permissions for page table entries.
pub const PtePerms = packed struct(u8) {
    valid: bool = false,
    readable: bool = false,
    writable: bool = false,
    executable: bool = false,
    user: bool = false,
    global: bool = false,
    accessed: bool = false,
    dirty: bool = false,
};

/// 9 bits.
const VA_LEVEL_MASK = 0x1FF;
/// Bits of offset within a page.
const PAGE_SHIFT = 12;

/// Extract the three 9-bit page table indices from a virtual address.
fn virtAddrIdxAtLevel(va: u64, level: u2) u9 {
    return @intCast((va >> (PAGE_SHIFT + 9 * @as(u6, level))) & VA_LEVEL_MASK);
}
