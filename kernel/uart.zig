//! Low-level driver routines for 16550a UART.

const std = @import("std");

const console = @import("console.zig");
const memlayout = @import("memlayout.zig");
const proc = @import("proc.zig");
const riscv = @import("riscv.zig");
const SpinLock = @import("sync/SpinLock.zig");

/// Enable receive holding register interrupt
const IER_RX_ENABLE = 1 << 0;
/// Enable transmit holding register interrupt
const IER_TX_ENABLE = 1 << 1;

/// Enable the transmit and receive FIFO
const FCR_FIFO_ENABLE = 1 << 0;
/// Clear the content of the two FIFOs
const FCR_FIFO_CLEAR = 3 << 1;

/// Special mode to set baud rate
const LCR_BAUD_LATCH = 1 << 7;
/// Specify the word length to be transmitted or received
const LCR_EIGHT_BITS = 3 << 0;

/// Input is waiting to be read from RHR
const LSR_RX_READY = 1 << 0;
/// THR can accept another character to send
const LSR_TX_IDLE = 1 << 5;

// for transmission.
var tx: struct {
    mutex: SpinLock,
    /// Is the UART busy sending?
    busy: bool,
    /// &chan is the "wait channel"
    chan: void,
} = .{
    .mutex = .{},
    .busy = false,
    .chan = {},
};

pub fn init() void {
    // disable interrupts.
    writeReg(.ier, 0x00);

    // special mode to set baud rate.
    writeReg(.lcr, LCR_BAUD_LATCH);

    // LSB for baud rate of 38.4K.
    writeReg(.div_lsb, 0x03);

    // MSB for baud rate of 38.4K.
    writeReg(.div_msb, 0x00);

    // leave set-baud mode,
    // and set word length to 8 bits, no parity.
    writeReg(.lcr, LCR_EIGHT_BITS);

    // reset and enable FIFOs.
    writeReg(.fcr, FCR_FIFO_ENABLE | FCR_FIFO_CLEAR);

    // enable transmit and receive interrupts.
    writeReg(.ier, IER_TX_ENABLE | IER_RX_ENABLE);
}

/// Transmit buf to the uart. It blocks if the
/// uart is busy, so it cannot be called from
/// interrupts, only from write() system calls.
pub fn write(buf: []const u8) void {
    tx.mutex.lock();
    defer tx.mutex.unlock();

    for (buf) |char| {
        while (tx.busy) {
            proc.sleep(@intFromPtr(&tx.chan), &tx.mutex);
        }

        writeReg(.thr, char);
        tx.busy = true;
    }
}

/// Handle a UART interrupt, raised because input has
/// arrived, or the uart is ready for more output, or
/// both. Called from handleDevIntr().
pub fn handleIntr() void {
    // acknowledge the interrupt
    _ = readReg(.isr);

    {
        tx.mutex.lock();
        defer tx.mutex.unlock();

        if (readReg(.lsr) & LSR_TX_IDLE != 0) {
            // UART finished transmitting; wake up sending thread.
            tx.busy = false;
            proc.wakeUp(@intFromPtr(&tx.chan));
        }
    }

    // read and process incoming characters.
    while (getChar()) |char| {
        console.handleIntr(char);
    }
}

/// Try to read one input character from the UART, returning null if none is waiting.
pub fn getChar() ?u8 {
    if (readReg(.lsr) & LSR_RX_READY == 1) {
        // input data is ready.
        return readReg(.rhr);
    } else {
        return null;
    }
}

/// Alternate version of put_char() that doesn't use interrupts, for
/// use by fmt.print() and to echo characters.
/// It spins waiting for the uart's output register to be empty.
pub fn putCharSync(char: u8) void {
    riscv.pushIntrOff();
    defer riscv.popIntrOff();

    while ((readReg(.lsr) & LSR_TX_IDLE) == 0) {}
    writeReg(.thr, char);
}

/// Registers that are readable.
const ReadReg = enum {
    /// Receive Holding Register
    rhr,
    /// Interrupt Status Register
    isr,
    /// Line Status Register
    lsr,
};

/// Read from the given register.
fn readReg(comptime reg: ReadReg) u8 {
    const offset = switch (reg) {
        .rhr => 0,
        .isr => 2,
        .lsr => 5,
    };
    const ptr: *volatile u8 = @ptrFromInt(memlayout.UART0 + offset);
    return ptr.*;
}

/// Registers that are writable.
const WriteReg = enum {
    /// Transmit Holding Register
    thr,
    /// LSB of Divisor Latch when Enabled
    div_lsb,
    /// Interrupt Enable Register
    ier,
    /// MSB of Divisor Latch when Enabled
    div_msb,
    /// FIFO control Register
    fcr,
    /// Line Control Register
    lcr,
};

/// Write val to the given register.
fn writeReg(comptime reg: WriteReg, val: u8) void {
    const offset = switch (reg) {
        .thr, .div_lsb => 0,
        .ier, .div_msb => 1,
        .fcr => 2,
        .lcr => 3,
    };
    const ptr: *volatile u8 = @ptrFromInt(memlayout.UART0 + offset);
    ptr.* = val;
}

/// Implementation of std.Io.Writer that uses the uart synchronously.
/// Must be locked before writing.
pub var sync_writer: SyncUartWriter = .{};

var buffer: [1024]u8 = undefined;
const SyncUartWriter = struct {
    /// Ensures that concurrent prints aren't interleaved.
    mutex: SpinLock = .{},
    interface: std.Io.Writer = .{
        .buffer = &buffer,
        .vtable = &.{
            .drain = drain,
        },
    },

    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
        var written: usize = 0;

        written += uartPutStrSync(io_w.buffered());
        io_w.end = 0;

        for (data[0 .. data.len - 1]) |chunk| {
            written += uartPutStrSync(chunk);
        }
        for (0..splat) |_| {
            written += uartPutStrSync(data[data.len - 1]);
        }

        return written;
    }
};

/// Prints a string one character at a time to the UART.
fn uartPutStrSync(str: []const u8) usize {
    for (str) |ch| {
        putCharSync(ch);
    }
    return str.len;
}
