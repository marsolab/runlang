const std = @import("std");

/// Probe for the GCC library directory containing sanitizer runtimes.
/// On Ubuntu/Debian, libasan.a lives under /usr/lib/gcc/<triple>/<version>/
/// which is not in the standard library search path.
fn findGccSanitizerLibDir(b: *std.Build) ?[]const u8 {
    const allocator = b.allocator;
    const io = b.graph.io;
    const triplets = [_][]const u8{ "x86_64-linux-gnu", "aarch64-linux-gnu" };
    const versions = [_][]const u8{ "14", "13", "12", "11" };
    for (triplets) |triplet| {
        for (versions) |ver| {
            const path = std.fmt.allocPrint(allocator, "/usr/lib/gcc/{s}/{s}/libasan.a", .{ triplet, ver }) catch continue;
            if (std.Io.Dir.cwd().openFile(io, path, .{})) |f| {
                f.close(io);
                return std.fmt.allocPrint(allocator, "/usr/lib/gcc/{s}/{s}", .{ triplet, ver }) catch null;
            } else |_| {}
        }
    }
    return null;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Sanitizer options for runtime C code
    const sanitize = b.option(bool, "sanitize", "Enable ASan+UBSan for runtime C code") orelse false;
    const tsan = b.option(bool, "tsan", "Enable ThreadSanitizer for runtime C code") orelse false;
    const no_gen_checks = b.option(bool, "no-gen-checks", "Disable generational reference checks at compile time") orelse false;
    const legacy_poller = b.option(bool, "legacy-poller", "Use legacy run_poller_legacy.c instead of libxev-backed poller") orelse false;

    // Version from build.zig.zon
    const version = "0.1.0-alpha.1";

    // Build options module (passes version to compiler source)
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    // Main compiler executable
    const exe = b.addExecutable(.{
        .name = "run",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);
    b.installArtifact(exe);

    // libxev dependency (cross-platform event loop for async I/O)
    const libxev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });

    // Runtime C library (static archive for use by the driver during compilation)
    const runtime_lib = b.addLibrary(.{
        .name = "runrt",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Select poller implementation: libxev-backed (default) or legacy
    const poller_source: []const u8 = if (legacy_poller)
        "src/runtime/run_poller_legacy.c"
    else
        "src/runtime/run_xev.c";

    const runtime_c_sources_base = .{
        "src/runtime/run_alloc.c",
        "src/runtime/run_string.c",
        "src/runtime/run_slice.c",
        "src/runtime/run_fmt.c",
        "src/runtime/run_scheduler.c",
        "src/runtime/run_chan.c",
        "src/runtime/run_vmem.c",
        "src/runtime/run_map.c",
        "src/runtime/run_simd.c",
        "src/runtime/run_numa.c",
        "src/runtime/run_runtime_api.c",
        "src/runtime/run_debug_api.c",
        "src/runtime/run_stacktrace.c",
    };
    // runtime_c_sources kept as alias for inline iteration below
    const runtime_c_sources = runtime_c_sources_base;

    // Build sanitizer flags
    var sanitizer_flag_buf: [10][]const u8 = undefined;
    var sanitizer_flag_count: usize = 0;
    // Enable GNU extensions (sched_getcpu, CPU_ZERO, pthread_setaffinity_np, etc.)
    sanitizer_flag_buf[sanitizer_flag_count] = "-D_GNU_SOURCE";
    sanitizer_flag_count += 1;
    sanitizer_flag_buf[sanitizer_flag_count] = "-g";
    sanitizer_flag_count += 1;
    if (sanitize) {
        sanitizer_flag_buf[sanitizer_flag_count] = "-fsanitize=address,undefined";
        sanitizer_flag_count += 1;
        sanitizer_flag_buf[sanitizer_flag_count] = "-fno-omit-frame-pointer";
        sanitizer_flag_count += 1;
    }
    if (tsan) {
        sanitizer_flag_buf[sanitizer_flag_count] = "-fsanitize=thread";
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
    // Add selected poller implementation (libxev-backed or legacy)
    runtime_lib.root_module.addCSourceFile(.{
        .file = b.path(poller_source),
        .flags = sanitizer_flags,
    });
    // run_main.c defines main() and is only included in the library,
    // not in the test executable (which has its own test_main.c).
    runtime_lib.root_module.addCSourceFile(.{
        .file = b.path("src/runtime/run_main.c"),
        .flags = sanitizer_flags,
    });

    // Add platform-specific assembly for context switching
    const target_info = target.result;
    if (target_info.cpu.arch == .x86_64) {
        runtime_lib.root_module.addAssemblyFile(b.path("src/runtime/run_context_amd64.S"));
        runtime_lib.root_module.addAssemblyFile(b.path("src/runtime/run_async_preempt_amd64.S"));
    } else if (target_info.cpu.arch == .aarch64) {
        runtime_lib.root_module.addAssemblyFile(b.path("src/runtime/run_context_arm64.S"));
        runtime_lib.root_module.addAssemblyFile(b.path("src/runtime/run_async_preempt_arm64.S"));
    }

    runtime_lib.root_module.addIncludePath(b.path("src/runtime"));
    // Build the Zig bridge that wraps libxev's Zig API for C consumption.
    //
    // The bridge is compiled once as an object file and added directly to
    // runtime_lib and runtime_test_exe via addObject. Linking it through a
    // shared static archive read concurrently by two executables produced
    // "truncated or malformed archive" errors on Linux x86_64 / Zig 0.15.2.
    //
    // A separate static library is also installed so the driver can link
    // -lrunxev when compiling user programs.
    const xev_bridge_obj: ?*std.Build.Step.Compile = if (!legacy_poller) blk: {
        const obj = b.addObject(.{
            .name = "run_xev_bridge",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/runtime/run_xev_bridge.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        obj.root_module.addImport("xev", libxev_dep.module("xev"));
        break :blk obj;
    } else null;
    if (xev_bridge_obj) |obj| {
        runtime_lib.root_module.addObject(obj);
        if (target_info.os.tag == .windows) {
            const xev_bridge_lib = b.addLibrary(.{
                .name = "runxev",
                .linkage = .static,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/runtime/run_xev_bridge.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            xev_bridge_lib.root_module.addImport("xev", libxev_dep.module("xev"));
            b.installArtifact(xev_bridge_lib);
        } else {
            // Bundle the already-compiled object into librunxev.a with host
            // `ar` so the driver can still link `-lrunxev`. Going through `ar`
            // directly avoids the Zig archiver race that produced truncated
            // archives on Linux x86_64 when librunxev.a was written and read
            // concurrently.
            const ar_cmd = b.addSystemCommand(&.{ "ar", "rcs" });
            const archive = ar_cmd.addOutputFileArg("librunxev.a");
            ar_cmd.addArtifactArg(obj);
            const install_xev_lib = b.addInstallFile(archive, "lib/librunxev.a");
            b.getInstallStep().dependOn(&install_xev_lib.step);
        }
    }
    runtime_lib.root_module.linkSystemLibrary("pthread", .{});
    // Link libunwind for stack traces with DWARF unwinding.
    // On macOS, libunwind is part of the system (linked automatically).
    // On Linux, it requires the libunwind-dev package.
    if (target_info.os.tag == .linux) {
        runtime_lib.root_module.linkSystemLibrary("unwind", .{});
    }
    // Note: sanitizer runtime libraries are NOT linked into the static archive.
    // The consuming executable is responsible for linking them.
    b.installArtifact(runtime_lib);

    // Install runtime headers alongside compiler (headers only, not .c/.S/tests)
    b.installDirectory(.{
        .source_dir = b.path("src/runtime"),
        .install_dir = .header,
        .install_subdir = "run",
        .include_extensions = &.{".h"},
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
            .link_libc = true,
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
            .link_libc = true,
        }),
    });

    const runtime_test_sources = .{
        "src/runtime/tests/test_main.c",
        "src/runtime/tests/test_vmem.c",
        "src/runtime/tests/test_scheduler.c",
        "src/runtime/tests/test_chan.c",
        "src/runtime/tests/test_map.c",
        "src/runtime/tests/test_fmt.c",
        "src/runtime/tests/test_simd.c",
        "src/runtime/tests/test_numa.c",
        "src/runtime/tests/test_runtime_api.c",
        "src/runtime/tests/test_debug_api.c",
        "src/runtime/tests/test_poller.c",
        "src/runtime/tests/test_stress.c",
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
    // Add selected poller implementation for tests
    runtime_test_exe.root_module.addCSourceFile(.{
        .file = b.path(poller_source),
        .flags = sanitizer_flags,
    });

    // Add assembly for runtime tests too
    if (target_info.cpu.arch == .x86_64) {
        runtime_test_exe.root_module.addAssemblyFile(b.path("src/runtime/run_context_amd64.S"));
        runtime_test_exe.root_module.addAssemblyFile(b.path("src/runtime/run_async_preempt_amd64.S"));
    } else if (target_info.cpu.arch == .aarch64) {
        runtime_test_exe.root_module.addAssemblyFile(b.path("src/runtime/run_context_arm64.S"));
        runtime_test_exe.root_module.addAssemblyFile(b.path("src/runtime/run_async_preempt_arm64.S"));
    }

    runtime_test_exe.root_module.addIncludePath(b.path("src/runtime"));
    runtime_test_exe.root_module.addIncludePath(b.path("src/runtime/tests"));
    // Reuse the same object file produced for runtime_lib (see note above).
    if (xev_bridge_obj) |obj| {
        runtime_test_exe.root_module.addObject(obj);
    }
    runtime_test_exe.root_module.linkSystemLibrary("pthread", .{});
    // Link libunwind for stack trace tests (matches runtime_lib linking).
    if (target_info.os.tag == .linux) {
        runtime_test_exe.root_module.linkSystemLibrary("unwind", .{});
        // On Linux, dladdr only resolves symbols exposed through the dynamic
        // symbol table. Without --export-dynamic, stack-trace tests that match
        // on function names (e.g. strstr(trace, "test_runtime_stack")) will
        // fail because the static test functions aren't visible to dladdr.
        runtime_test_exe.rdynamic = true;
    }

    // Link sanitizer runtime libraries for the test executable.
    // On Ubuntu/Debian, these live in GCC's versioned lib directory
    // (e.g. /usr/lib/gcc/x86_64-linux-gnu/13/) which isn't in the
    // standard search path. Probe for it at configure time.
    if (sanitize or tsan) {
        if (findGccSanitizerLibDir(b)) |gcc_dir| {
            runtime_test_exe.root_module.addLibraryPath(.{ .cwd_relative = gcc_dir });
        }
    }
    if (sanitize) {
        runtime_test_exe.root_module.linkSystemLibrary("asan", .{});
        runtime_test_exe.root_module.linkSystemLibrary("ubsan", .{});
    }
    if (tsan) {
        runtime_test_exe.root_module.linkSystemLibrary("tsan", .{});
    }
    b.installArtifact(runtime_test_exe);

    const run_runtime_tests = b.addRunArtifact(runtime_test_exe);
    run_runtime_tests.step.dependOn(&runtime_test_exe.step);
    if (target_info.os.tag == .macos) {
        const runtime_tests_dsym = b.addSystemCommand(&.{"dsymutil"});
        runtime_tests_dsym.addArtifactArg(runtime_test_exe);
        run_runtime_tests.step.dependOn(&runtime_tests_dsym.step);
    }
    const runtime_test_step = b.step("test-runtime", "Run runtime C tests");
    runtime_test_step.dependOn(&run_runtime_tests.step);

    // Runtime benchmarks
    const runtime_bench_exe = b.addExecutable(.{
        .name = "runtime-bench",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    const runtime_bench_sources = .{
        "benchmarks/runtime/bench_main.c",
        "benchmarks/runtime/bench_spawn.c",
        "benchmarks/runtime/bench_context_switch.c",
        "benchmarks/runtime/bench_channel.c",
        "benchmarks/runtime/bench_steal.c",
        "benchmarks/runtime/bench_poll.c",
        "benchmarks/runtime/bench_scheduler.c",
    };
    inline for (runtime_bench_sources) |src| {
        runtime_bench_exe.root_module.addCSourceFile(.{
            .file = b.path(src),
            .flags = &.{"-D_GNU_SOURCE"},
        });
    }
    inline for (runtime_c_sources) |src| {
        runtime_bench_exe.root_module.addCSourceFile(.{
            .file = b.path(src),
            .flags = &.{"-D_GNU_SOURCE"},
        });
    }
    runtime_bench_exe.root_module.addCSourceFile(.{
        .file = b.path(poller_source),
        .flags = &.{"-D_GNU_SOURCE"},
    });
    // Note: run_main.c is NOT included in benchmarks — bench_main.c provides main()
    if (target_info.cpu.arch == .x86_64) {
        if (target_info.os.tag == .windows) {
            runtime_bench_exe.root_module.addAssemblyFile(b.path("src/runtime/run_context_win64.S"));
        } else {
            runtime_bench_exe.root_module.addAssemblyFile(b.path("src/runtime/run_context_amd64.S"));
            runtime_bench_exe.root_module.addAssemblyFile(b.path("src/runtime/run_async_preempt_amd64.S"));
        }
    } else if (target_info.cpu.arch == .aarch64) {
        runtime_bench_exe.root_module.addAssemblyFile(b.path("src/runtime/run_context_arm64.S"));
        runtime_bench_exe.root_module.addAssemblyFile(b.path("src/runtime/run_async_preempt_arm64.S"));
    }
    runtime_bench_exe.root_module.addIncludePath(b.path("src/runtime"));
    runtime_bench_exe.root_module.addIncludePath(b.path("benchmarks/runtime"));
    if (!legacy_poller) {
        const xev_bench_bridge = b.addLibrary(.{
            .name = "runxev-bench",
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/runtime/run_xev_bridge.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .link_libc = true,
            }),
        });
        xev_bench_bridge.root_module.addImport("xev", libxev_dep.module("xev"));
        runtime_bench_exe.root_module.linkLibrary(xev_bench_bridge);
    }
    runtime_bench_exe.root_module.linkSystemLibrary("pthread", .{});
    // Link libunwind for stack trace support (matches runtime_lib linking).
    if (target_info.os.tag == .linux) {
        runtime_bench_exe.root_module.linkSystemLibrary("unwind", .{});
    }
    b.installArtifact(runtime_bench_exe);

    const run_runtime_bench = b.addRunArtifact(runtime_bench_exe);
    run_runtime_bench.step.dependOn(&runtime_bench_exe.step);
    const runtime_bench_step = b.step("bench-runtime", "Run runtime benchmarks");
    runtime_bench_step.dependOn(&run_runtime_bench.step);

    // Example build tests
    const examples_test_exe = b.addExecutable(.{
        .name = "examples-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/examples/runner.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_examples_tests = b.addRunArtifact(examples_test_exe);
    run_examples_tests.step.dependOn(b.getInstallStep());
    const examples_test_step = b.step("test-examples", "Build all example programs");
    examples_test_step.dependOn(&run_examples_tests.step);

    // E2E compiler tests
    const e2e_test_exe = b.addExecutable(.{
        .name = "e2e-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e/runner.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_e2e_tests = b.addRunArtifact(e2e_test_exe);
    run_e2e_tests.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_e2e_tests.addArgs(args);
    }
    const e2e_test_step = b.step("test-e2e", "Run end-to-end compiler tests");
    e2e_test_step.dependOn(&run_e2e_tests.step);

    // Fuzz targets
    const fuzz_targets = .{
        .{ "fuzz-lexer", "src/fuzz_lexer.zig", "Fuzz the lexer" },
        .{ "fuzz-parser", "src/fuzz_parser.zig", "Fuzz the parser" },
        .{ "fuzz-pipeline", "src/fuzz_pipeline.zig", "Fuzz the full pipeline" },
    };
    inline for (fuzz_targets) |entry| {
        const fuzz_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(entry[1]),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        const run_fuzz = b.addRunArtifact(fuzz_test);
        const fuzz_step = b.step(entry[0], entry[2]);
        fuzz_step.dependOn(&run_fuzz.step);
    }

    // Benchmark suite
    const bench_root = b.createModule(.{
        .root_source_file = b.path("benchmarks/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    // Provide compiler as a single module to avoid file-ownership conflicts
    bench_root.addImport("compiler", b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }));
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_root,
    });
    // Benchmark depends on compiler binary for pipeline benchmarks
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
    const bench_step = b.step("bench", "Run compiler benchmarks");
    bench_step.dependOn(&run_bench.step);

    // WASM build for the web playground
    const wasm = b.addExecutable(.{
        .name = "run-playground",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.entry = .disabled;
    wasm.root_module.export_symbol_names = &.{
        "alloc",
        "dealloc",
        "getResultPtr",
        "getResultLen",
        "check",
        "tokenize",
        "parse",
        "format",
        "run",
    };
    const install_wasm = b.addInstallArtifact(wasm, .{});

    const wasm_step = b.step("wasm", "Build WASM module for the web playground");
    wasm_step.dependOn(&install_wasm.step);
}
