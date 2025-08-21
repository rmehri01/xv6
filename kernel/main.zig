//! The main functionality of the kernel after the basic setup from start.zig
//! is completed.

const std = @import("std");

const fmt = @import("fmt.zig");
const heap = @import("heap.zig");
const riscv = @import("riscv.zig");
const trap = @import("trap.zig");
const uart = @import("uart.zig");
const vm = @import("vm.zig");
const plic = @import("plic.zig");

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);

    const cpu_id = riscv.cpuId();

    var w = &uart.sync_writer;
    w.mutex.lock();
    w.interface.print("hart {d}: KERNEL PANIC! {s}\n", .{ cpu_id, msg }) catch {};
    if (first_trace_addr) |first_addr| {
        var it = std.debug.StackIterator.init(first_addr, null);
        while (it.next()) |addr| {
            w.interface.print("  0x{x}\n", .{addr}) catch {};
        }
    }
    w.interface.flush() catch {};
    w.mutex.unlock();

    while (true) {}
}

var started = std.atomic.Value(bool).init(false);

/// start() jumps here in supervisor mode on all CPUs.
pub fn kmain() noreturn {
    const cpu_id = riscv.cpuId();
    if (cpu_id == 0) {
        uart.init();
        fmt.println("xv6 kernel is booting", .{});

        // physical page allocator
        heap.init();

        // create kernel page table
        vm.init(heap.page_allocator) catch @panic("failed to initialize virtual memory");
        // turn on paging
        vm.initHart();
        // install kernel trap vector
        trap.initHart();
        // set up interrupt controller
        plic.init();
        // ask PLIC for device interrupts
        plic.initHart();

        started.store(true, .release);
    } else {
        while (!started.load(.acquire)) {
            std.atomic.spinLoopHint();
        }

        fmt.println("hart {d}: starting", .{cpu_id});

        // turn on paging
        vm.initHart();
        // install kernel trap vector
        trap.initHart();
        // ask PLIC for device interrupts
        plic.initHart();
    }

    while (true) {}
}
