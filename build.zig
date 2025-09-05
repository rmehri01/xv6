const std = @import("std");

pub fn build(b: *std.Build) !void {
    // the host target, which mkfs runs on
    const target = b.standardTargetOptions(.{});
    // the riscv target which the kernel and user programs run on
    const riscv_target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const optimize = b.standardOptimizeOption(.{});

    // the check step makes sure everything compiles and gives us nicer
    // diagnostics from zls
    const check = b.step("check", "Check if the kernel compiles");

    // shared definitions between kernel and userspace
    const shared = b.addModule("shared", .{
        .root_source_file = b.path("shared/root.zig"),
        .target = riscv_target,
        .optimize = optimize,
        .code_model = .medium,
    });

    // compile mkfs which takes a list of user programs to include in the
    // initial file system image
    const mkfs = b.addExecutable(.{
        .name = "mkfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("mkfs/mkfs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    mkfs.root_module.addAnonymousImport("shared", .{
        .root_source_file = b.path("shared/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    check.dependOn(&mkfs.step);

    const mkfs_run = b.addRunArtifact(mkfs);
    mkfs_run.addArgs(&.{ "fs.img", "README.md" });

    // compile the shared user library
    const ulib = b.addModule("ulib", .{
        .root_source_file = b.path("user/lib/root.zig"),
        .target = riscv_target,
        .optimize = .ReleaseSafe,
    });
    ulib.addImport("shared", shared);

    // compile user programs
    const user_progs: []const []const u8 = &.{
        "init",
        "sh",
        "echo",
        "cat",
        "ln",
        "uptime",
        "kill",
        "wc",
        "ls",
        "mkdir",
        "rm",
        "grep",
        "zombie",
        "forktest",
        "dorphan",
        "forphan",
        "logstress",
        "grind",
    };
    inline for (user_progs) |prog| {
        // the user program module
        const uprog = b.createModule(.{
            .root_source_file = b.path(
                std.fmt.comptimePrint("user/bin/{s}.zig", .{prog}),
            ),
            .target = riscv_target,
            .optimize = .ReleaseSafe,
            .strip = true,
        });
        uprog.addImport("shared", shared);
        uprog.addImport("ulib", ulib);

        // the shim sets up a panic handler and does error handling/exiting
        // so that the user programs can just define main
        const shim = b.addExecutable(.{
            .name = prog,
            .root_module = b.createModule(.{
                .root_source_file = b.path("user/bin/entry.zig"),
                .target = riscv_target,
                .optimize = .ReleaseSafe,
                .strip = true,
            }),
        });
        shim.setLinkerScript(b.path("user/user.ld"));
        shim.root_module.addImport("ulib", ulib);
        shim.root_module.addImport("uprog", uprog);
        b.installArtifact(shim);

        mkfs_run.addArtifactArg(shim);
        check.dependOn(&shim.step);
    }

    const mkfs_step = b.step("mkfs", "Build an initial file system");
    mkfs_step.dependOn(&mkfs_run.step);

    // compile the kernel itself
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/start.zig"),
            .target = riscv_target,
            .optimize = optimize,
            .code_model = .medium,
        }),
    });
    kernel.setLinkerScript(b.path("kernel/kernel.ld"));
    kernel.addAssemblyFile(b.path("kernel/entry.S"));
    kernel.addAssemblyFile(b.path("kernel/trampoline.S"));
    kernel.addAssemblyFile(b.path("kernel/ctxSwitch.S"));
    kernel.root_module.addImport("shared", shared);
    b.installArtifact(kernel);
    check.dependOn(&kernel.step);

    // set up a run command that runs the kernel in qemu with the fs image from mkfs
    const qemu = "qemu-system-riscv64";
    const qemu_cpu = "rv64";

    const cpus = if (b.option(u8, "cpus", "Number of cpus to use")) |cpus|
        try std.fmt.allocPrint(b.allocator, "{d}", .{cpus})
    else
        "3";

    // zig fmt: off
    const qemu_cmd = b.addSystemCommand(&.{
        qemu,
        "-machine", "virt",
        "-bios", "none",
        "-m", "128M",
        "-cpu", qemu_cpu,
        "-smp", cpus,
        "-nographic",
        "-global", "virtio-mmio.force-legacy=false",
        "-drive", "file=fs.img,if=none,format=raw,id=x0",
        "-device", "virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0",
        "-kernel",
    });
    // zig fmt: on
    qemu_cmd.addArtifactArg(kernel);

    const debug = b.option(bool, "debug", "Debug the kernel using gdb") orelse false;
    if (debug) {
        qemu_cmd.addArgs(&.{ "-s", "-S" });
        std.log.debug("*** Now run 'gdb' in another window.", .{});
    }

    qemu_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| qemu_cmd.addArgs(args);
    const run_step = b.step("run", "Start the kernel in qemu");
    run_step.dependOn(&qemu_cmd.step);
}
