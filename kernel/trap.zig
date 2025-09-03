//! Events that force transfer of control into the kernel such as
//! syscalls, exceptions, and interrupts.

const std = @import("std");
const assert = std.debug.assert;

const params = @import("shared").params;

const fmt = @import("fmt.zig");
const virtio = @import("fs/virtio.zig");
const heap = @import("heap.zig");
const memlayout = @import("memlayout.zig");
const plic = @import("plic.zig");
const proc = @import("proc.zig");
const riscv = @import("riscv.zig");
const syscall = @import("syscall.zig");
const uart = @import("uart.zig");

pub var ticks: std.atomic.Value(usize) = .init(0);

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
                    .virtio => virtio.handleIntr(),
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
        proc.wakeUp(@intFromPtr(&ticks));
    }

    const time = riscv.csrr(.time);
    riscv.csrw(.stimecmp, time + params.TIMER_INTERVAL);
}

/// Set up trapframe and control registers for a return to user space.
pub fn prepareReturn() void {
    const p = proc.myProc().?;

    // We're about to switch the destination of traps from
    // kernelTrap() to userTrap(). Because a trap from kernel
    // code to userTrap would be a disaster, turn off interrupts.
    riscv.intrOff();

    // Send syscalls, interrupts, and exceptions to userVec in trampoline.S
    const trampoline_user_vec = memlayout.TRAMPOLINE;
    riscv.csrw(.stvec, trampoline_user_vec);

    // Set up trapframe values that userVec will need when
    // the process next traps into the kernel.
    const trap_frame = p.private.trap_frame.?;
    // kernel page table
    trap_frame.kernel_satp = riscv.csrr(.satp);
    // process's kernel stack
    trap_frame.kernel_sp = p.private.kstack + params.STACK_SIZE;
    trap_frame.kernel_trap = @intFromPtr(&userTrap);
    // hartid for cpuid()
    trap_frame.kernel_hartid = riscv.read(.tp);

    // Set up the registers that trampoline.S's sret will use
    // to get to user space.

    // Set S Previous Privilege mode to User.
    var sstatus = riscv.csrr(.sstatus);
    // clear SPP to 0 for user mode
    sstatus &= ~@as(u64, riscv.SSTATUS_SPP);
    // enable interrupts in user mode
    sstatus |= riscv.SSTATUS_SPIE;
    riscv.csrw(.sstatus, sstatus);

    // Set S Exception Program Counter to the saved user pc.
    riscv.csrw(.sepc, trap_frame.epc);
}

/// Handle an interrupt, exception, or system call from user space.
/// called from, and returns to, trampoline.S.
/// Return value is user satp for trampoline.S to switch to.
fn userTrap() callconv(.c) u64 {
    assert(riscv.csrr(.sstatus) & riscv.SSTATUS_SPP == 0);

    // send interrupts and exceptions to kerneltrap(),
    // since we're now in the kernel.
    riscv.csrw(.stvec, @intFromPtr(&kernelVec));

    const p = proc.myProc().?;

    // save user program counter.
    p.private.trap_frame.?.epc = riscv.csrr(.sepc);

    var is_timer = false;
    const scause = riscv.csrr(.scause);
    if (scause == 8) {
        // system call

        if (p.isKilled())
            proc.exit(-1);

        // sepc points to the ecall instruction,
        // but we want to return to the next instruction.
        p.private.trap_frame.?.epc += 4;

        // an interrupt will change sepc, scause, and sstatus,
        // so enable only now that we're done with those registers.
        riscv.intrOn();
        syscall.handle();
    } else if (value: {
        const dev_intr = handleDevIntr();
        is_timer = dev_intr == .timer;
        break :value dev_intr != .unknown;
    }) {
        // ok
    } else if ((scause == 15 or scause == 13) and
        if (p.private.page_table.?.handleFault(
            heap.page_allocator,
            riscv.csrr(.stval),
        )) |_| true else |_| false)
    {
        // page fault on lazily-allocated page
    } else {
        fmt.println(
            "unexpected user trap: scause=0x{x} pid={d} sepc=0x{x:0>16} stval=0x{x}",
            .{ scause, p.public.pid.?, riscv.csrr(.sepc), riscv.csrr(.stval) },
        );
        p.setKilled();
    }

    if (p.isKilled())
        proc.exit(-1);

    // Give up the CPU if this is a timer interrupt.
    if (is_timer)
        p.yield();

    prepareReturn();

    // The user page table to switch to, for trampoline.S
    const satp = p.private.page_table.?.makeSatp();
    // Return to trampoline.S; satp value in a0.
    return satp;
}
