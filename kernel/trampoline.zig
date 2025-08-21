//! Low-level code to handle traps from user space into
//! the kernel, and returns from kernel to user.
//!
//! The kernel maps the page holding this code
//! at the same virtual address (TRAMPOLINE)
//! in user and kernel space so that it continues
//! to work when it switches page tables.
//! kernel.ld causes this code to start at
//! a page boundary.

pub fn userVec() align(4) linksection("trampsec") callconv(.naked) void {}

pub fn userRet() linksection("trampsec") callconv(.naked) void {}
