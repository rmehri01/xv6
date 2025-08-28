//! init: The initial user-level program

export fn _start() void {
    const hello_str = "hello from userspace!\n";
    asm volatile (
        \\ la a0, %[console]
        \\ li a1, 1
        \\ li a2, 0
        \\ li a7, 17
        \\ ecall
        \\ la a0, %[console]
        \\ li a1, 2
        \\ li a7, 15
        \\ ecall
        \\ la a0, 0
        \\ la a1, %[str_ptr]
        \\ li a2, %[str_len]
        \\ li a7, 16
        \\ ecall
        :
        : [console] "i" ("console"),
          [str_ptr] "i" (hello_str),
          [str_len] "i" (hello_str.len),
    );

    while (true) {}
}
