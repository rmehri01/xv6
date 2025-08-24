//! Mutual exclusion lock based on sleeping.

const params = @import("../params.zig");
const proc = @import("../proc.zig");
const SpinLock = @import("SpinLock.zig");

const SleepLock = @This();

/// Whether the sleep lock is being held.
locked: bool = false,
// SpinLock protecting this sleep lock.
mutex: SpinLock,
/// Process holding the lock.
pid: ?proc.Pid = null,

/// Acquire the lock. Sleeps until the lock is acquired.
pub fn lock(self: *SleepLock) void {
    self.mutex.lock();
    while (self.locked) {
        proc.sleep(@intFromPtr(self), &self.mutex);
    }

    self.locked = true;
    self.pid = proc.myProc().?.public.pid.?;

    // TODO: defer?
    self.mutex.unlock();
}

/// Release the lock. Wakes up anyone else waiting for it.
pub fn unlock(self: *SleepLock) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    self.locked = false;
    self.pid = null;

    proc.wakeUp(@intFromPtr(self));
}

/// Check whether this process is holding the lock.
pub fn holding(self: *SleepLock) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.locked and self.pid.? == proc.myProc().?.public.pid.?;
}
