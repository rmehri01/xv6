//! Processes.

const std = @import("std");
const atomic = std.atomic;

const params = @import("params.zig");
const SpinLock = @import("sync/SpinLock.zig");
const vm = @import("vm.zig");

var procs: [params.MAX_PROCS]Process = undefined;
var next_pid: atomic.Value(u32) = .init(1);

/// Per-process state.
const Process = struct {
    /// Mutex that protects the public state of the process.
    mutex: SpinLock,
    /// Parent process. The wait_mutex must be held when using this.
    parent: ?*Process,
    /// Process mutex must be held while using these.
    public: struct {
        state: ProcessState,
    },
    private: struct {
        /// Virtual address of kernel stack.
        kstack: u64,
    },
};

/// The possible states a process can be in.
const ProcessState = enum { unused, used, sleeping, runnable, running, zombie };

pub fn init() void {
    for (0.., &procs) |proc_num, *proc| {
        proc.* = .{
            .mutex = .{},
            .parent = null,
            .public = .{ .state = .unused },
            .private = .{
                .kstack = vm.kStackVAddr(proc_num),
            },
        };
    }
}
