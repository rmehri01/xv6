//! The RISC-V Platform Level Interrupt Controller (PLIC).

const std = @import("std");

const fmt = @import("fmt.zig");
const memlayout = @import("memlayout.zig");
const riscv = @import("riscv.zig");

/// Interrupt Request.
pub const Irq = enum(u32) {
    virtio = 1,
    uart = 10,

    inline fn val(self: Irq) u32 {
        return @intFromEnum(self);
    }
};

/// Pointer to the memory-mapped PLIC.
const plic: [*]u32 = @ptrFromInt(memlayout.PLIC);

pub fn init() void {
    // set desired IRQ priorities non-zero (otherwise disabled).
    plic[Irq.uart.val()] = 1;
    plic[Irq.virtio.val()] = 1;
}

pub fn initHart() void {
    const cpuId = riscv.cpuId();

    // set enable bits for this hart's S-mode
    // for the uart and virtio disk.
    sEnable(cpuId).* = (1 << Irq.uart.val()) | (1 << Irq.virtio.val());

    // set this hart's S-mode priority threshold to 0.
    sPriority(cpuId).* = 0;
}

/// Ask the PLIC what interrupt we should serve.
pub fn claim() ?Irq {
    const cpuId = riscv.cpuId();
    const irq = sClaim(cpuId).*;
    return std.enums.fromInt(Irq, irq) orelse {
        fmt.println("unexpected interrupt irq={d}", .{irq});
        return null;
    };
}

/// Tell the PLIC we've served this IRQ.
pub fn complete(irq: Irq) void {
    const cpuId = riscv.cpuId();
    sClaim(cpuId).* = irq.val();
}

fn sEnable(cpuId: u8) *u32 {
    return &plic[(0x2080 + @as(usize, cpuId) * 0x100) / @sizeOf(u32)];
}

fn sPriority(cpuId: u8) *u32 {
    return &plic[(0x201000 + @as(usize, cpuId) * 0x2000) / @sizeOf(u32)];
}

fn sClaim(cpuId: u8) *u32 {
    return &plic[(0x201004 + @as(usize, cpuId) * 0x2000) / @sizeOf(u32)];
}
