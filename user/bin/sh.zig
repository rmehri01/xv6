//! Shell.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const OpenMode = @import("shared").file.OpenMode;
const params = @import("shared").params;
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
                const c = parseCmd(
                    ulib.mem.allocator,
                    cmd[0 .. cmd.len - 1],
                ) catch |err| {
                    stderr.println("parsing failed: {}", .{err});
                    syscall.exit(1);
                };
                c.run();
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

const Error = error{
    OutOfMemory,
    TooManyArgs,
};

fn parseCmd(allocator: Allocator, cmd: []const u8) !*Cmd {
    var rest = cmd;
    const c = parseLine(allocator, &rest);
    if (rest.len != 0) {
        stderr.println("invalid command, leftover: {s}", .{rest});
        syscall.exit(1);
    }
    return c;
}

fn parseLine(allocator: Allocator, rest: *[]const u8) Error!*Cmd {
    var cmd = try parsePipe(allocator, rest);

    if (peek(rest.*, "&")) {
        const tok = getToken(rest);
        assert(tok.? == .special);

        const background = try allocator.create(Cmd);
        background.* = .{ .background = .{
            .cmd = cmd,
        } };
        cmd = background;
    }
    if (peek(rest.*, ";")) {
        const tok = getToken(rest);
        assert(tok.? == .special);

        const list = try allocator.create(Cmd);
        list.* = .{ .list = .{
            .left = cmd,
            .right = try parseLine(allocator, rest),
        } };
        cmd = list;
    }

    return cmd;
}

fn parsePipe(allocator: Allocator, rest: *[]const u8) !*Cmd {
    const cmd = try parseExec(allocator, rest);

    // TODO: pipe

    return cmd;
}

fn parseExec(allocator: Allocator, rest: *[]const u8) !*Cmd {
    if (peek(rest.*, "(")) {
        return try parseBlock(allocator, rest);
    }

    const cmd = try allocator.create(Cmd);
    cmd.* = .{ .exec = .{
        .args = try .initCapacity(allocator, 8),
    } };
    var ret = cmd;

    ret = try parseRedirs(allocator, ret, rest);
    while (!peek(rest.*, "|)&;")) {
        const tok = getToken(rest) orelse break;
        try cmd.exec.args.append(allocator, tok.tok);
        if (cmd.exec.args.items.len >= params.MAX_ARGS)
            return error.TooManyArgs;
        ret = try parseRedirs(allocator, ret, rest);
    }

    return ret;
}

fn parseBlock(allocator: Allocator, rest: *[]const u8) !*Cmd {
    assert(peek(rest.*, "("));

    const ltok = getToken(rest);
    assert(ltok.? == .special);

    var cmd = try parseLine(allocator, rest);

    if (!peek(rest.*, ")")) {
        stderr.println("missing )", .{});
        syscall.exit(1);
    }
    const rtok = getToken(rest);
    assert(rtok.? == .special);

    cmd = try parseRedirs(allocator, cmd, rest);
    return cmd;
}

fn parseRedirs(allocator: Allocator, cmd: *Cmd, rest: *[]const u8) !*Cmd {
    var c = cmd;
    while (peek(rest.*, "<>")) {
        const tok = getToken(rest) orelse break;
        const filename = getToken(rest);
        if (filename == null or filename.? != .tok) {
            stderr.println("missing file for redirection", .{});
            syscall.exit(1);
        }

        const mode: u32, const fd: u32 = switch (tok.special[0]) {
            '<' => .{ OpenMode.READ_ONLY, 0 },
            '>' => if (tok.special.len == 2)
                .{ OpenMode.WRITE_ONLY | OpenMode.CREATE | OpenMode.APPEND, 1 }
            else
                .{ OpenMode.WRITE_ONLY | OpenMode.CREATE | OpenMode.TRUNCATE, 1 },
            else => unreachable,
        };

        const redir = try allocator.create(Cmd);
        redir.* = .{ .redir = .{
            .cmd = cmd,
            .file = filename.?.tok,
            .mode = mode,
            .fd = fd,
        } };
        c = redir;
    }
    return c;
}

fn peek(str: []const u8, toks: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, str, &std.ascii.whitespace);
    if (trimmed.len == 0)
        return false;
    return std.mem.containsAtLeastScalar(u8, toks, 1, trimmed[0]);
}

fn getToken(rest: *[]const u8) ?union(enum) {
    special: []const u8,
    tok: []const u8,
} {
    rest.* = std.mem.trimStart(u8, rest.*, &std.ascii.whitespace);
    if (rest.*.len == 0)
        return null;

    const rest0 = rest.*;
    switch (rest0[0]) {
        '|', '(', ')', ';', '&', '<' => {
            rest.* = rest.*[1..];
            return .{ .special = rest0[0..1] };
        },
        '>' => {
            rest.* = rest.*[1..];
            if (std.mem.startsWith(u8, rest.*, ">")) {
                rest.* = rest.*[1..];
                return .{ .special = rest0[0..2] };
            } else {
                return .{ .special = rest0[0..1] };
            }
        },
        else => {
            while (rest.len != 0 and
                !std.mem.containsAtLeastScalar(
                    u8,
                    &std.ascii.whitespace,
                    1,
                    rest.*[0],
                ) and
                !std.mem.containsAtLeastScalar(
                    u8,
                    "<|>&;()",
                    1,
                    rest.*[0],
                ))
            {
                rest.* = rest.*[1..];
            }

            return .{ .tok = rest0[0..(rest0.len - rest.len)] };
        },
    }
}

const Cmd = union(enum) {
    exec: struct {
        args: std.ArrayList([]const u8),
    },
    redir: struct {
        cmd: *Cmd,
        file: []const u8,
        mode: u32,
        fd: u32,
    },
    list: struct {
        left: *Cmd,
        right: *Cmd,
    },
    background: struct {
        cmd: *Cmd,
    },

    fn run(self: *Cmd) noreturn {
        switch (self.*) {
            .exec => |e| {
                if (e.args.items.len == 0)
                    syscall.exit(1);
                syscall.exec(e.args.items[0], e.args.items) catch {
                    stderr.println("exec {s} failed", .{e.args.items[0]});
                    syscall.exit(1);
                };
            },
            .redir => |r| {
                syscall.close(r.fd) catch {};
                _ = syscall.open(r.file, r.mode) catch {
                    stderr.println("open {s} failed", .{r.file});
                    syscall.exit(1);
                };
                r.cmd.run();
            },
            .list => |l| {
                const f = syscall.fork() catch {
                    stderr.println("fork failed", .{});
                    syscall.exit(1);
                };
                switch (f) {
                    .child => l.left.run(),
                    .parent => {
                        _ = syscall.wait(null) catch unreachable;
                        l.right.run();
                    },
                }
            },
            .background => |b| {
                const f = syscall.fork() catch {
                    stderr.println("fork failed", .{});
                    syscall.exit(1);
                };
                switch (f) {
                    .child => b.cmd.run(),
                    .parent => syscall.exit(0),
                }
            },
        }
    }
};
