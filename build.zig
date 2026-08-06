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

    // 1. Build host tool bin2zig
    const bin2zig = b.addExecutable(.{
        .name = "bin2zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bin2zig.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    // 2. Build user space test program
    const user_exe = b.addExecutable(.{
        .name = "user_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/user/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    user_exe.entry = .{ .symbol_name = "_start" };
    user_exe.image_base = 0x2000000;

    // 3. Run bin2zig to generate user_test_bin.zig
    const run_bin2zig = b.addRunArtifact(bin2zig);
    run_bin2zig.addArg("-i");
    run_bin2zig.addFileArg(user_exe.getEmittedBin());
    run_bin2zig.addArg("-o");
    const out_file = run_bin2zig.addOutputFileArg("user_test_bin.zig");

    // 4. Build kernel
    const exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });

    exe.root_module.addAssemblyFile(b.path("src/entry.S"));
    exe.root_module.addAssemblyFile(b.path("src/arch/isr.S"));
    exe.setLinkerScript(b.path("linker.ld"));
    exe.entry = .{ .symbol_name = "_start" };

    // Add generated binary array as a module import
    exe.root_module.addAnonymousImport("user_test_bin", .{
        .root_source_file = out_file,
    });

    b.installArtifact(exe);

    const build_step = b.step("build", "Build the kernel");
    build_step.dependOn(&exe.step);
}
