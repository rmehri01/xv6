const std = @import("std");
const Allocator = std.mem.Allocator;

const proc = @import("../proc.zig");
const SpinLock = @import("../sync/SpinLock.zig");
const file = @import("file.zig");

const Pipe = @This();

mutex: SpinLock,
data: [512]u8,
/// Number of bytes read.
num_read: u9,
/// Number of bytes written.
num_written: u9,
/// Read fd is still open.
read_open: bool,
/// Write fd is still open.
write_open: bool,

pub fn init() Pipe {
    return std.mem.zeroInit(Pipe, .{
        .read_open = true,
        .write_open = true,
    });
}

pub fn read(self: *Pipe, allocator: Allocator, addr: u64, len: u32) !u64 {
    const p = proc.myProc().?;

    self.mutex.lock();
    defer self.mutex.unlock();

    while (self.num_read == self.num_written and self.write_open) {
        if (p.isKilled()) {
            return error.Killed;
        }
        proc.sleep(@intFromPtr(&self.num_read), &self.mutex);
    }

    var i: u64 = 0;
    while (i < len) : (i += 1) {
        if (self.num_read == self.num_written)
            break;

        const char = self.data[self.num_read];
        self.num_read +%= 1;
        try p.private.page_table.copyOut(
            allocator,
            addr + i,
            std.mem.asBytes(&char),
        );
    }
    proc.wakeUp(@intFromPtr(&self.num_written));

    return i;
}

pub fn write(self: *Pipe, allocator: Allocator, addr: u64, len: u32) !u64 {
    const p = proc.myProc().?;

    self.mutex.lock();
    defer self.mutex.unlock();

    var i: u64 = 0;
    while (i < len) {
        if (!self.read_open or p.isKilled()) {
            return error.Killed;
        }

        if (self.num_written +% 1 == self.num_read) {
            proc.wakeUp(@intFromPtr(&self.num_read));
            proc.sleep(@intFromPtr(&self.num_written), &self.mutex);
        } else {
            var char: u8 = undefined;
            try p.private.page_table.copyIn(
                allocator,
                std.mem.asBytes(&char),
                addr + i,
            );
            self.data[self.num_written] = char;
            self.num_written +%= 1;
            i += 1;
        }
    }
    proc.wakeUp(@intFromPtr(&self.num_read));

    return i;
}

pub fn close(self: *Pipe, allocator: Allocator, writable: bool) void {
    self.mutex.lock();

    if (writable) {
        self.write_open = false;
        proc.wakeUp(@intFromPtr(&self.num_read));
    } else {
        self.read_open = false;
        proc.wakeUp(@intFromPtr(&self.num_written));
    }

    if (!self.read_open and !self.write_open) {
        self.mutex.unlock();
        allocator.destroy(self);
    } else {
        self.mutex.unlock();
    }
}
