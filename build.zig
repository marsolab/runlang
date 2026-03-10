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
    const sanitizer_flags = sanitizer_flag_buf[0..sanitizer_flag_count];

    inline for (runtime_c_sources) |src| {
        runtime_lib.root_module.addCSourceFile(.{
            .file = b.path(src),
            .flags = sanitizer_flags,
        });
    }
    runtime_lib.root_module.addIncludePath(b.path("src/runtime"));
    runtime_lib.linkLibC();
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
}
