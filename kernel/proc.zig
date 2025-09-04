//! Processes and CPU state.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const params = @import("shared").params;

const fmt = @import("fmt.zig");
const fs = @import("fs.zig");
const file = @import("fs/file.zig");
const log = @import("fs/log.zig");
const memlayout = @import("memlayout.zig");
const riscv = @import("riscv.zig");
const SpinLock = @import("sync/SpinLock.zig");
const syscall = @import("syscall.zig");
const trap = @import("trap.zig");
const vm = @import("vm.zig");

// trampoline.S
extern const trampoline: opaque {};
extern const userRet: opaque {};

var cpus: [params.MAX_CPUS]Cpu = undefined;
var init_proc: *Process = undefined;
var procs: [params.MAX_PROCS]Process = init: {
    var init_procs: [params.MAX_PROCS]Process = undefined;

    for (0.., &init_procs) |proc_num, *proc| {
        proc.* = .{
            .mutex = .{},
            .parent = null,
            .public = .{
                .state = .unused,
                .killed = false,
                .pid = null,
            },
            .private = .{
                .kstack = vm.kStackVAddr(proc_num),
                .size = 0,
                .trap_frame = null,
                .page_table = null,
                .context = null,
                .open_files = .{null} ** params.NUM_FILE_PER_PROC,
                .cwd = null,
                .name = .{0} ** 16,
            },
        };
    }

    break :init init_procs;
};

/// Process ID.
pub const Pid = u32;
var next_pid: std.atomic.Value(Pid) = .init(1);
var first_proc: std.atomic.Value(bool) = .init(true);

/// Helps ensure that wakeups of wait()ing parents are not lost.
/// Helps obey the memory model when using p.parent.
/// Must be acquired before any p.mutex.
var wait_mutex: SpinLock = .{};

/// Per-CPU state.
pub const Cpu = struct {
    /// The process running on this cpu, or null.
    proc: ?*Process,
    /// ctxSwitch() here to enter runScheduler().
    context: Context,
    /// Depth of pushIntrOff() nesting.
    num_off: u32,
    /// Were interrupts enabled before pushIntrOff()?
    interrupts_enabled: bool,
};

/// Per-process state.
const Process = struct {
    /// Mutex that protects the public state of the process.
    mutex: SpinLock,
    /// Parent process. The wait_mutex must be held when using this.
    parent: ?*Process,
    /// Process mutex must be held while using these.
    public: struct {
        state: ProcessState,
        /// Has the process been killed?
        killed: bool,
        /// Process ID.
        pid: ?Pid,
    },
    /// These are private to the process, so p.mutex need not be held.
    private: struct {
        /// Virtual address of kernel stack.
        kstack: u64,
        /// Size of process memory (bytes)
        size: u64,
        /// Data page for trampoline.S
        trap_frame: ?*TrapFrame,
        /// User page table.
        page_table: ?vm.PageTable(.user),
        /// ctxSwitch() here to run process
        context: ?Context,
        /// Current directory
        cwd: ?*fs.Inode,
        /// Open files
        open_files: [params.NUM_FILE_PER_PROC]?*file.File,
        /// Process name (debugging)
        name: [16]u8,
    },

    /// Give up the CPU for one scheduling round.
    pub fn yield(self: *Process) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.public.state = .runnable;
        switchToScheduler();
    }

    /// Checks if the process has been killed.
    pub fn isKilled(self: *Process) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.public.killed;
    }

    /// Sets the process to be killed.
    pub fn setKilled(self: *Process) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.public.killed = true;
    }

    /// Pass this process' abandoned children to init.
    /// Caller must hold wait_lock.
    pub fn reparentChildren(self: *Process) void {
        for (&procs) |*proc| {
            if (proc.parent == self) {
                proc.parent = init_proc;
                wakeUp(@intFromPtr(init_proc));
            }
        }
    }

    /// Look in the process table for an unused proc.
    /// If found, initialize state required to run in the kernel,
    /// and return with p.mutex held.
    /// If there are no free procs, or a memory allocation fails, returns an error.
    fn alloc(allocator: Allocator) !*Process {
        const proc = for (&procs) |*proc| {
            proc.mutex.lock();
            if (proc.public.state == .unused) {
                break proc;
            } else {
                proc.mutex.unlock();
            }
        } else {
            return error.OutOfProcesses;
        };
        errdefer {
            proc.free(allocator);
            proc.mutex.unlock();
        }

        proc.public = .{
            .pid = next_pid.fetchAdd(1, .acq_rel),
            .killed = false,
            .state = .used,
        };
        // Allocate a trapframe page.
        proc.private.trap_frame = try allocator.create(TrapFrame);
        // An empty user page table.
        proc.private.page_table = try createPageTable(allocator, proc);

        // Set up new context to start executing at forkret,
        // which returns to user space.
        proc.private.context = std.mem.zeroInit(Context, .{
            .ra = @intFromPtr(&forkRet),
            .sp = proc.private.kstack + params.STACK_SIZE,
        });

        return proc;
    }

    /// Free a proc structure and the data hanging from it, including user pages.
    /// p.mutex must be held.
    fn free(self: *Process, allocator: Allocator) void {
        if (self.private.trap_frame) |trap_frame| {
            allocator.destroy(trap_frame);
        }
        if (self.private.page_table) |page_table| {
            freePageTable(allocator, page_table, self.private.size);
        }

        // TODO: others
        self.parent = null;
        self.public.state = .unused;
        self.public.killed = false;
        self.public.pid = null;
        self.private.size = 0;
        self.private.trap_frame = null;
        self.private.page_table = null;
        self.private.context = null;
        self.private.name = .{0} ** self.private.name.len;
    }
};

/// The possible states a process can be in.
const ProcessState = union(enum) {
    unused,
    used,
    sleeping: struct {
        /// Channel that this process is sleeping on.
        chan: usize,
    },
    runnable,
    running,
    zombie: struct {
        /// Exit status to be returned to parent's wait.
        exit_status: i32,
    },
};

/// Per-process data for the trap handling code in trampoline.S.
/// Sits in a page by itself just under the trampoline page in the
/// user page table. Not specially mapped in the kernel page table.
/// userVec in trampoline.S saves user registers in the trapframe,
/// then initializes registers from the trapframe's
/// kernel_sp, kernel_hartid, kernel_satp, and jumps to kernelTrap.
/// userTrapRet() and userRet in trampoline.S set up
/// the trapframe's kernel_*, restore user registers from the
/// trapframe, switch to the user page table, and enter user space.
/// The trapframe includes callee-saved user registers like s0-s11 because the
/// return-to-user path via userTrapRet() doesn't return through
/// the entire kernel call stack.
const TrapFrame = extern struct {
    /// kernel page table
    kernel_satp: u64,
    /// top of process's kernel stack
    kernel_sp: u64,
    /// userTrap()
    kernel_trap: u64,
    /// saved user program counter
    epc: u64,
    /// saved kernel tp
    kernel_hartid: u64,
    ra: u64,
    sp: u64,
    gp: u64,
    tp: u64,
    t0: u64,
    t1: u64,
    t2: u64,
    s0: u64,
    s1: u64,
    a0: u64,
    a1: u64,
    a2: u64,
    a3: u64,
    a4: u64,
    a5: u64,
    a6: u64,
    a7: u64,
    s2: u64,
    s3: u64,
    s4: u64,
    s5: u64,
    s6: u64,
    s7: u64,
    s8: u64,
    s9: u64,
    s10: u64,
    s11: u64,
    t3: u64,
    t4: u64,
    t5: u64,
    t6: u64,
};

/// Saved registers for kernel context switches.
const Context = extern struct {
    ra: u64,
    sp: u64,

    // callee-saved
    s0: u64,
    s1: u64,
    s2: u64,
    s3: u64,
    s4: u64,
    s5: u64,
    s6: u64,
    s7: u64,
    s8: u64,
    s9: u64,
    s10: u64,
    s11: u64,
};

/// Set up first user process.
pub fn userInit(allocator: Allocator) !void {
    init_proc = try .alloc(allocator);
    defer init_proc.mutex.unlock();

    init_proc.private.cwd = fs.lookupPath(allocator, "/") catch unreachable;
    init_proc.public.state = .runnable;
}

/// Create a user page table for a given process, with no user memory,
/// but with trampoline and trapframe pages.
pub fn createPageTable(allocator: Allocator, proc: *Process) !vm.PageTable(.user) {
    // An empty user page table.
    var page_table = try vm.PageTable(.user).init(allocator);
    errdefer page_table.free(allocator, 0);

    // Map the trampoline code (for system call return) at the highest user virtual address.
    // Only the supervisor uses it, on the way to/from user space, so not PTE_U.
    try page_table.mapPages(
        allocator,
        memlayout.TRAMPOLINE,
        @intFromPtr(&trampoline),
        riscv.PAGE_SIZE,
        .{ .readable = true, .executable = true },
    );
    errdefer page_table.unmap(null, memlayout.TRAMPOLINE, 1);

    // map the trapframe page just below the trampoline page, for trampoline.S.
    try page_table.mapPages(
        allocator,
        memlayout.TRAP_FRAME,
        @intFromPtr(proc.private.trap_frame.?),
        riscv.PAGE_SIZE,
        .{ .readable = true, .writable = true },
    );

    return page_table;
}

/// Free a process's page table, and free the physical memory it refers to.
pub fn freePageTable(allocator: Allocator, page_table: vm.PageTable(.user), size: u64) void {
    page_table.unmap(null, memlayout.TRAMPOLINE, 1);
    page_table.unmap(null, memlayout.TRAP_FRAME, 1);
    page_table.free(allocator, size);
}

/// A fork child's very first scheduling by runScheduler() will switch to forkRet.
fn forkRet() callconv(.c) void {
    const proc = myProc().?;

    // Still holding p.mutex from scheduler.
    proc.mutex.unlock();

    if (first_proc.load(.acquire)) {
        // File system initialization must be run in the context of a
        // regular process (e.g., because it calls sleep), and thus cannot
        // be run from kmain().
        fs.init(params.ROOT_DEV);
        first_proc.store(false, .release);

        // We can invoke kexec() now that file system is initialized.
        // Put the return value (argc) of kexec into a0.
        proc.private.trap_frame.?.a0 = syscall.kexec("/init", &.{ "/init", null }) catch |err|
            std.debug.panic("failed to exec init program: {}", .{err});
    }

    // return to user space, mimicking userTrap()'s return.
    trap.prepareReturn();

    const satp = proc.private.page_table.?.makeSatp();
    const trampoline_user_ret = memlayout.TRAMPOLINE +
        (@intFromPtr(&userRet) - @intFromPtr(&trampoline));
    @as(*const fn (u64) callconv(.c) void, @ptrFromInt(trampoline_user_ret))(satp);
}

/// Per-CPU process scheduler.
/// Each CPU calls runScheduler() after setting itself up.
/// Scheduler never returns. It loops, doing:
///  - choose a process to run.
///  - switch to start running that process.
///  - eventually that process transfers control
///    via switch back to the scheduler.
pub fn runScheduler() noreturn {
    const cpu = myCpu();

    sched_loop: while (true) {
        // The most recent process to run may have had interrupts
        // turned off; enable them to avoid a deadlock if all
        // processes are waiting. Then turn them back off
        // to avoid a possible race between an interrupt
        // and wfi.
        riscv.intrOn();
        riscv.intrOff();

        for (&procs) |*proc| {
            proc.mutex.lock();
            defer proc.mutex.unlock();

            if (proc.public.state == .runnable) {
                // Switch to chosen process. It is the process's job
                // to release its lock and then reacquire it
                // before jumping back to us.
                proc.public.state = .running;
                cpu.proc = proc;
                ctxSwitch(&cpu.context, &proc.private.context.?);

                // Process is done running for now.
                // It should have changed its p->state before coming back.
                cpu.proc = null;
                continue :sched_loop;
            }
        } else {
            // nothing to run; stop running on this core until an interrupt.
            asm volatile ("wfi");
        }
    }
}

/// Switch to scheduler. Must hold only p.mutex and have changed
/// proc.public.state. Saves and restores interrupts_enabled because
/// interrupts_enabled is a property of this kernel thread, not this CPU.
/// It should be proc.interrupts_enabled and proc.num_off, but that would
/// break in the few places where a lock is held but there's no process.
fn switchToScheduler() void {
    const proc = myProc().?;

    assert(proc.mutex.holding());
    assert(myCpu().num_off == 1);
    assert(proc.public.state != .running);
    assert(!riscv.intrGet());

    const interrupts_enabled = myCpu().interrupts_enabled;
    ctxSwitch(&proc.private.context.?, &myCpu().context);
    myCpu().interrupts_enabled = interrupts_enabled;
}

/// Context switch, save current registers in old and load from new.
extern fn ctxSwitch(old: *Context, new: *const Context) void;

/// Return the current process running on this cpu, or null if none.
pub fn myProc() ?*Process {
    riscv.pushIntrOff();
    defer riscv.popIntrOff();

    const cpu = myCpu();
    return cpu.proc;
}

/// Return this CPU's cpu struct.
/// Interrupts must be disabled.
pub fn myCpu() *Cpu {
    const cpuId = riscv.cpuId();
    return &cpus[cpuId];
}

/// Sleep on channel chan, releasing condition lock `mutex`.
/// Re-acquires `mutex` when awakened.
pub fn sleep(chan: usize, mutex: *SpinLock) void {
    const p = myProc().?;

    // Must acquire p.mutex in order to change p.public.state and then
    // call switchToScheduler(). Once we hold p.mutex, we can be guaranteed
    // that we won't miss any wakeup (wakeup locks p.mutex), so it's okay
    // to release mutex.
    p.mutex.lock();
    mutex.unlock();
    defer {
        // Reacquire original lock.
        p.mutex.unlock();
        mutex.lock();
    }

    // Go to sleep.
    p.public.state = .{ .sleeping = .{ .chan = chan } };
    switchToScheduler();
}

/// Wake up all processes sleeping on channel chan.
/// Caller should hold the condition lock.
pub fn wakeUp(chan: usize) void {
    const currentProc = myProc();
    for (&procs) |*proc| {
        if (proc != currentProc) {
            proc.mutex.lock();
            defer proc.mutex.unlock();

            const state = proc.public.state;
            if (state == .sleeping and
                state.sleeping.chan == chan)
            {
                proc.public.state = .runnable;
            }
        }
    }
}

/// Either a user or kernel piece of memory.
pub const EitherMem = union(enum) {
    user: struct { addr: u64, len: u64 },
    kernel: []u8,
};

/// Copy to either a user address, or kernel address, depending on dst.
pub fn eitherCopyOut(allocator: Allocator, dst: EitherMem, src: []const u8) !void {
    switch (dst) {
        .user => |dest| {
            const proc = myProc().?;
            assert(dest.len == src.len);
            return proc.private.page_table.?.copyOut(allocator, dest.addr, src);
        },
        .kernel => |dest| @memcpy(dest, src),
    }
}

/// Copy from either a user address, or kernel address, depending on src.
pub fn eitherCopyIn(allocator: Allocator, dst: []u8, src: EitherMem) !void {
    switch (src) {
        .user => |source| {
            const proc = myProc().?;
            assert(source.len == dst.len);
            return proc.private.page_table.?.copyIn(allocator, dst, source.addr);
        },
        .kernel => |source| @memcpy(dst, source),
    }
}

/// Grow user memory by bytes.
pub fn grow(allocator: Allocator, bytes: u32) !void {
    const proc = myProc().?;
    var size = proc.private.size;

    if (bytes > 0) {
        size = try proc.private.page_table.?.grow(
            allocator,
            size,
            size + bytes,
            .{ .writable = true },
        );
    }

    proc.private.size = size;
}

/// Exit the current process. Does not return.
/// An exited process remains in the zombie state
/// until its parent calls wait().
pub fn exit(status: i32) noreturn {
    const proc = myProc().?;
    if (proc == init_proc) {
        @panic("init exiting");
    }

    // Close all open files.
    for (0.., proc.private.open_files) |fd, maybe_file| {
        if (maybe_file) |f| {
            f.close();
            proc.private.open_files[fd] = null;
        }
    }

    log.beginOp();
    proc.private.cwd.?.put();
    log.endOp();
    proc.private.cwd = null;

    wait_mutex.lock();
    // Give any children to init.
    proc.reparentChildren();
    // Parent might be sleeping in wait().
    wakeUp(@intFromPtr(proc.parent.?));

    proc.mutex.lock();
    proc.public.state = .{ .zombie = .{ .exit_status = status } };
    wait_mutex.unlock();

    // Jump into the scheduler, never to return.
    switchToScheduler();
    @panic("zombie exit");
}

/// Create a new process, copying the parent.
/// Sets up child kernel stack to return as if from fork() system call.
pub fn fork(allocator: Allocator) !Pid {
    const parent = myProc().?;

    // Allocate process.
    const child = try Process.alloc(allocator);
    errdefer {
        child.free(allocator);
        child.mutex.unlock();
    }

    // Copy user memory from parent to child.
    try parent.private.page_table.?.copyTo(
        allocator,
        child.private.page_table.?,
        parent.private.size,
    );
    child.private.size = parent.private.size;

    // Copy saved user registers.
    child.private.trap_frame.?.* = parent.private.trap_frame.?.*;
    // Cause fork to return 0 in the child.
    child.private.trap_frame.?.a0 = 0;

    // Increment reference counts on open file descriptors.
    for (0..parent.private.open_files.len) |fd| {
        if (parent.private.open_files[fd]) |f| {
            child.private.open_files[fd] = f.dup();
        }
    }
    child.private.cwd = parent.private.cwd.?.dup();
    child.private.name = parent.private.name;

    const pid = child.public.pid.?;
    child.mutex.unlock();

    {
        wait_mutex.lock();
        defer wait_mutex.unlock();

        child.parent = parent;
    }

    {
        child.mutex.lock();
        defer child.mutex.unlock();

        child.public.state = .runnable;
    }

    return pid;
}

/// Wait for a child process to exit and return its pid,
/// optionally copying it's exit status to out_addr.
/// Return an if this process has no children.
pub fn wait(allocator: Allocator, out_addr: ?u64) !Pid {
    const parent = myProc().?;

    wait_mutex.lock();
    defer wait_mutex.unlock();

    while (true) {
        // Scan through table looking for exited children.
        var have_kids = false;

        for (&procs) |*child| {
            if (child.parent == parent) {
                // make sure the child isn't still in exit() or swtch().
                child.mutex.lock();
                defer child.mutex.unlock();

                have_kids = true;

                if (child.public.state == .zombie) {
                    // Found one.
                    const pid = child.public.pid.?;
                    if (out_addr) |addr| {
                        try parent.private.page_table.?.copyOut(
                            allocator,
                            addr,
                            std.mem.asBytes(&child.public.state.zombie),
                        );
                    }
                    child.free(allocator);
                    return pid;
                }
            }
        }

        // No point waiting if we don't have any children.
        if (!have_kids or parent.isKilled()) {
            return error.WaitFailed;
        }

        // Wait for a child to exit.
        sleep(@intFromPtr(parent), &wait_mutex);
    }
}

/// Kill the process with the given pid.
/// The victim won't exit until it tries to return
/// to user space (see userTrap() in trap.zig).
pub fn kill(pid: Pid) !void {
    for (&procs) |*proc| {
        proc.mutex.lock();
        defer proc.mutex.unlock();

        if (proc.public.pid == pid) {
            proc.public.killed = true;

            // Wake process from sleep().
            if (proc.public.state == .sleeping) {
                proc.public.state = .runnable;
            }

            return;
        }
    } else {
        return error.ProcessNotFound;
    }
}

/// Print a process listing to console. For debugging.
/// Runs when user types ^P on console.
/// No lock to avoid wedging a stuck machine further.
pub fn dump() void {
    fmt.println("", .{});
    for (&procs) |*proc| {
        if (proc.public.state == .unused)
            continue;

        fmt.println(
            "{d} {any} {s}",
            .{
                proc.public.pid.?,
                proc.public.state,
                std.mem.sliceTo(&proc.private.name, 0),
            },
        );
    }
}
