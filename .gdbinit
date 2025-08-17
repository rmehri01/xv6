set confirm off
set architecture riscv:rv64
target remote localhost:1234
symbol-file zig-out/bin/kernel
set disassemble-next-line auto
set riscv use-compressed-breakpoints yes
