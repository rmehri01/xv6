const std = @import("std");

const ulib = @import("ulib");
const syscall = ulib.syscall;

const stdout = &ulib.io.stdout;

pub fn main() !void {
    // uptime is in ticks and each tick is roughly a tenth of a second
    const uptime = syscall.uptime();
    var seconds = uptime / 10;

    const days = seconds / std.time.s_per_day;
    seconds -= days * std.time.s_per_day;

    const hours = seconds / std.time.s_per_hour;
    seconds -= hours * std.time.s_per_hour;

    const mins = seconds / std.time.s_per_min;
    seconds -= mins * std.time.s_per_min;

    stdout.println(
        "up {d} {s}, {d} {s}, {d} {s}, {d} {s}",
        .{
            days,
            if (days == 1) "day" else "days",
            hours,
            if (hours == 1) "hour" else "hours",
            mins,
            if (mins == 1) "min" else "mins",
            seconds,
            if (seconds == 1) "second" else "seconds",
        },
    );
}
