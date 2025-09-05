# xv6

An implementation of [xv6-riscv](https://github.com/mit-pdos/xv6-riscv) in Zig! Also runs in the browser using [qemu-wasm](https://github.com/ktock/qemu-wasm).

# Running Locally

The first time you need a file system image:

```console
zig build mkfs
```

After that you can run the kernel in QEMU with:

```console
zig build run -Doptimize=ReleaseSafe
```
