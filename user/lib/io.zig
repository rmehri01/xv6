//! Input/Output.

const syscall = @import("syscall.zig");

pub fn getStr(buf: []u8) []const u8 {
    @memset(buf, 0);

    var read: usize = 0;
    while (read < buf.len) {
        const num_read = syscall.read(0, buf[read..][0..1]) catch
            break;
        if (num_read == 0)
            break;

        defer read += num_read;
        if (buf[read] == '\n' or buf[read] == '\r')
            break;
    }
    return buf[0..read];
}
