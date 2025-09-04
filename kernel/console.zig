//! Console input and output, to the uart.
//! Reads are line at a time.
//! Implements special input characters:
//!   newline -- end of line
//!   control-h -- backspace
//!   control-u -- kill line
//!   control-d -- end of file
//!   control-p -- print process list

const std = @import("std");

const heap = @import("heap.zig");
const proc = @import("proc.zig");
const uart = @import("uart.zig");
const SpinLock = @import("sync/SpinLock.zig");

var console: struct {
    mutex: SpinLock,
    /// input
    buf: [128]u8,
    /// read index
    read: u7,
    /// write index
    written: u7,
    /// edit index
    edit: u7,
} = .{
    .mutex = .{},
    .buf = undefined,
    .read = 0,
    .written = 0,
    .edit = 0,
};

/// User read()s from the console go here.
/// Copy (up to) a whole input line to dst.
/// dest indicates whether dst is a user or kernel address.
pub fn read(dest: proc.EitherMem) !u64 {
    console.mutex.lock();
    defer console.mutex.unlock();

    const target = switch (dest) {
        .user => |dst| dst.len,
        .kernel => |dst| dst.len,
    };
    var n = target;
    while (n > 0) {
        // wait until interrupt handler has put some input into console.buf.
        while (console.read == console.written) {
            if (proc.myProc().?.isKilled()) {
                return error.ReadFailed;
            }
            proc.sleep(@intFromPtr(&console.read), &console.mutex);
        }

        const char = console.buf[console.read];
        console.read +%= 1;

        if (char == ctrl('D')) {
            // end-of-file
            if (n < target) {
                // Save ^D for next time, to make sure caller gets a 0-byte result.
                console.read -%= 1;
            }
            break;
        }

        // copy the input byte to the user-space buffer.
        const num_read = target - n;
        const dst: proc.EitherMem = switch (dest) {
            .user => |src| .{
                .user = .{ .addr = src.addr + num_read, .len = 1 },
            },
            .kernel => |src| .{ .kernel = src[num_read..][0..1] },
        };
        proc.eitherCopyOut(
            heap.page_allocator,
            dst,
            std.mem.asBytes(&char),
        ) catch return error.ReadFailed;

        n -= 1;

        if (char == '\n') {
            // a whole line has arrived, return to the user-level read().
            break;
        }
    }

    return target - n;
}

/// User write()s to the console go here.
pub fn write(source: proc.EitherMem) !u64 {
    const len = switch (source) {
        .user => |dst| dst.len,
        .kernel => |dst| dst.len,
    };
    var buf: [32]u8 = undefined;
    var written: u64 = 0;

    while (written < len) {
        var bytes_to_write = buf.len;
        if (bytes_to_write > len - written)
            bytes_to_write = len - written;

        const src: proc.EitherMem = switch (source) {
            .user => |src| .{
                .user = .{ .addr = src.addr + written, .len = bytes_to_write },
            },
            .kernel => |src| .{ .kernel = src[written..][0..bytes_to_write] },
        };
        proc.eitherCopyIn(
            heap.page_allocator,
            buf[0..bytes_to_write],
            src,
        ) catch break;
        uart.write(buf[0..bytes_to_write]);

        written += bytes_to_write;
    }

    return written;
}

/// The console input interrupt handler.
/// uart.handleIntr() calls this for input characters.
/// Do erase/kill processing, append to cons.buf,
/// wake up read() if a whole line has arrived.
pub fn handleIntr(char: u8) void {
    console.mutex.lock();
    defer console.mutex.unlock();

    switch (char) {
        // Print process list.
        ctrl('P') => proc.dump(),
        // Kill line.
        ctrl('U') => while (console.edit != console.written and
            console.buf[(console.edit -% 1)] != '\n')
        {
            console.edit -= 1;
            putChar(.backspace);
        },
        // Backspace or delete key
        ctrl('H'), '\x7f' => {
            if (console.edit != console.written) {
                console.edit -%= 1;
                putChar(.backspace);
            }
        },
        else => {
            if (char != 0 and console.edit - console.read < console.buf.len) {
                const c = if (char == '\r') '\n' else char;

                // echo back to the user.
                putChar(.{ .char = c });

                // store for consumption by read().
                console.buf[console.edit] = c;
                console.edit +%= 1;

                if (c == '\n' or
                    c == ctrl('D') or
                    console.edit - console.read == console.buf.len)
                {
                    // wake up read() if a whole line (or end-of-file) has arrived.
                    console.written = console.edit;
                    proc.wakeUp(@intFromPtr(&console.read));
                }
            }
        },
    }
}

// Send one character to the uart.
// Called to echo input characters, but not from write().
fn putChar(char: union(enum) { char: u8, backspace }) void {
    switch (char) {
        .backspace => {
            // if the user typed backspace, overwrite with a space.
            uart.putCharSync('\x08');
            uart.putCharSync(' ');
            uart.putCharSync('\x08');
        },
        .char => |c| {
            uart.putCharSync(c);
        },
    }
}

fn ctrl(char: u8) u8 {
    return char - '@';
}
