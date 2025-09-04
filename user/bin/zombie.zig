//! Create a zombie process that must be reparented at exit.

const ulib = @import("ulib");
const syscall = ulib.syscall;

pub fn main() !void {
    switch (try syscall.fork()) {
        .child => {},
        .parent => {
            // Let child exit before parent.
            try syscall.pause(5);
        },
    }
}
