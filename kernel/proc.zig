//! Processes and CPU state.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const fs = @import("fs.zig");
const memlayout = @import("memlayout.zig");
const params = @import("params.zig");
const riscv = @import("riscv.zig");
const SpinLock = @import("sync/SpinLock.zig");
const trampoline = @import("trampoline.zig");
const vm = @import("vm.zig");

var cpus: [params.MAX_CPUS]Cpu = undefined;
var initProc: *Process = undefined;
var procs: [params.MAX_PROCS]Process = init: {
    var init_procs: [params.MAX_PROCS]Process = undefined;

    for (0.., &init_procs) |proc_num, *proc| {
        proc.* = .{
            .mutex = .{},
            .parent = null,
            .public = .{
                .state = .unused,
                .pid = null,
            },
            .private = .{
                .kstack = vm.kStackVAddr(proc_num),
                .size = 0,
                .trapFrame = null,
                .pageTable = null,
                .context = null,
                .cwd = null,
            },
        };
    }

    break :init init_procs;
};

/// Process ID.
pub const Pid = u32;
var next_pid: std.atomic.Value(Pid) = .init(1);
var first_proc: std.atomic.Value(bool) = .init(true);

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
        /// Process ID.
        pid: ?Pid,
    },
    /// These are private to the process, so p.mutex need not be held.
    private: struct {
        /// Virtual address of kernel stack.
        kstack: u64,
        /// Size of process memory (bytes)
        size: u64,
        /// Data page for trampoline.zig
        trapFrame: ?*TrapFrame,
        /// User page table.
        pageTable: ?vm.PageTable(.user),
        /// ctxSwitch() here to run process
        context: ?Context,
        /// Current directory
        cwd: ?*fs.Inode,
    },

    /// Give up the CPU for one scheduling round.
    pub fn yield(self: *Process) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.public.state = .runnable;
        switchToScheduler();
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
            .state = .used,
        };
        // Allocate a trapframe page.
        proc.private.trapFrame = try allocator.create(TrapFrame);
        // An empty user page table.
        proc.private.pageTable = try createPageTable(allocator, proc);

        // Set up new context to start executing at forkret,
        // which returns to user space.
        proc.private.context = std.mem.zeroInit(Context, .{
            .ra = @intFromPtr(&forkRet),
            .sp = proc.private.kstack + riscv.PAGE_SIZE,
        });

        return proc;
    }

    /// Free a proc structure and the data hanging from it, including user pages.
    /// p.mutex must be held.
    fn free(self: *Process, allocator: Allocator) void {
        if (self.private.trapFrame) |trapFrame| {
            allocator.destroy(trapFrame);
        }
        if (self.private.pageTable) |pageTable| {
            Process.freePageTable(allocator, pageTable, self.private.size);
        }

        // TODO: others
        self.parent = null;
        self.public.state = .unused;
        self.public.pid = null;
        self.private.size = 0;
        self.private.trapFrame = null;
        self.private.pageTable = null;
        self.private.context = null;
    }

    /// Free a process's page table, and free the physical memory it refers to.
    fn freePageTable(allocator: Allocator, pageTable: vm.PageTable(.user), size: u64) void {
        pageTable.unmap(null, memlayout.TRAMPOLINE, 1);
        pageTable.unmap(null, memlayout.TRAP_FRAME, 1);
        pageTable.free(allocator, size);
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
    zombie,
};

/// Per-process data for the trap handling code in trampoline.zig.
/// Sits in a page by itself just under the trampoline page in the
/// user page table. Not specially mapped in the kernel page table.
/// userVec in trampoline.zig saves user registers in the trapframe,
/// then initializes registers from the trapframe's
/// kernel_sp, kernel_hartid, kernel_satp, and jumps to kernelTrap.
/// userTrapRet() and userRet in trampoline.zig set up
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
    initProc = try .alloc(allocator);
    defer initProc.mutex.unlock();

    initProc.private.cwd = fs.lookupPath("/") catch unreachable;
    initProc.public.state = .runnable;
}

/// Create a user page table for a given process, with no user memory,
/// but with trampoline and trapframe pages.
fn createPageTable(allocator: Allocator, proc: *Process) !vm.PageTable(.user) {
    // An empty user page table.
    var pageTable = try vm.PageTable(.user).init(allocator);
    errdefer pageTable.free(allocator, 0);

    // Map the trampoline code (for system call return) at the highest user virtual address.
    // Only the supervisor uses it, on the way to/from user space, so not PTE_U.
    try pageTable.mapPages(
        allocator,
        memlayout.TRAMPOLINE,
        @intFromPtr(&trampoline.userVec),
        riscv.PAGE_SIZE,
        .{ .readable = true, .executable = true },
    );
    errdefer pageTable.unmap(null, memlayout.TRAMPOLINE, 1);

    // map the trapframe page just below the trampoline page, for trampoline.zig.
    try pageTable.mapPages(
        allocator,
        memlayout.TRAP_FRAME,
        @intFromPtr(proc.private.trapFrame.?),
        riscv.PAGE_SIZE,
        .{ .readable = true, .writable = true },
    );

    return pageTable;
}

/// A fork child's very first scheduling by runScheduler() will switch to forkRet.
fn forkRet() void {
    const proc = myProc().?;

    // Still holding p.mutex from scheduler.
    proc.mutex.unlock();

    if (first_proc.load(.acquire)) {
        // File system initialization must be run in the context of a
        // regular process (e.g., because it calls sleep), and thus cannot
        // be run from kmain().
        fs.init(params.ROOT_DEV);
        first_proc.store(false, .release);

        // TODO: exec
    }

    // TODO: forkret
    @panic("unimplemented");
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

/// Either a user or kernel address.
pub const EitherAddr = union(enum) {
    user: struct { addr: u64, len: u64 },
    kernel: []u8,
};

/// Copy to either a user address, or kernel address, depending on dst.
pub fn eitherCopyOut(dst: EitherAddr, src: []const u8) !void {
    switch (dst) {
        .user => |dest| {
            const proc = myProc().?;
            assert(dest.len == src.len);
            return proc.private.pageTable.?.copyOut(dest.addr, src);
        },
        .kernel => |dest| @memcpy(dest, src),
    }
}

/// Copy from either a user address, or kernel address, depending on src.
pub fn eitherCopyIn(dst: []u8, src: EitherAddr) !void {
    switch (src) {
        .user => |source| {
            const proc = myProc().?;
            assert(source.len == dst.len);
            return proc.private.pageTable.?.copyIn(dst, source.addr);
        },
        .kernel => |source| @memcpy(dst, source),
    }
}
