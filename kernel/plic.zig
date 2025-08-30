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
    const cpu_id = riscv.cpuId();

    // set enable bits for this hart's S-mode
    // for the uart and virtio disk.
    sEnable(cpu_id).* = (1 << Irq.uart.val()) | (1 << Irq.virtio.val());

    // set this hart's S-mode priority threshold to 0.
    sPriority(cpu_id).* = 0;
}

/// Ask the PLIC what interrupt we should serve.
pub fn claim() ?Irq {
    const cpuId = riscv.cpuId();
    const irq = sClaim(cpuId).*;
    return std.enums.fromInt(Irq, irq) orelse {
        if (irq != 0) {
            fmt.println("unexpected interrupt irq={d}", .{irq});
        }
        return null;
    };
}

/// Tell the PLIC we've served this IRQ.
pub fn complete(irq: Irq) void {
    const cpu_id = riscv.cpuId();
    sClaim(cpu_id).* = irq.val();
}

fn sEnable(cpu_id: u8) *u32 {
    return &plic[(0x2080 + @as(usize, cpu_id) * 0x100) / @sizeOf(u32)];
}

fn sPriority(cpu_id: u8) *u32 {
    return &plic[(0x201000 + @as(usize, cpu_id) * 0x2000) / @sizeOf(u32)];
}

fn sClaim(cpu_id: u8) *u32 {
    return &plic[(0x201004 + @as(usize, cpu_id) * 0x2000) / @sizeOf(u32)];
}
