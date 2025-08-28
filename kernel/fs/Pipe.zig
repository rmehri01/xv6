const Pipe = @This();

pub fn close(self: *Pipe) void {
    _ = self; // autofix
    @panic("todo pipe close");
}
