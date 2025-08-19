//! The main entry point for zig. Also see entry.S

const main = @import("main.zig");
const params = @import("params.zig");
const riscv = @import("riscv.zig");

pub const panic = main.panic;

/// entry.S needs one stack per CPU.
export const stack0: [params.STACK_SIZE * params.NCPU]u8 align(16) = undefined;

/// entry.S jumps here in machine mode on stack0.
export fn start() noreturn {
    // set M Previous Privilege mode to Supervisor, for mret.
    var mstatus = riscv.csrr(.mstatus);
    mstatus &= ~@as(u64, riscv.MSTATUS_MPP_MASK);
    mstatus |= riscv.MSTATUS_MPP_S;
    riscv.csrw(.mstatus, mstatus);

    // set M Exception Program Counter to kmain, for mret.
    // requires gcc -mcmodel=medany
    riscv.csrw(.mepc, @intFromPtr(&main.kmain));

    // disable paging for now.
    riscv.csrw(.satp, 0);

    // delegate all interrupts and exceptions to supervisor mode.
    riscv.csrw(.medeleg, 0xffff);
    riscv.csrw(.mideleg, 0xffff);

    const sie = riscv.csrr(.sie);
    riscv.csrw(.sie, sie | riscv.SIE_SEIE | riscv.SIE_STIE);

    // configure Physical Memory Protection to give supervisor mode
    // access to all of physical memory.
    riscv.csrw(.pmpaddr0, 0x3fffffffffffff);
    riscv.csrw(.pmpcfg0, 0xf);

    // ask for clock interrupts.
    timerInit();

    // keep each CPU's hartid in its tp register, for cpuid().
    const id = riscv.csrr(.mhartid);
    riscv.write(.tp, id);

    // switch to supervisor mode and jump to main().
    asm volatile ("mret");
    unreachable;
}

/// Ask each hart to generate timer interrupts.
fn timerInit() void {
    // enable supervisor-mode timer interrupts.
    const mie = riscv.csrr(.mie);
    riscv.csrw(.mie, mie | riscv.MIE_STIE);

    // enable the sstc extension (i.e. stimecmp).
    const menvcfg = riscv.csrr(.menvcfg);
    riscv.csrw(.menvcfg, menvcfg | (1 << 63));

    // allow supervisor to use stimecmp and time.
    const mcounteren = riscv.csrr(.mcounteren);
    riscv.csrw(.mcounteren, mcounteren | 2);

    // ask for the very first timer interrupt.
    const time = riscv.csrr(.time);
    riscv.csrw(.stimecmp, time + params.TIMER_INTERVAL);
}
