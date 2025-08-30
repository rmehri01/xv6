//! Mutual exclusion lock based on spinning.

const std = @import("std");
const assert = std.debug.assert;

const proc = @import("../proc.zig");
const riscv = @import("../riscv.zig");

const SpinLock = @This();

/// Whether the spin lock is being held.
locked: std.atomic.Value(bool) = .init(false),
/// The cpu holding the lock.
cpu: ?*proc.Cpu = null,

/// Acquire the lock. Loops (spins) until the lock is acquired.
pub fn lock(self: *SpinLock) void {
    riscv.pushIntrOff();
    assert(!self.holding());

    while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
    self.cpu = proc.myCpu();
}

/// Release the lock.
pub fn unlock(self: *SpinLock) void {
    assert(self.holding());
    self.cpu = null;

    self.locked.store(false, .release);
    riscv.popIntrOff();
}

/// Check whether this cpu is holding the lock.
/// Interrupts must be off.
pub fn holding(self: *SpinLock) bool {
    return self.locked.load(.acquire) and self.cpu == proc.myCpu();
}
