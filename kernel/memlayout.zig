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
//! PHYSTOP -- end RAM used by the kernel

// qemu puts UART registers here in physical memory.
pub const UART0 = 0x10000000;
pub const UART0_IRQ = 10;
