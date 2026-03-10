const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Sanitizer options for runtime C code
    const sanitize = b.option(bool, "sanitize", "Enable ASan+UBSan for runtime C code") orelse false;
    const tsan = b.option(bool, "tsan", "Enable ThreadSanitizer for runtime C code") orelse false;
    const no_gen_checks = b.option(bool, "no-gen-checks", "Disable generational reference checks at compile time") orelse false;

    // Main compiler executable
    const exe = b.addExecutable(.{
        .name = "run",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Runtime C library (static archive for use by the driver during compilation)
    const runtime_lib = b.addLibrary(.{
        .name = "runrt",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    const runtime_c_sources = .{
        "src/runtime/run_alloc.c",
        "src/runtime/run_string.c",
        "src/runtime/run_slice.c",
        "src/runtime/run_fmt.c",
        "src/runtime/run_scheduler.c",
        "src/runtime/run_chan.c",
        "src/runtime/run_vmem.c",
        "src/runtime/run_map.c",
    };

    // Build sanitizer flags
    var sanitizer_flag_buf: [8][]const u8 = undefined;
    var sanitizer_flag_count: usize = 0;
    if (sanitize) {
        sanitizer_flag_buf[sanitizer_flag_count] = "-fsanitize=address,undefined";
        sanitizer_flag_count += 1;
        sanitizer_flag_buf[sanitizer_flag_count] = "-fno-omit-frame-pointer";
        sanitizer_flag_count += 1;
        sanitizer_flag_buf[sanitizer_flag_count] = "-g";
        sanitizer_flag_count += 1;
    }
    if (tsan) {
        sanitizer_flag_buf[sanitizer_flag_count] = "-fsanitize=thread";
        sanitizer_flag_count += 1;
        sanitizer_flag_buf[sanitizer_flag_count] = "-g";
        sanitizer_flag_count += 1;
    }
    if (no_gen_checks) {
        sanitizer_flag_buf[sanitizer_flag_count] = "-DRUN_NO_GEN_CHECKS";
        sanitizer_flag_count += 1;
    }
    // Always disable stack protector for runtime code — green thread
    // context switching is incompatible with stack canaries.
    sanitizer_flag_buf[sanitizer_flag_count] = "-fno-stack-protector";
    sanitizer_flag_count += 1;
    const sanitizer_flags = sanitizer_flag_buf[0..sanitizer_flag_count];

    inline for (runtime_c_sources) |src| {
        runtime_lib.root_module.addCSourceFile(.{
            .file = b.path(src),
            .flags = sanitizer_flags,
        });
    }

    // Add platform-specific assembly for context switching
    const target_info = target.result;
    if (target_info.cpu.arch == .x86_64) {
        runtime_lib.root_module.addAssemblyFile(b.path("src/runtime/run_context_amd64.S"));
    } else if (target_info.cpu.arch == .aarch64) {
        runtime_lib.root_module.addAssemblyFile(b.path("src/runtime/run_context_arm64.S"));
    }

    runtime_lib.root_module.addIncludePath(b.path("src/runtime"));
    runtime_lib.linkLibC();
    runtime_lib.linkSystemLibrary("pthread");
    b.installArtifact(runtime_lib);

    // Install runtime headers alongside compiler
    b.installDirectory(.{
        .source_dir = b.path("src/runtime"),
        .install_dir = .header,
        .install_subdir = "run",
    });

    // Run command: `zig build run -- <args>`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Compile and run the Run compiler");
    run_step.dependOn(&run_cmd.step);

    // Tests (via root.zig which re-exports all modules)
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Runtime C tests
    const runtime_test_exe = b.addExecutable(.{
        .name = "runtime-tests",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    const runtime_test_sources = .{
        "src/runtime/tests/test_main.c",
        "src/runtime/tests/test_vmem.c",
        "src/runtime/tests/test_scheduler.c",
        "src/runtime/tests/test_chan.c",
        "src/runtime/tests/test_map.c",
    };
    inline for (runtime_test_sources) |src| {
        runtime_test_exe.root_module.addCSourceFile(.{
            .file = b.path(src),
            .flags = sanitizer_flags,
        });
    }
    inline for (runtime_c_sources) |src| {
        runtime_test_exe.root_module.addCSourceFile(.{
            .file = b.path(src),
            .flags = sanitizer_flags,
        });
    }

    // Add assembly for runtime tests too
    if (target_info.cpu.arch == .x86_64) {
        runtime_test_exe.root_module.addAssemblyFile(b.path("src/runtime/run_context_amd64.S"));
    } else if (target_info.cpu.arch == .aarch64) {
        runtime_test_exe.root_module.addAssemblyFile(b.path("src/runtime/run_context_arm64.S"));
    }

    runtime_test_exe.root_module.addIncludePath(b.path("src/runtime"));
    runtime_test_exe.root_module.addIncludePath(b.path("src/runtime/tests"));
    runtime_test_exe.linkLibC();
    runtime_test_exe.linkSystemLibrary("pthread");
    b.installArtifact(runtime_test_exe);

    const run_runtime_tests = b.addRunArtifact(runtime_test_exe);
    run_runtime_tests.step.dependOn(&runtime_test_exe.step);
    const runtime_test_step = b.step("test-runtime", "Run runtime C tests");
    runtime_test_step.dependOn(&run_runtime_tests.step);
}
