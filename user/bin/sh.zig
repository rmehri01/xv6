//! Shell.

const std = @import("std");

const file = @import("shared").file;
const ulib = @import("ulib");
const io = ulib.io;
const syscall = ulib.syscall;

const stderr = &io.stderr;

pub fn main() !void {
    var buf: [100]u8 = undefined;

    // Read and run input commands.
    while (getCmd(&buf)) |cmd| {
        var parts = std.mem.tokenizeAny(u8, cmd, " \t\n");
        const first = parts.next() orelse continue;

        // chdir must be called by the parent, not the child.
        if (std.mem.eql(u8, "cd", first)) {
            const dir = parts.next() orelse "/";
            if (parts.next() != null) {
                stderr.println("cd: too many arguments", .{});
                continue;
            }

            syscall.chdir(dir) catch {
                stderr.println("cannot cd {s}", .{dir});
            };
            continue;
        }

        switch (try syscall.fork()) {
            .child => {
                // TODO: more elaborate running of commands
                var args = try std.ArrayList([]const u8).initCapacity(
                    ulib.mem.allocator,
                    8,
                );
                try args.append(ulib.mem.allocator, first);
                while (parts.next()) |part| {
                    try args.append(ulib.mem.allocator, part);
                }
                _ = try syscall.exec(first, try args.toOwnedSlice(ulib.mem.allocator));
            },
            .parent => _ = try syscall.wait(null),
        }
    }
}

fn getCmd(buf: []u8) ?[]const u8 {
    stderr.print("$ ", .{});
    const str = io.getStr(buf);

    if (str.len == 0)
        return null
    else
        return str;
}
