const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const init = b.addExecutable(.{
        .name = "init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/init.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .riscv64,
                .os_tag = .freestanding,
                .abi = .none,
            }),
            .optimize = .ReleaseSafe,
            .code_model = .medium,
        }),
    });
    init.setLinkerScript(b.path("user/user.ld"));

    const mkfs = b.addExecutable(.{
        .name = "mkfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("mkfs/mkfs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const mkfs_deps: []const []const u8 = &.{ "kernel/params.zig", "kernel/fs/defs.zig" };
    for (mkfs_deps) |path| {
        mkfs.root_module.addAnonymousImport(path, .{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
    }
    const mkfs_run = b.addRunArtifact(mkfs);
    mkfs_run.addArgs(&.{ "fs.img", "README.md" });
    mkfs_run.addArtifactArg(init);
    const mkfs_step = b.step("mkfs", "Build an initial file system");
    mkfs_step.dependOn(&mkfs_run.step);

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/start.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .riscv64,
                .os_tag = .freestanding,
                .abi = .none,
            }),
            .optimize = optimize,
            .code_model = .medium,
        }),
    });
    kernel.setLinkerScript(b.path("kernel/kernel.ld"));
    kernel.addAssemblyFile(b.path("kernel/entry.S"));
    kernel.addAssemblyFile(b.path("kernel/trampoline.S"));
    kernel.addAssemblyFile(b.path("kernel/ctxSwitch.S"));
    b.installArtifact(kernel);

    const check = b.step("check", "Check if the kernel compiles");
    check.dependOn(&kernel.step);
    check.dependOn(&mkfs.step);

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
