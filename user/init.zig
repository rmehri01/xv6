//! init: The initial user-level program

export fn _start() void {
    asm volatile ("ecall");
}
