//! System calls, the main interface for user programs to request the OS to perform
//! some service.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const elf = std.elf;

const params = @import("shared").params;
const SyscallNum = @import("shared").syscall.Num;

const fmt = @import("fmt.zig");
const fs = @import("fs.zig");
const log = @import("fs/log.zig");
const heap = @import("heap.zig");
const proc = @import("proc.zig");
const riscv = @import("riscv.zig");
const sys_fs = @import("syscall/fs.zig");
const sys_proc = @import("syscall/proc.zig");
const vm = @import("vm.zig");

/// Main logic for handling a syscall.
pub fn handle() void {
    const p = proc.myProc().?;
    const trap_frame = p.private.trap_frame.?;

    const num = trap_frame.a7;
    if (std.enums.fromInt(SyscallNum, num)) |sys_num| {
        // Use num to lookup the system call function for num, call it,
        // and store its return value in p.private.trap_frame.a0
        trap_frame.a0 = switch (sys_num) {
            .fork => sys_proc.fork(),
            .exit => sys_proc.exit(),
            .wait => sys_proc.wait(),
            .pipe => @panic("todo pipe"),
            .read => sys_fs.read(),
            .kill => sys_proc.kill(),
            .exec => sys_fs.exec(),
            .fstat => @panic("todo fstat"),
            .chdir => @panic("todo chdir"),
            .dup => sys_fs.dup(),
            .getpid => @panic("todo getpid"),
            .sbrk => sys_proc.sbrk(),
            .pause => @panic("todo pause"),
            .uptime => sys_proc.uptime(),
            .open => sys_fs.open(),
            .write => sys_fs.write(),
            .mknod => sys_fs.mknod(),
            .unlink => @panic("todo unlink"),
            .link => sys_fs.link(),
            .mkdir => @panic("todo mkdir"),
            .close => sys_fs.close(),
        } catch std.math.maxInt(u64);
    } else {
        fmt.println(
            "{d} {s}: unknown sys call {d}",
            .{ p.public.pid.?, p.private.name, num },
        );
        trap_frame.a0 = std.math.maxInt(u64);
    }
}

/// Fetch the nth 32-bit system call argument.
pub fn intArg(n: u3) u32 {
    return @intCast(rawArg(n));
}

/// Fetch the nth word-sized system call argument as a string.
/// Copies into buf, at most buf.len.
/// Returns string if OK or error.
pub fn strArg(n: u3, dst: [:0]u8) ![:0]u8 {
    const addr = rawArg(n);
    return try fetchStr(dst, addr);
}

/// Fetch the nth system call argument as a raw 64-bit integer.
pub fn rawArg(n: u3) u64 {
    const p = proc.myProc().?;
    const trap_frame = p.private.trap_frame.?;

    return switch (n) {
        0 => trap_frame.a0,
        1 => trap_frame.a1,
        2 => trap_frame.a2,
        3 => trap_frame.a3,
        4 => trap_frame.a4,
        5 => trap_frame.a5,
        else => std.debug.panic("invalid raw arg num: {d}", .{n}),
    };
}

// Fetch the u64 at addr from the current process.
pub fn fetchAddr(addr: u64) !u64 {
    const p = proc.myProc().?;
    if (addr >= p.private.size or addr + @sizeOf(u64) > p.private.size)
        return error.AddrOutOfRange;

    var dst: u64 = undefined;
    try p.private.page_table.?.copyIn(
        heap.page_allocator,
        std.mem.asBytes(&dst),
        addr,
    );
    return dst;
}

/// Fetch the nul-terminated string at addr from the current process.
/// Returns string or an error.
pub fn fetchStr(dst: [:0]u8, src_addr: u64) ![:0]u8 {
    const p = proc.myProc().?;
    return try p.private.page_table.?.copyInStr(dst, src_addr);
}

/// The implementation of the exec() system call.
pub fn kexec(path: []const u8, argv: [*]const ?[:0]const u8) !u64 {
    var size: u64 = 0;
    const allocator = heap.page_allocator;
    const p = proc.myProc().?;

    const page_table = try proc.createPageTable(allocator, p);
    errdefer proc.freePageTable(allocator, page_table, size);

    const entry = value: {
        log.beginOp();
        defer log.endOp();

        var inode = try fs.lookupPath(allocator, path);
        defer inode.unlockPut();
        inode.lock();

        var hdr_buf: [@sizeOf(elf.Ehdr)]u8 = undefined;
        const read = try inode.read(allocator, .{ .kernel = &hdr_buf }, 0);
        assert(read == hdr_buf.len);

        var hdr_reader = std.Io.Reader.fixed(&hdr_buf);
        const hdr = try elf.Header.read(&hdr_reader);

        // Load program into memory.
        for (0..hdr.phnum) |idx| {
            const off = hdr.phoff + idx * @sizeOf(elf.Phdr);

            var prog_hdr: elf.Phdr = undefined;
            const rd = try inode.read(
                allocator,
                .{ .kernel = std.mem.asBytes(&prog_hdr) },
                @intCast(off),
            );
            assert(rd == @sizeOf(elf.Phdr));

            if (prog_hdr.p_type != elf.PT_LOAD)
                continue;
            if (prog_hdr.p_memsz < prog_hdr.p_filesz or
                prog_hdr.p_vaddr + prog_hdr.p_memsz < prog_hdr.p_vaddr or
                prog_hdr.p_vaddr % riscv.PAGE_SIZE != 0)
                return error.InvalidElf;

            size = try page_table.grow(
                allocator,
                size,
                prog_hdr.p_vaddr + prog_hdr.p_memsz,
                flagsToPerms(prog_hdr.p_flags),
            );
            try loadSeg(
                allocator,
                page_table,
                inode,
                prog_hdr.p_vaddr,
                prog_hdr.p_offset,
                prog_hdr.p_filesz,
            );
        }

        break :value hdr.entry;
    };

    // TODO: assign myproc again?

    const old_size = p.private.size;

    // Allocate some pages at the next page boundary.
    // Make the first inaccessible as a stack guard.
    // Use the rest as the user stack.
    size = riscv.pageRoundUp(size);
    size = try page_table.grow(
        allocator,
        size,
        size + params.USER_STACK_SIZE + riscv.PAGE_SIZE,
        .{ .writable = true },
    );
    page_table.clear(size - (params.USER_STACK_SIZE + riscv.PAGE_SIZE));

    // Copy argument strings into new stack, remember their addresses in ustack.
    var ustack: [params.MAX_ARGS]u64 = undefined;
    var sp = size;
    const stack_base = sp - params.USER_STACK_SIZE;

    var argc: u64 = 0;
    while (argv[argc]) |arg| : (argc += 1) {
        if (argc >= params.MAX_ARGS)
            return error.TooManyArgs;

        // riscv sp must be 16-byte aligned
        sp -= arg.len + 1;
        sp -= sp % 16;

        if (sp < stack_base)
            return error.OutOfUserStack;
        try page_table.copyOut(allocator, sp, arg[0 .. arg.len + 1]);
        ustack[argc] = sp;
    }
    ustack[argc] = 0;

    // push a copy of ustack, the array of argv pointers.
    sp -= (argc + 1) * @sizeOf(u64);
    sp -= sp % 16;
    if (sp < stack_base)
        return error.OutOfUserStack;
    try page_table.copyOut(
        allocator,
        sp,
        std.mem.sliceAsBytes(ustack[0 .. argc + 1]),
    );

    // a0 and a1 contain arguments to user main(argc, argv)
    // argc is returned via the system call return
    // value, which goes in a0.
    p.private.trap_frame.?.a1 = sp;

    // Save program name for debugging.
    var it = std.mem.splitBackwardsScalar(u8, path, '/');
    const name = it.next().?;
    const name_len = @min(p.private.name.len, name.len);
    @memcpy(p.private.name[0..name_len], name[0..name_len]);

    // Commit to the user image.
    const old_page_table = p.private.page_table.?;
    p.private.page_table = page_table;
    p.private.size = size;
    p.private.trap_frame.?.epc = entry;
    p.private.trap_frame.?.sp = sp;
    proc.freePageTable(allocator, old_page_table, old_size);

    // this ends up in a0, the first argument to main(argc, argv)
    return argc;
}

/// Load an ELF program segment into pagetable at virtual address va.
/// va must be page-aligned and the pages from va to va+sz must already be mapped.
fn loadSeg(
    allocator: Allocator,
    page_table: vm.PageTable(.user),
    inode: *fs.Inode,
    va: u64,
    hdr_off: u64,
    hdr_size: u64,
) !void {
    assert(va % riscv.PAGE_SIZE == 0);

    var va_off: u64 = 0;
    while (va_off < hdr_size) : (va_off += riscv.PAGE_SIZE) {
        const pa = page_table.walkAddr(va + va_off) catch |err|
            std.debug.panic(
                "address 0x{x} should exist but didn't: {}",
                .{ va + va_off, err },
            );
        const n = if (hdr_size - va_off < riscv.PAGE_SIZE)
            hdr_size - va_off
        else
            riscv.PAGE_SIZE;

        const mem = @as([*]u8, @ptrFromInt(pa))[0..n];
        const read = try inode.read(
            allocator,
            .{ .kernel = mem },
            @intCast(hdr_off + va_off),
        );
        if (read != n)
            return error.FailedToLoadSegment;
    }
}

/// Map ELF permissions to PTE permission bits.
fn flagsToPerms(flags: u32) vm.PageTableEntry.Perms {
    var perms: vm.PageTableEntry.Perms = .{};
    if (flags & 0x1 != 0)
        perms.executable = true;
    if (flags & 0x2 != 0)
        perms.writable = true;
    return perms;
}
