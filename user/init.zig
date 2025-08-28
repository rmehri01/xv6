//! init: The initial user-level program

export fn _start() void {
    asm volatile (
        \\ la a0, %[console]
        \\ li a1, 1
        \\ li a2, 0
        \\ li a7, 17
        \\ ecall
        :
        : [console] "i" ("console"),
    );
}
