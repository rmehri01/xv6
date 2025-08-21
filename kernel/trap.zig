//! Events that force transfer of control into the kernel such as
//! syscalls, exceptions, and interrupts.

const std = @import("std");
const atomic = std.atomic;
const assert = std.debug.assert;

const params = @import("params.zig");
const plic = @import("plic.zig");
const uart = @import("uart.zig");
const proc = @import("proc.zig");
const riscv = @import("riscv.zig");

var ticks: atomic.Value(u32) = .init(0);

/// Set up to take exceptions and traps while in the kernel.
pub fn initHart() void {
    riscv.csrw(.stvec, @intFromPtr(&kernelVec));
}

/// Interrupts and exceptions while in supervisor mode come here.
///
/// The current stack is a kernel stack.
/// Push registers, call kernelTrap().
/// When kernelTrap() returns, restore registers, return.
fn kernelVec() align(4) callconv(.naked) noreturn {
    asm volatile (
        \\ # make room to save registers.
        \\ addi sp, sp, -256
        \\ 
        \\ # save caller-saved registers.
        \\ sd ra, 0(sp)
        \\ # sd sp, 8(sp)
        \\ sd gp, 16(sp)
        \\ sd tp, 24(sp)
        \\ sd t0, 32(sp)
        \\ sd t1, 40(sp)
        \\ sd t2, 48(sp)
        \\ sd a0, 72(sp)
        \\ sd a1, 80(sp)
        \\ sd a2, 88(sp)
        \\ sd a3, 96(sp)
        \\ sd a4, 104(sp)
        \\ sd a5, 112(sp)
        \\ sd a6, 120(sp)
        \\ sd a7, 128(sp)
        \\ sd t3, 216(sp)
        \\ sd t4, 224(sp)
        \\ sd t5, 232(sp)
        \\ sd t6, 240(sp)
        \\ 
        \\ # call the zig trap handler
        \\ call kernelTrap
        \\ 
        \\ # restore registers.
        \\ ld ra, 0(sp)
        \\ # ld sp, 8(sp)
        \\ ld gp, 16(sp)
        \\ # not tp (contains hartid), in case we moved CPUs
        \\ ld t0, 32(sp)
        \\ ld t1, 40(sp)
        \\ ld t2, 48(sp)
        \\ ld a0, 72(sp)
        \\ ld a1, 80(sp)
        \\ ld a2, 88(sp)
        \\ ld a3, 96(sp)
        \\ ld a4, 104(sp)
        \\ ld a5, 112(sp)
        \\ ld a6, 120(sp)
        \\ ld a7, 128(sp)
        \\ ld t3, 216(sp)
        \\ ld t4, 224(sp)
        \\ ld t5, 232(sp)
        \\ ld t6, 240(sp)
        \\ 
        \\ addi sp, sp, 256
        \\ 
        \\ # return to whatever we were doing in the kernel.
        \\ sret
    );
}

/// Interrupts and exceptions from kernel code go here via kernelVec,
/// on whatever the current kernel stack is.
export fn kernelTrap() void {
    const sepc = riscv.csrr(.sepc);
    const sstatus = riscv.csrr(.sstatus);

    assert(sstatus & riscv.SSTATUS_SPP != 0);
    assert(!riscv.intrGet());

    switch (handleDevIntr()) {
        .unknown => {
            // interrupt or trap from an unknown source
            const scause = riscv.csrr(.scause);
            const stval = riscv.csrr(.stval);
            std.debug.panic(
                "unknown kernel trap scause=0x{x} sepc=0x{x:0>16} stval=0x{x}",
                .{ scause, sepc, stval },
            );
        },
        .other => {},
        .timer => {
            // give up the CPU if this is a timer interrupt.
            if (proc.myProc()) |p|
                p.yield();
        },
    }

    // TODO: move after yield?
    // the yield() may have caused some traps to occur,
    // so restore trap registers for use by kernelVec's sepc instruction.
    riscv.csrw(.sepc, sepc);
    riscv.csrw(.sstatus, sstatus);
}

// Check if it's an external interrupt or software interrupt, and handle it.
fn handleDevIntr() enum { unknown, other, timer } {
    const scause = riscv.csrr(.scause);
    return switch (scause) {
        0x8000000000000009 => {
            // this is a supervisor external interrupt, via PLIC.

            // irq indicates which device interrupted.
            const irq = plic.claim();
            if (irq) |dev| {
                switch (dev) {
                    .uart => uart.handleIntr(),
                    .virtio => {
                        // TODO: virtio
                    },
                }

                // the PLIC allows each device to raise at most one
                // interrupt at a time; tell the PLIC the device is
                // now allowed to interrupt again.
                plic.complete(dev);
            }

            return .other;
        },
        0x8000000000000005 => {
            // timer interrupt.
            handleClockIntr();
            return .timer;
        },
        else => .unknown,
    };
}

/// Handles timer interrupts.
fn handleClockIntr() void {
    if (riscv.cpuId() == 0) {
        _ = ticks.fetchAdd(1, .acq_rel);
        // TODO: wakeup
    }

    const time = riscv.csrr(.time);
    riscv.csrw(.stimecmp, time + params.TIMER_INTERVAL);
}
