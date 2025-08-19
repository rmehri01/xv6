//! Mutual exclusion lock based on spinning.

const std = @import("std");
const assert = std.debug.assert;

const SpinLock = @This();

/// Whether the spin lock is being held.
locked: std.atomic.Value(bool) = .init(false),

/// Acquire the lock. Loops (spins) until the lock is acquired.
pub fn lock(self: *SpinLock) void {
    while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

/// Release the lock.
pub fn unlock(self: *SpinLock) void {
    assert(self.locked.load(.acquire));
    self.locked.store(false, .release);
}
