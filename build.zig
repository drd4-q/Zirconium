const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const selftest = b.option(bool, "selftest", "Run the embedded ring-3 boot self-test") orelse false;
    const config_path = b.option(
        []const u8,
        "config",
        "Path to the declarative kernel configuration (default: config/kernel.json)",
    ) orelse "config/kernel.json";

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

    // 1b. Build host tool gen_config, which compiles the declarative kernel
    //     configuration into a Zig module the kernel imports as "config".
    const gen_config = b.addExecutable(.{
        .name = "gen_config",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_config.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    // The guest profiles are pure data, so the generator can read the same
    // table the kernel uses: a profile that is spelled wrong in the
    // configuration is a build error, not a machine that never comes up.
    gen_config.root_module.addAnonymousImport("vm_profiles", .{
        .root_source_file = b.path("src/vm/profiles.zig"),
    });

    const run_gen_config = b.addRunArtifact(gen_config);
    // Inherit the terminal: the generator's progress output is meant to be
    // read, and a captured stderr makes the build system echo the whole
    // command back as if it had failed.
    run_gen_config.stdio = .inherit;
    run_gen_config.addArg("--input");
    // b.path() only accepts paths relative to the build root; an absolute
    // path has to go through the cwd-relative variant.
    const config_file: std.Build.LazyPath = if (std.fs.path.isAbsolute(config_path))
        .{ .cwd_relative = config_path }
    else
        b.path(config_path);
    run_gen_config.addFileArg(config_file);
    run_gen_config.addArg("--output");
    const config_out = run_gen_config.addOutputFileArg("config.zig");
    if (selftest) {
        // The command-line switch layers on top of the configuration file.
        run_gen_config.addArgs(&.{ "--set-feature", "selftest=true" });
    }

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

    // 2b. Second ring-3 task: a pure user-mode spinner used to prove that the
    //     scheduler preempts (it never blocks, so only a tick can switch away).
    const user2_exe = b.addExecutable(.{
        .name = "user_test2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/user/test2.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    user2_exe.entry = .{ .symbol_name = "_start" };
    user2_exe.image_base = 0x2000000;

    // 2c. The guest driver for the hypervisor's own device.  It is a
    //     freestanding ring-3 program, exactly like the user tests, and it
    //     talks to the device through the shared protocol header.
    const kvm_test_exe = b.addExecutable(.{
        .name = "kvm_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/user/kvm_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    kvm_test_exe.entry = .{ .symbol_name = "_start" };
    kvm_test_exe.image_base = 0x2000000;
    // The protocol header is shared with the hypervisor: the guest driver
    // and the device it drives cannot disagree about the interface.
    kvm_test_exe.root_module.addAnonymousImport("kvm_proto", .{
        .root_source_file = b.path("src/vm/proto.zig"),
    });

    // 2d. The sample guest kernel: a 32-bit Multiboot stub plus the 64-bit
    //     half.  It is embedded in the kernel, so a ZVM with no guest image
    //     on its disk still has one to load.
    const guest_exe = b.addExecutable(.{
        .name = "guest_kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("samples/guest_kernel.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The 32-bit Multiboot stub (samples/guest_stub.S) is *not* linked in yet:
    // putting a 32-bit stub and 64-bit code in one image needs the linker's
    // own layout, and the sample is here to exercise the loader, not the
    // handoff.  The stub and its linker script are in the tree, ready for
    // the CPU emulator milestone.
    guest_exe.entry = .{ .symbol_name = "guest64_entry" };
    guest_exe.image_base = 0x100000;

    // 3. Run bin2zig to generate user_test_bin.zig
    const run_bin2zig = b.addRunArtifact(bin2zig);
    run_bin2zig.addArg("-i");
    run_bin2zig.addFileArg(user_exe.getEmittedBin());
    run_bin2zig.addArg("-o");
    const out_file = run_bin2zig.addOutputFileArg("user_test_bin.zig");

    const run_bin2zig2 = b.addRunArtifact(bin2zig);
    run_bin2zig2.addArg("-i");
    run_bin2zig2.addFileArg(user2_exe.getEmittedBin());
    run_bin2zig2.addArg("-o");
    const out_file2 = run_bin2zig2.addOutputFileArg("user_test2_bin.zig");

    // 3b. Build the AP trampoline blob (assemble + link at 0x8000, raw binary),
    //     then embed it as a Zig byte array via bin2zig.
    const tramp_exe = b.addExecutable(.{
        .name = "trampoline",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    tramp_exe.root_module.addAssemblyFile(b.path("src/arch/trampoline.S"));
    tramp_exe.setLinkerScript(b.path("src/arch/trampoline.ld"));
    tramp_exe.entry = .{ .symbol_name = "_start" };

    const tramp_bin = tramp_exe.addObjCopy(.{ .format = .bin });
    const tramp_bin_file = tramp_bin.getOutput();

    const run_bin2zig_kvm = b.addRunArtifact(bin2zig);
    run_bin2zig_kvm.addArg("-i");
    run_bin2zig_kvm.addFileArg(kvm_test_exe.getEmittedBin());
    run_bin2zig_kvm.addArg("-o");
    const kvm_test_out = run_bin2zig_kvm.addOutputFileArg("kvm_test_bin.zig");

    const run_bin2zig_guest = b.addRunArtifact(bin2zig);
    run_bin2zig_guest.addArg("-i");
    run_bin2zig_guest.addFileArg(guest_exe.getEmittedBin());
    run_bin2zig_guest.addArg("-o");
    const guest_out = run_bin2zig_guest.addOutputFileArg("guest_kernel_bin.zig");

    const run_bin2zig_t = b.addRunArtifact(bin2zig);
    run_bin2zig_t.addArg("-i");
    run_bin2zig_t.addFileArg(tramp_bin_file);
    run_bin2zig_t.addArg("-o");
    const tramp_out = run_bin2zig_t.addOutputFileArg("ap_tramp_bin.zig");

    // 4. Build kernel
    const exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .red_zone = false,
            // system/panic.zig walks the RBP chain in printBacktrace, and
            // main.zig's panic handler seeds it from the current frame.  The
            // optimized modes drop frame pointers by default, which would turn
            // the backtrace into garbage exactly when it is needed (a panic on
            // real hardware is otherwise undebuggable).  Keep them.
            .omit_frame_pointer = false,
            .strip = true,
        }),
        .use_llvm = true,
    });

    exe.root_module.addAnonymousImport("config", .{
        .root_source_file = config_out,
    });
    exe.root_module.addAssemblyFile(b.path("src/entry.S"));
    exe.root_module.addAssemblyFile(b.path("src/arch/isr.S"));
    exe.setLinkerScript(b.path("linker.ld"));
    exe.entry = .{ .symbol_name = "_start" };

    // Add generated binary array as a module import
    exe.root_module.addAnonymousImport("user_test_bin", .{
        .root_source_file = out_file,
    });
    exe.root_module.addAnonymousImport("user_test2_bin", .{
        .root_source_file = out_file2,
    });
    exe.root_module.addAnonymousImport("ap_tramp_bin", .{
        .root_source_file = tramp_out,
    });
    exe.root_module.addAnonymousImport("kvm_test_bin", .{
        .root_source_file = kvm_test_out,
    });
    exe.root_module.addAnonymousImport("guest_kernel_bin", .{
        .root_source_file = guest_out,
    });

    b.installArtifact(exe);

    const build_step = b.step("build", "Build the kernel");
    build_step.dependOn(&exe.step);
}
