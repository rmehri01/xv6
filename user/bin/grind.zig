//! Run random system calls in parallel forever.

const std = @import("std");
const assert = std.debug.assert;

const OpenMode = @import("shared").file.OpenMode;
const ulib = @import("ulib");
const syscall = ulib.syscall;

const stdout = &ulib.io.stdout;
const stderr = &ulib.io.stderr;

var rand_next: u64 = 1;

pub fn main() !void {
    while (true) {
        switch (try syscall.fork()) {
            .child => try iter(),
            .parent => {
                _ = try syscall.wait(null);
                try syscall.pause(20);
                rand_next += 1;
            },
        }
    }
}

fn iter() !noreturn {
    syscall.unlink("a") catch {};
    syscall.unlink("b") catch {};

    if (try syscall.fork() == .child) {
        rand_next ^= 31;
        try go(0);
        syscall.exit(0);
    }

    if (try syscall.fork() == .child) {
        rand_next ^= 7177;
        try go(1);
        syscall.exit(0);
    }

    _ = try syscall.wait(null);
    _ = try syscall.wait(null);

    syscall.exit(0);
}

const errFd = std.math.maxInt(u32);

fn go(which_child: u1) !void {
    var iters: u64 = 0;
    var fd: u32 = errFd;
    var buf: [999]u8 = .{0xaa} ** 999;
    const break0 = try syscall.sbrk(0, .eager);

    syscall.mkdir("grindir") catch {};
    try syscall.chdir("grindir");
    try syscall.chdir("/");

    while (true) {
        iters += 1;

        if (iters % 500 == 0) {
            stdout.print("{s}", .{switch (which_child) {
                0 => "A",
                1 => "B",
            }});
        }

        const what = rand() % 23;
        switch (what) {
            1 => syscall.close(syscall.open(
                "grindir/../a",
                OpenMode.CREATE | OpenMode.READ_WRITE,
            ) catch errFd) catch {},
            2 => syscall.close(syscall.open(
                "grindir/../grindir/../b",
                OpenMode.CREATE | OpenMode.READ_WRITE,
            ) catch errFd) catch {},
            3 => syscall.unlink("grindir/../a") catch {},
            4 => {
                try syscall.chdir("grindir");
                syscall.unlink("../b") catch {};
                try syscall.chdir("/");
            },
            5 => {
                syscall.close(fd) catch {};
                fd = syscall.open(
                    "/grindir/../a",
                    OpenMode.CREATE | OpenMode.READ_WRITE,
                ) catch errFd;
            },
            6 => {
                syscall.close(fd) catch {};
                fd = syscall.open(
                    "/./grindir/./../b",
                    OpenMode.CREATE | OpenMode.READ_WRITE,
                ) catch errFd;
            },
            7 => _ = syscall.write(fd, &buf) catch {},
            8 => _ = syscall.read(fd, &buf) catch {},
            9 => {
                syscall.mkdir("grindir/../a") catch {};
                syscall.close(syscall.open(
                    "a/../a/./a",
                    OpenMode.CREATE | OpenMode.READ_WRITE,
                ) catch errFd) catch {};
                syscall.unlink("a/a") catch {};
            },
            10 => {
                syscall.mkdir("/../b") catch {};
                syscall.close(syscall.open(
                    "grindir/../b/b",
                    OpenMode.CREATE | OpenMode.READ_WRITE,
                ) catch errFd) catch {};
                syscall.unlink("b/b") catch {};
            },
            11 => {
                syscall.unlink("b") catch {};
                syscall.link("../grindir/./../a", "../b") catch {};
            },
            12 => {
                syscall.unlink("../grindir/../a") catch {};
                syscall.link(".././b", "/grindir/../a") catch {};
            },
            13 => switch (try syscall.fork()) {
                .child => syscall.exit(0),
                .parent => _ = try syscall.wait(null),
            },
            14 => switch (try syscall.fork()) {
                .child => {
                    _ = try syscall.fork();
                    _ = try syscall.fork();
                    syscall.exit(0);
                },
                .parent => _ = try syscall.wait(null),
            },
            15 => _ = try syscall.sbrk(6011, .eager),
            16 => {
                const brk = try syscall.sbrk(0, .eager);
                if (brk > break0) {
                    _ = try syscall.sbrk(
                        -@as(i32, @intCast(brk - break0)),
                        .eager,
                    );
                }
            },
            17 => switch (try syscall.fork()) {
                .child => {
                    syscall.close(syscall.open(
                        "a",
                        OpenMode.CREATE | OpenMode.READ_WRITE,
                    ) catch errFd) catch {};
                    syscall.exit(0);
                },
                .parent => |pid| {
                    try syscall.chdir("../grindir/..");
                    try syscall.kill(pid);
                    _ = try syscall.wait(null);
                },
            },
            18 => switch (try syscall.fork()) {
                .child => {
                    try syscall.kill(syscall.getpid());
                    unreachable;
                },
                .parent => _ = try syscall.wait(null),
            },
            19 => {
                const pipe = try syscall.pipe();
                switch (try syscall.fork()) {
                    .child => {
                        _ = try syscall.fork();
                        _ = try syscall.fork();

                        const written = try syscall.write(pipe.tx, "x");
                        assert(written == 1);

                        var char: u8 = undefined;
                        const read = try syscall.read(pipe.rx, std.mem.asBytes(&char));
                        assert(read == 1);

                        syscall.exit(0);
                    },
                    .parent => {
                        try syscall.close(pipe.rx);
                        try syscall.close(pipe.tx);
                        _ = try syscall.wait(null);
                    },
                }
            },
            20 => switch (try syscall.fork()) {
                .child => {
                    syscall.unlink("a") catch {};
                    syscall.mkdir("a") catch {};
                    syscall.chdir("a") catch {};
                    syscall.unlink("../a") catch {};

                    fd = syscall.open(
                        "x",
                        OpenMode.CREATE | OpenMode.READ_WRITE,
                    ) catch errFd;
                    syscall.unlink("x") catch {};
                    syscall.exit(0);
                },
                .parent => _ = try syscall.wait(null),
            },
            21 => {
                syscall.unlink("c") catch {};

                // should always succeed. check that there are free i-nodes,
                // file descriptors, blocks.
                const fd1 = try syscall.open(
                    "c",
                    OpenMode.CREATE | OpenMode.READ_WRITE,
                );
                const written = try syscall.write(fd1, "x");
                assert(written == 1);

                const meta = try syscall.fstat(fd1);
                if (meta.size != 1) {
                    stderr.println(
                        "grind: fstat reports wrong size {d}",
                        .{meta.size},
                    );
                }
                if (meta.inum > 200) {
                    stderr.println(
                        "grind: fstat reports crazy i-number {d}",
                        .{meta.inum},
                    );
                }
                try syscall.close(fd1);
                syscall.unlink("c") catch {};
            },
            22 => {
                // echo hi | cat
                const a = try syscall.pipe();
                const b = try syscall.pipe();

                if (try syscall.fork() == .child) {
                    try syscall.close(b.rx);
                    try syscall.close(b.tx);
                    try syscall.close(a.rx);

                    try syscall.close(1);
                    try syscall.dup(a.tx);
                    try syscall.close(a.tx);

                    try syscall.exec("grindir/../echo", &.{ "echo", "hi" });
                    syscall.exit(2);
                }
                if (try syscall.fork() == .child) {
                    try syscall.close(a.tx);
                    try syscall.close(b.rx);

                    try syscall.close(0);
                    try syscall.dup(a.rx);
                    try syscall.close(a.rx);

                    try syscall.close(1);
                    try syscall.dup(b.tx);
                    try syscall.close(b.tx);

                    try syscall.exec("/cat", &.{"cat"});
                    syscall.exit(6);
                }

                try syscall.close(a.rx);
                try syscall.close(a.tx);
                try syscall.close(b.tx);

                var out: [3]u8 = .{0} ** 3;
                _ = try syscall.read(b.rx, out[0..1]);
                _ = try syscall.read(b.rx, out[1..2]);
                _ = try syscall.read(b.rx, out[2..3]);
                try syscall.close(b.rx);

                var st1: i32 = undefined;
                var st2: i32 = undefined;

                _ = try syscall.wait(&st1);
                _ = try syscall.wait(&st2);

                if (st1 != 0 or st2 != 0 or !std.mem.eql(u8, &out, "hi\n")) {
                    stderr.println(
                        "grind: exec pipeline failed {d} {d} \"{s}\" ",
                        .{ st1, st2, out },
                    );
                }
            },
            else => {},
        }
    }
}

fn rand() u32 {
    return do_rand(&rand_next);
}

/// From FreeBSD:
///
/// Compute x = (7^5 * x) mod (2^31 - 1)
/// without overflowing 31 bits:
///      (2^31 - 1) = 127773 * (7^5) + 2836
/// From "Random number generators: good ones are hard to find",
/// Park and Miller, Communications of the ACM, vol. 31, no. 10,
/// October 1988, p. 1195.
fn do_rand(ctx: *u64) u32 {
    // Transform to [1, 0x7ffffffe] range.
    var x: i64 = @intCast((ctx.* % 0x7ffffffe) + 1);
    const hi = @divFloor(x, 127773);
    const lo = @rem(x, 127773);

    x = 16807 * lo - 2836 * hi;
    if (x < 0)
        x += 0x7fffffff;

    // Transform to [0, 0x7ffffffd] range.
    x -= 1;
    ctx.* = @intCast(x);
    return @intCast(x);
}
