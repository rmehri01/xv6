//! Provides functions and constants for interacting with RISC-V specific registers.

const std = @import("std");

// Machine Status Register
/// Previous Mode
pub const MSTATUS_MPP_MASK = 3 << 11;
/// Machine
pub const MSTATUS_MPP_M = 3 << 11;
/// Supervisor
pub const MSTATUS_MPP_S = 1 << 11;
/// User
pub const MSTATUS_MPP_U = 0 << 11;

// Supervisor Interrupt Enable
/// External
pub const SIE_SEIE = 1 << 9;
/// Timer
pub const SIE_STIE = 1 << 5;

// Machine-mode Interrupt Enable
/// Supervisor Timer
pub const MIE_STIE = 1 << 5;

/// Control status registers that are readable.
pub const ReadCSR = enum {
    mstatus,
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
pub fn cpu_id() u8 {
    return @intCast(read(.tp));
}
