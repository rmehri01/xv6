//! Low-level driver routines for 16550a UART.

const memlayout = @import("memlayout.zig");

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

pub fn init() void {
    // disable interrupts.
    write_reg(.ier, 0x00);

    // special mode to set baud rate.
    write_reg(.lcr, LCR_BAUD_LATCH);

    // LSB for baud rate of 38.4K.
    write_reg(.div_lsb, 0x03);

    // MSB for baud rate of 38.4K.
    write_reg(.div_msb, 0x00);

    // leave set-baud mode,
    // and set word length to 8 bits, no parity.
    write_reg(.lcr, LCR_EIGHT_BITS);

    // reset and enable FIFOs.
    write_reg(.fcr, FCR_FIFO_ENABLE | FCR_FIFO_CLEAR);

    // enable transmit and receive interrupts.
    write_reg(.ier, IER_TX_ENABLE | IER_RX_ENABLE);
}

/// Try to read one input character from the UART, returning null if none is waiting.
pub fn get_char() ?u8 {
    if (read_reg(.lsr) & LSR_RX_READY == 1) {
        return read_reg(.rhr);
    } else {
        return null;
    }
}

/// Alternate version of put_char() that doesn't use interrupts, for
/// use by fmt.print() and to echo characters.
/// It spins waiting for the uart's output register to be empty.
pub fn put_char_sync(ch: u8) void {
    while ((read_reg(.lsr) & LSR_TX_IDLE) == 0) {}
    write_reg(.thr, ch);
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
fn read_reg(comptime reg: ReadReg) u8 {
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
fn write_reg(comptime reg: WriteReg, val: u8) void {
    const offset = switch (reg) {
        .thr, .div_lsb => 0,
        .ier, .div_msb => 1,
        .fcr => 2,
        .lcr => 3,
    };
    const ptr: *volatile u8 = @ptrFromInt(memlayout.UART0 + offset);
    ptr.* = val;
}
