//! Physical memory layout.
//!
//! qemu -machine virt is set up like this,
//! based on qemu's hw/riscv/virt.c:
//!
//! 00001000 -- boot ROM, provided by qemu
//! 02000000 -- CLINT
//! 0C000000 -- PLIC
//! 10000000 -- uart0
//! 10001000 -- virtio disk
//! 80000000 -- qemu's boot ROM loads the kernel here,
//!             then jumps here.
//! unused RAM after 80000000.
//!
//! the kernel uses physical memory thus:
//! 80000000 -- entry.S, then kernel text and data
//! end -- start of kernel page allocation area
//! PHYS_STOP -- end RAM used by the kernel

const riscv = @import("riscv.zig");

// qemu puts UART registers here in physical memory.
pub const UART0 = 0x10000000;
pub const UART0_IRQ = 10;

// virtio mmio interface
pub const VIRTIO0 = 0x10001000;
pub const VIRTIO0_IRQ = 1;

// qemu puts platform-level interrupt controller (PLIC) here.
pub const PLIC = 0x0c000000;

// the kernel expects there to be RAM for use by the kernel and user pages
// from physical address 0x80000000 to PHYS_STOP.
pub const KERN_BASE = 0x80000000;
pub const PHYS_STOP = KERN_BASE + 128 * 1024 * 1024;

// map the trampoline page to the highest address,
// in both user and kernel space.
pub const TRAMPOLINE = riscv.MAX_VA - riscv.PAGE_SIZE;

// User memory layout.
// Address zero first:
//   text
//   original data and bss
//   fixed-size stack
//   expandable heap
//   ...
//   TRAPFRAME (p.trapframe, used by the trampoline)
//   TRAMPOLINE (the same page as in the kernel)
pub const TRAP_FRAME = TRAMPOLINE - riscv.PAGE_SIZE;
