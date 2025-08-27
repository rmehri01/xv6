//! init: The initial user-level program

export fn _start() void {
    asm volatile (
        \\ li a0, 1
        \\ li a7, 6
        \\ ecall
    );
}
