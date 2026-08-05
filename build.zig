const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64 },
        .cpu_features_sub = std.Target.x86.featureSet(&.{
            .sse3,
            .ssse3,
            .sse4_1,
            .sse4_2,
            .avx,
            .avx2,
        }),
    });

    const mkdir_step = b.addSystemCommand(&.{ "mkdir", "-p", "build" });

    const asm_entry = b.addSystemCommand(&.{
        "as", "--64", "-o", "build/entry.o", "src/entry.S",
    });
    asm_entry.step.dependOn(&mkdir_step.step);

    const asm_isr = b.addSystemCommand(&.{
        "as", "--64", "-o", "build/isr.o", "src/arch/isr.S",
    });
    asm_isr.step.dependOn(&mkdir_step.step);

    const exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });

    exe.root_module.addObjectFile(b.path("build/entry.o"));
    exe.root_module.addObjectFile(b.path("build/isr.o"));
    exe.setLinkerScript(b.path("linker.ld"));
    exe.entry = .{ .symbol_name = "_start" };
    exe.step.dependOn(&asm_entry.step);
    exe.step.dependOn(&asm_isr.step);
    b.installArtifact(exe);

    const build_step = b.step("build", "Build the kernel");
    build_step.dependOn(&exe.step);
}
