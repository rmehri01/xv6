//! Provides functions and constants for interacting with RISC-V specific registers.

const std = @import("std");
const assert = std.debug.assert;

const proc = @import("proc.zig");

/// Bytes per page.
pub const PAGE_SIZE = 4096;

// Machine Status Register
/// Previous Mode
pub const MSTATUS_MPP_MASK = 3 << 11;
/// Machine
pub const MSTATUS_MPP_M = 3 << 11;
/// Supervisor
pub const MSTATUS_MPP_S = 1 << 11;
/// User
pub const MSTATUS_MPP_U = 0 << 11;

// Supervisor Status Register
/// Previous mode, 1=Supervisor, 0=User
pub const SSTATUS_SPP = 1 << 8;
/// Supervisor Previous Interrupt Enable
pub const SSTATUS_SPIE = 1 << 5;
/// User Previous Interrupt Enable
pub const SSTATUS_UPIE = 1 << 4;
/// Supervisor Interrupt Enable
pub const SSTATUS_SIE = 1 << 1;
/// User Interrupt Enable
pub const SSTATUS_UIE = 1 << 0;

// Supervisor Interrupt Enable
/// External
pub const SIE_SEIE = 1 << 9;
/// Timer
pub const SIE_STIE = 1 << 5;

// Machine-mode Interrupt Enable
/// Supervisor Timer
pub const MIE_STIE = 1 << 5;

/// use riscv's sv39 page table scheme.
pub const SATP_SV39 = 8 << 60;

/// Control status registers that are readable.
pub const ReadCSR = enum {
    mstatus,
    sstatus,
    mhartid,
    menvcfg,
    mcounteren,
    mie,
    sie,
    time,
};

/// Read from the given control status register.
pub fn csrr(comptime reg: ReadCSR) u64 {
    return asm volatile (std.fmt.comptimePrint("csrr %[ret], {s}", .{@tagName(reg)})
        : [ret] "=r" (-> u64),
    );
}

/// Control status registers that are writable.
pub const WriteCSR = enum {
    mstatus,
    sstatus,
    mepc,
    medeleg,
    mideleg,
    menvcfg,
    mcounteren,
    satp,
    mie,
    sie,
    pmpaddr0,
    pmpcfg0,
    stimecmp,
};

/// Write a value to the given control status register.
pub fn csrw(comptime reg: WriteCSR, val: u64) void {
    asm volatile (std.fmt.comptimePrint("csrw {s}, %[val]", .{@tagName(reg)})
        :
        : [val] "r" (val),
    );
}

/// Read from the given register.
pub fn read(comptime reg: enum { tp }) u64 {
    return asm volatile (std.fmt.comptimePrint("mv %[ret], {s}", .{@tagName(reg)})
        : [ret] "=r" (-> u64),
    );
}

/// Write a value to the given register.
pub fn write(comptime reg: enum { tp }, val: u64) void {
    asm volatile (std.fmt.comptimePrint("mv {s}, %[val]", .{@tagName(reg)})
        :
        : [val] "r" (val),
    );
}

/// The unique id for the current CPU. Must be called with interrupts disabled,
/// to prevent race with process being moved to a different CPU.
pub fn cpuId() u8 {
    return @intCast(read(.tp));
}

/// Like intrOn except it must be matched with a corresponding popIntrOff.
/// Also stores the state of if interrupts were on or off.
pub fn pushIntrOff() void {
    const old = intrGet();

    // disable interrupts to prevent an involuntary context
    // switch while using mycpu().
    intrOff();

    const cpu = proc.myCpu();
    if (cpu.num_off == 0)
        cpu.interrupts_enabled = old;
    cpu.num_off += 1;
}

/// Like intrOff except it must be matched with a corresponding pushIntrOff.
/// Also restores the state of if interrupts were on or off.
pub fn popIntrOff() void {
    const cpu = proc.myCpu();

    assert(!intrGet());
    assert(cpu.num_off >= 1);

    cpu.num_off -= 1;
    if (cpu.num_off == 0 and cpu.interrupts_enabled)
        intrOn();
}

/// Enable device interrupts.
pub fn intrOn() void {
    const sstatus = csrr(.sstatus);
    csrw(.sstatus, sstatus | SSTATUS_SIE);
}

// Disable device interrupts.
pub fn intrOff() void {
    const sstatus = csrr(.sstatus);
    csrw(.sstatus, sstatus & ~@as(u64, SSTATUS_SIE));
}

// Are device interrupts enabled?
pub fn intrGet() bool {
    const sstatus = csrr(.sstatus);
    return (sstatus & SSTATUS_SIE) != 0;
}

/// One beyond the highest possible virtual address.
/// MAX_VA is actually one bit less than the max allowed by
/// Sv39, to avoid having to sign-extend virtual addresses
/// that have the high bit set.
pub const MAX_VA = 1 << (9 + 9 + 9 + 12 - 1);

/// Flush the TLB.
pub fn sfenceVma() void {
    // zero, zero flushes all TLB entries
    asm volatile ("sfence.vma zero, zero");
}
