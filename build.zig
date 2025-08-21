const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .riscv64,
            .os_tag = .freestanding,
            .abi = .none,
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/start.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .medium,
        }),
    });

    kernel.setLinkerScript(b.path("kernel/kernel.ld"));
    kernel.addAssemblyFile(b.path("kernel/entry.S"));

    b.installArtifact(kernel);

    const check = b.step("check", "Check if the kernel compiles");
    check.dependOn(&kernel.step);

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
