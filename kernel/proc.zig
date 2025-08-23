//! Processes and CPU state.

const std = @import("std");

const params = @import("params.zig");
const SpinLock = @import("sync/SpinLock.zig");
const vm = @import("vm.zig");
const riscv = @import("riscv.zig");

var cpus: [params.MAX_CPUS]Cpu = undefined;
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
            },
        };
    }

    break :init init_procs;
};

/// Process ID.
pub const Pid = u32;
var next_pid: std.atomic.Value(Pid) = .init(1);

/// Per-CPU state.
pub const Cpu = struct {
    /// The process running on this cpu, or null.
    proc: ?*Process,
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
    private: struct {
        /// Virtual address of kernel stack.
        kstack: u64,
    },

    /// Give up the CPU for one scheduling round.
    pub fn yield(self: *Process) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.public.state = .runnable;
        sched();
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

// TODO: sched
pub fn sched() void {}

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

    // Must acquire p.mutex in order to
    // change p.public.state and then call sched.
    // Once we hold p.mutex, we can be
    // guaranteed that we won't miss any wakeup
    // (wakeup locks p.mutex),
    // so it's okay to release mutex.
    p.mutex.lock();
    mutex.unlock();

    // Go to sleep.
    p.public.state = .{ .sleeping = .{ .chan = chan } };
    sched();

    // TODO: defer?
    // Reacquire original lock.
    p.mutex.unlock();
    mutex.lock();
}

/// Wake up all processes sleeping on channel chan.
/// Caller should hold the condition lock.
pub fn wakeUp(chan: usize) void {
    const currentProc = myProc().?;
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
